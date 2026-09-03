//
// `net` shim for the embedded mobile worker.
//
// The bare embedded engine (QuickJS/JavaScriptCore) cannot open or accept TCP connections. The one
// irreducible native piece of the asset server is the TCP socket; everything above it is TypeScript.
// This shim provides a `Server` and `Socket` built on four native host functions (tcpListen,
// tcpWrite, tcpClose, tcpStopListening) plus an inbound event push: native delivers `connection`,
// `data`, and `close` events into the engine by calling `globalThis.__tcpEvent`, which this module
// installs. The `http` shim is layered on top of this `net` shim.
//
// In the Node unit-test environment a mock host is installed on `globalThis.host` and inbound events
// are simulated by calling `globalThis.__tcpEvent` directly, so the whole layer is testable off-device.
//

import { Buffer } from "buffer";
import { callHost } from "./host-access";

//
// How long a native file send has to take before it is worth saying how long it took.
//
// A quick send says nothing, so it says nothing. A slow one is the only measurement anywhere of how
// fast the bytes actually leave the phone, which is the thing no code above this can change.
//
const SLOW_SEND_MS = 1000;

//
// The `AddressInfo` type, used only in type position by find-available-port.
//
export class AddressInfo {}

//
// The subset of native host functions the net shim calls. They are synchronous native callables and
// follow the same error convention as the fs host functions (an error-envelope string decoded by
// callHost). tcpListen returns a JSON string describing the bound listener.
//
export interface ITcpHost {
    // Binds a loopback TCP listener and returns a JSON string { listenerId, port } (port resolved when 0 was requested).
    tcpListen: (host: string, port: number) => string;

    // Opens an outbound TCP connection and returns a JSON string { connectionId }.
    tcpConnect: (host: string, port: number) => string;

    // Writes base64-encoded bytes to an accepted connection.
    tcpWrite: (connectionId: string, base64: string) => string | null;

    // Writes a range of a file straight from disk to a connection, without the bytes entering the
    // engine. Returns null on success or an error envelope.
    tcpWriteFile: (connectionId: string, path: string, offset: number, length: number) => string | null;

    // Closes one accepted connection.
    tcpClose: (connectionId: string) => string | null;

    // Closes the listener so it accepts no further connections.
    tcpStopListening: (listenerId: string) => string | null;
}

//
// The JSON shape native returns from tcpListen.
//
interface ITcpListenResult {
    // The opaque id used to stop this listener later.
    listenerId: string;

    // The actual bound port (resolved even when port 0 was requested).
    port: number;
}

//
// The JSON shape native returns from tcpConnect.
//
interface ITcpConnectResult {
    // The opaque id of the newly opened outbound connection.
    connectionId: string;
}

//
// An inbound TCP event pushed from native into the engine via globalThis.__tcpEvent.
//
interface ITcpInboundEvent {
    // The event kind: a new accepted connection, inbound bytes, or a closed connection.
    kind: "connection" | "data" | "close";

    // The listener the connection was accepted on (present for "connection").
    listenerId?: string;

    // The connection the event relates to (present for all kinds).
    connectionId?: string;

    // Base64-encoded inbound bytes (present for "data").
    base64?: string;
}

//
// A registered event listener.
//
type NetListener = (...args: any[]) => void;

//
// Returns the installed native host bridge, throwing a clear error if it is missing.
//
function getTcpHost(): ITcpHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; net shim cannot run.");
    }

    return host as ITcpHost;
}

//
// A tiny event emitter shared by Server and Socket. Self-contained so the net shim does not depend
// on Node's `events` module resolving in the engine.
//
class TinyEmitter {
    //
    // Listeners registered per event name.
    //
    private netListeners: Map<string, NetListener[]> = new Map();

    //
    // Registers a listener for an event.
    //
    on(eventName: string, listener: NetListener): this {
        const existing = this.netListeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.netListeners.set(eventName, [listener]);
        }
        return this;
    }

    //
    // Registers a one-shot listener that removes itself after firing once.
    //
    once(eventName: string, listener: NetListener): this {
        const wrapper: NetListener = (...args: any[]) => {
            this.off(eventName, wrapper);
            listener(...args);
        };
        return this.on(eventName, wrapper);
    }

    //
    // Removes a previously registered listener.
    //
    off(eventName: string, listener: NetListener): this {
        const existing = this.netListeners.get(eventName);
        if (existing) {
            const index = existing.indexOf(listener);
            if (index >= 0) {
                existing.splice(index, 1);
            }
        }
        return this;
    }

    //
    // Emits an event to all registered listeners.
    //
    emit(eventName: string, ...args: any[]): void {
        const handlers = this.netListeners.get(eventName);
        if (!handlers) {
            return;
        }
        for (const handler of handlers.slice()) {
            handler(...args);
        }
    }
}

//
// Registry of active listeners keyed by listenerId, used to route inbound "connection" events.
//
const activeServers: Map<string, Server> = new Map();

//
// Registry of accepted sockets keyed by connectionId, used to route inbound "data" / "close" events.
//
const activeSockets: Map<string, Socket> = new Map();

//
// An accepted TCP connection. Reads arrive as `data` events (Buffers) and the remote close as `end`
// then `close`; writes go out via the native tcpWrite, and end() closes the connection via tcpClose.
//
export class Socket extends TinyEmitter {
    //
    // The opaque native connection id this socket wraps.
    //
    readonly connectionId: string;

    //
    // True once the socket has been closed (locally or by the remote).
    //
    private closed = false;

    //
    // Whether the connection can still be read from and written to. Both stay true until it closes.
    //
    // These exist for on-finished, which express and body-parser both sit on top of. Its isFinished()
    // decides an IncomingMessage is already finished when `!socket.readable`, and an absent property
    // reads as undefined, which negates to true. So without these a brand new request looked complete
    // before a byte of it had been read: body-parser's read() took its "body already parsed" branch,
    // called next() without ever setting req.body, and the route behind express.json() then threw
    // reading a property of undefined. That is every route on this server that parses a JSON body,
    // which is to say the whole gallery edit path. Nothing about the transport was wrong; the socket
    // simply was not telling the truth about itself.
    //
    readable = true;
    writable = true;

    //
    // Wraps a native-accepted connection id.
    //
    constructor(connectionId: string) {
        super();
        this.connectionId = connectionId;
    }

    //
    // Writes bytes to the connection. Strings are encoded as utf-8; Buffers/Uint8Arrays are sent as-is.
    //
    write(chunk: Buffer | Uint8Array | string): boolean {
        if (this.closed) {
            return false;
        }
        const buffer = typeof chunk === "string" ? Buffer.from(chunk, "utf8") : Buffer.from(chunk);
        const host = getTcpHost();
        callHost(() => host.tcpWrite(this.connectionId, buffer.toString("base64")));
        return true;
    }

    //
    // Sends a range of a file to the connection, read and written natively.
    //
    // The bytes never enter the engine. Everything else here crosses the host bridge as base64: a
    // third larger than the bytes it carries, built on one side and decoded on the other, both in an
    // interpreter. Measured on a Pixel 6, a file being uploaded went through that twice, once to read
    // it and once to send it, and the phone managed about three megabytes a minute; the network was
    // idle nine tenths of the time.
    //
    writeFile(path: string, offset: number, length: number): boolean {
        if (this.closed) {
            return false;
        }
        const host = getTcpHost();
        const startedAt = Date.now();
        callHost(() => host.tcpWriteFile(this.connectionId, path, offset, length));

        // A send that took a noticeable time says how fast the network really is, which is the one
        // thing no code above this can change and the one thing nothing else here measures: a sync's
        // own timings cover a whole upload, and an upload is the request, the body and the server's
        // answer. A send that was quick says nothing, so it says nothing.
        const elapsedMs = Date.now() - startedAt;
        if (elapsedMs >= SLOW_SEND_MS) {
            console.log(`Sent ${length} bytes in ${elapsedMs}ms, ${Math.round(length / 1024 / elapsedMs)}MB/s.`);
        }
        return true;
    }

    //
    // Optionally writes a final chunk, then closes the connection.
    //
    end(chunk?: Buffer | Uint8Array | string): void {
        if (chunk !== undefined) {
            this.write(chunk);
        }
        this.close();
    }

    //
    // Closes the connection immediately (no final write).
    //
    destroy(): void {
        this.close();
    }

    //
    // Closes the native connection once and emits `close`.
    //
    private close(): void {
        if (this.closed) {
            return;
        }
        this.closed = true;
        this.readable = false;
        this.writable = false;
        activeSockets.delete(this.connectionId);
        const host = getTcpHost();
        callHost(() => host.tcpClose(this.connectionId));
        this.emit("close");
    }

    //
    // Delivers inbound bytes pushed from native (internal; called by the inbound dispatcher).
    //
    deliverData(base64: string): void {
        this.emit("data", Buffer.from(base64, "base64"));
    }

    //
    // Handles a remote-initiated close pushed from native: emits `end` then `close` once.
    //
    deliverClose(): void {
        if (this.closed) {
            return;
        }
        this.closed = true;
        this.readable = false;
        this.writable = false;
        activeSockets.delete(this.connectionId);
        this.emit("end");
        this.emit("close");
    }
}

//
// A listening TCP server. listen() binds a loopback port via the native host; each accepted
// connection is delivered as a `connection` event carrying a Socket. close() stops the listener.
//
export class Server extends TinyEmitter {
    //
    // The native listener id, set once listen() succeeds.
    //
    private listenerId: string | undefined = undefined;

    //
    // The bound port, set once listen() succeeds.
    //
    private boundPort = 0;

    //
    // The host the server bound to.
    //
    private boundHost = "127.0.0.1";

    //
    // Binds the server to a loopback port via the native host. host/port may be passed in either
    // order to match Node's overloads; a callback (if given) is registered for the `listening` event.
    //
    listen(port: number, host?: string | (() => void), callback?: () => void): this {
        const actualHost = typeof host === "string" ? host : "127.0.0.1";
        const actualCallback = typeof host === "function" ? host : callback;

        const tcpHost = getTcpHost();
        const resultJson = callHost(() => tcpHost.tcpListen(actualHost, port)) as string;
        const result = JSON.parse(resultJson) as ITcpListenResult;
        this.listenerId = result.listenerId;
        this.boundPort = result.port;
        this.boundHost = actualHost;
        activeServers.set(result.listenerId, this);

        if (actualCallback) {
            this.once("listening", actualCallback);
        }

        // Emit `listening` on a microtask so a synchronously-attached listener still observes it.
        Promise.resolve().then(() => {
            this.emit("listening");
        });

        return this;
    }

    //
    // Returns the bound address info (port/address/family), matching the subset http reads.
    //
    address(): IServerAddress {
        return { port: this.boundPort, address: this.boundHost, family: "IPv4" };
    }

    //
    // Stops the listener and emits `close`. The callback (if given) runs after the listener is closed.
    //
    close(callback?: () => void): this {
        if (this.listenerId !== undefined) {
            const tcpHost = getTcpHost();
            const listenerId = this.listenerId;
            activeServers.delete(listenerId);
            this.listenerId = undefined;
            callHost(() => tcpHost.tcpStopListening(listenerId));
        }
        this.emit("close");
        if (callback) {
            callback();
        }
        return this;
    }

    //
    // Builds a Socket for a native-accepted connection and emits `connection` (internal; called by
    // the inbound dispatcher).
    //
    acceptConnection(connectionId: string): void {
        const socket = new Socket(connectionId);
        activeSockets.set(connectionId, socket);
        this.emit("connection", socket);
    }
}

//
// The subset of a bound server address the net shim reports.
//
export interface IServerAddress {
    // The numeric bound port.
    port: number;

    // The bound host/interface.
    address: string;

    // The address family (always IPv4 for loopback here).
    family: string;
}

//
// Opens an outbound TCP connection and returns the connected socket, mirroring net.connect. Native
// completes the connect before returning, so the socket is usable immediately; `connect` is still
// emitted on a microtask for a caller that attaches its listener straight after this returns.
//
// This is what lets an `http://` endpoint be reached as plain HTTP, with no TLS anywhere in the path.
//
export function connect(port: number, host: string): Socket {
    const tcpHost = getTcpHost();
    const resultJson = callHost(() => tcpHost.tcpConnect(host, port)) as string;
    const result = JSON.parse(resultJson) as ITcpConnectResult;
    if (typeof result.connectionId !== "string" || result.connectionId.length === 0) {
        // Without an id the socket has nothing to write to and every send would vanish, so refuse here
        // rather than hand back a connection that looks open and silently discards the request.
        throw new Error(`host.tcpConnect(${host}, ${port}) returned no connectionId: ${resultJson}`);
    }
    const socket = new Socket(result.connectionId);
    activeSockets.set(result.connectionId, socket);

    Promise.resolve().then(() => {
        socket.emit("connect");
    });

    return socket;
}

//
// Creates a server, optionally registering a `connection` listener (matching net.createServer).
//
export function createServer(connectionListener?: (socket: Socket) => void): Server {
    const server = new Server();
    if (connectionListener) {
        server.on("connection", connectionListener);
    }
    return server;
}

//
// Routes one inbound event (pushed from native) to the right Server or Socket.
//
function dispatchInboundEvent(event: ITcpInboundEvent): void {
    if (event.kind === "connection") {
        if (event.listenerId === undefined || event.connectionId === undefined) {
            return;
        }
        const server = activeServers.get(event.listenerId);
        if (server) {
            server.acceptConnection(event.connectionId);
        }
        return;
    }

    if (event.kind === "data") {
        if (event.connectionId === undefined || event.base64 === undefined) {
            return;
        }
        const socket = activeSockets.get(event.connectionId);
        if (socket) {
            socket.deliverData(event.base64);
        }
        return;
    }

    if (event.kind === "close") {
        if (event.connectionId === undefined) {
            return;
        }
        const socket = activeSockets.get(event.connectionId);
        if (socket) {
            socket.deliverClose();
        }
    }
}

//
// Installs the inbound event entry point native calls to push connection/data/close events into the
// engine. Native passes the event as a JSON string so it crosses the bridge as a single argument.
//
export function installTcpInbound(globalScope: any = globalThis): void {
    globalScope.__tcpEvent = (eventJson: string): void => {
        const event = JSON.parse(eventJson) as ITcpInboundEvent;
        dispatchInboundEvent(event);
    };
}

// Install the inbound entry point on import so it exists before native delivers the first event.
installTcpInbound();

//
// Classifies a string as an IPv4/IPv6 address, mirroring net.isIP (0 = not an IP). Express references
// it when computing req.ip; the asset routes never read req.ip, so a minimal classifier suffices.
//
export function isIP(input: string): number {
    if (/^(\d{1,3}\.){3}\d{1,3}$/.test(input)) {
        return 4;
    }
    if (input.includes(":")) {
        return 6;
    }
    return 0;
}

//
// The default export mirrors `import net from "net"`.
//
const netModule = { AddressInfo, Server, Socket, connect, createServer, installTcpInbound, isIP };

export default netModule;

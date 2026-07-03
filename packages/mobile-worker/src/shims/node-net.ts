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

    // Writes base64-encoded bytes to an accepted connection.
    tcpWrite: (connectionId: string, base64: string) => string | null;

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
const netModule = { AddressInfo, Server, Socket, createServer, installTcpInbound, isIP };

export default netModule;

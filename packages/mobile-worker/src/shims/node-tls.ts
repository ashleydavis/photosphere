//
// `tls` shim for the embedded mobile worker.
//
// The bare embedded engine cannot perform a TLS handshake, which LAN-share needs (the receiver runs
// an HTTPS server with a self-signed cert; the sender connects with certificate pinning). This shim
// provides a client `connect()` and a `Server` built on five native host functions (tlsListen,
// tlsConnect, tlsWrite, tlsClose, tlsStopListening) plus an inbound event push: native delivers
// `connection` / `data` / `close` events by calling `globalThis.__tlsEvent`, which this module
// installs. It mirrors the `net` shim but over TLS, and additionally exposes the peer certificate on
// a client socket so the JS side can pin it. The `https` shim is layered on top of this.
//
// In the Node unit-test environment a mock host is installed on `globalThis.host` and inbound events
// are simulated by calling `globalThis.__tlsEvent` directly, so the layer is testable off-device.
//

import { Buffer } from "buffer";
import { callHost } from "./host-access";

//
// The TLS client trust mode, chosen explicitly per connection (no default):
//   - "pinned": native installs a trust-all manager and the JS side pins the peer cert itself (LAN
//     share, which presents a runtime self-signed cert).
//   - "validated": native performs real CA-chain and hostname validation (S3 over public HTTPS).
// This is a required argument so the S3 path can never accidentally downgrade to trust-all.
//
export type TlsConnectMode = "pinned" | "validated";

//
// The subset of native host functions the tls shim calls. Synchronous native callables following the
// same error-envelope convention as the other host functions; tlsListen/tlsConnect return JSON strings.
//
export interface ITlsHost {
    // Binds a TLS listener using the given PEM cert/key and returns a JSON string { listenerId, port }.
    tlsListen: (host: string, port: number, certPem: string, keyPem: string) => string;

    // Opens a TLS client connection in the given trust mode ("pinned" trusts any cert; "validated"
    // validates the CA chain and hostname) and returns a JSON string { connectionId, peerCertBase64 }.
    tlsConnect: (host: string, port: number, mode: string) => string;

    // Writes base64-encoded bytes to a TLS connection.
    tlsWrite: (connectionId: string, base64: string) => string | null;

    // Closes one TLS connection.
    tlsClose: (connectionId: string) => string | null;

    // Closes a TLS listener so it accepts no further connections.
    tlsStopListening: (listenerId: string) => string | null;
}

//
// The JSON shape native returns from tlsListen.
//
interface ITlsListenResult {
    // The opaque id used to stop this listener later.
    listenerId: string;

    // The actual bound port (resolved even when port 0 was requested).
    port: number;
}

//
// The JSON shape native returns from tlsConnect.
//
interface ITlsConnectResult {
    // The opaque id used to write to / close this connection later.
    connectionId: string;

    // The server's certificate in DER, base64-encoded, for JS-side pinning.
    peerCertBase64: string;
}

//
// An inbound TLS event pushed from native into the engine via globalThis.__tlsEvent.
//
interface ITlsInboundEvent {
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
// The peer certificate shape LAN-share reads: only `raw` (the DER bytes) is used, to compute the
// SHA-256 fingerprint for pinning.
//
export interface IPeerCertificate {
    // The certificate in DER form.
    raw: Buffer;
}

//
// A registered event listener.
//
type TlsListener = (...args: any[]) => void;

//
// Returns the installed native host bridge, throwing a clear error if it is missing.
//
function getTlsHost(): ITlsHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; tls shim cannot run.");
    }

    return host as ITlsHost;
}

//
// A tiny event emitter shared by TLSSocket and Server (mirrors the net shim's emitter).
//
class TinyEmitter {
    //
    // Listeners registered per event name.
    //
    private tlsListeners: Map<string, TlsListener[]> = new Map();

    //
    // Registers a listener for an event.
    //
    on(eventName: string, listener: TlsListener): this {
        const existing = this.tlsListeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.tlsListeners.set(eventName, [listener]);
        }
        return this;
    }

    //
    // Registers a one-shot listener that removes itself after firing once.
    //
    once(eventName: string, listener: TlsListener): this {
        const wrapper: TlsListener = (...args: any[]) => {
            this.off(eventName, wrapper);
            listener(...args);
        };
        return this.on(eventName, wrapper);
    }

    //
    // Removes a previously registered listener.
    //
    off(eventName: string, listener: TlsListener): this {
        const existing = this.tlsListeners.get(eventName);
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
        const handlers = this.tlsListeners.get(eventName);
        if (!handlers) {
            return;
        }
        for (const handler of handlers.slice()) {
            handler(...args);
        }
    }
}

//
// Registry of active TLS servers keyed by listenerId, used to route inbound "connection" events.
//
const activeTlsServers: Map<string, Server> = new Map();

//
// Registry of active TLS sockets keyed by connectionId, used to route inbound "data" / "close" events.
//
const activeTlsSockets: Map<string, TLSSocket> = new Map();

//
// A TLS connection (client-initiated or server-accepted). Reads arrive as `data` events (Buffers) and
// the remote close as `end` then `close`; writes go out via native tlsWrite; end()/destroy() close the
// connection via tlsClose. A client socket additionally carries the peer certificate for pinning.
//
export class TLSSocket extends TinyEmitter {
    //
    // The opaque native connection id this socket wraps.
    //
    readonly connectionId: string;

    //
    // The peer certificate DER (client sockets only), used by getPeerCertificate for pinning.
    //
    private peerCertBase64: string;

    //
    // True once the socket has been closed (locally or by the remote).
    //
    private closed = false;

    //
    // Wraps a native TLS connection id, optionally carrying the peer cert (client side).
    //
    constructor(connectionId: string, peerCertBase64: string = "") {
        super();
        this.connectionId = connectionId;
        this.peerCertBase64 = peerCertBase64;
    }

    //
    // Returns the peer certificate. Only `raw` (DER bytes) is populated, which is all LAN-share's
    // pinning check reads.
    //
    getPeerCertificate(): IPeerCertificate {
        return { raw: Buffer.from(this.peerCertBase64, "base64") };
    }

    //
    // Writes bytes to the connection. Strings are encoded utf-8; Buffers/Uint8Arrays are sent as-is.
    //
    write(chunk: Buffer | Uint8Array | string): boolean {
        if (this.closed) {
            return false;
        }
        const buffer = typeof chunk === "string" ? Buffer.from(chunk, "utf8") : Buffer.from(chunk);
        const host = getTlsHost();
        callHost(() => host.tlsWrite(this.connectionId, buffer.toString("base64")));
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
        activeTlsSockets.delete(this.connectionId);
        const host = getTlsHost();
        callHost(() => host.tlsClose(this.connectionId));
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
        activeTlsSockets.delete(this.connectionId);
        this.emit("end");
        this.emit("close");
    }
}

//
// A listening TLS server. listen() binds a loopback port via the native host using the configured
// cert/key; each accepted connection is delivered as a `secureConnection` event carrying a TLSSocket.
//
export class Server extends TinyEmitter {
    //
    // The PEM certificate presented to clients.
    //
    private certPem: string;

    //
    // The PEM private key for the certificate.
    //
    private keyPem: string;

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
    // Builds a TLS server presenting the given cert/key.
    //
    constructor(certPem: string, keyPem: string) {
        super();
        this.certPem = certPem;
        this.keyPem = keyPem;
    }

    //
    // Binds the server to a loopback port via the native host. host/port may be passed in either order
    // to match Node's overloads; a callback (if given) is registered for the `listening` event.
    //
    listen(port: number, host?: string | (() => void), callback?: () => void): this {
        // Default to all interfaces (0.0.0.0), matching Node's https.listen(0) with no host. LAN-share's
        // receiver must accept connections addressed to whatever interface its UDP broadcast advertised
        // (loopback for a same-device transfer, the LAN IP for a cross-device one), not just loopback.
        const actualHost = typeof host === "string" ? host : "0.0.0.0";
        const actualCallback = typeof host === "function" ? host : callback;

        const tlsHost = getTlsHost();
        const resultJson = callHost(() => tlsHost.tlsListen(actualHost, port, this.certPem, this.keyPem)) as string;
        const result = JSON.parse(resultJson) as ITlsListenResult;
        this.listenerId = result.listenerId;
        this.boundPort = result.port;
        this.boundHost = actualHost;
        activeTlsServers.set(result.listenerId, this);

        if (actualCallback) {
            this.once("listening", actualCallback);
        }

        Promise.resolve().then(() => {
            this.emit("listening");
        });

        return this;
    }

    //
    // Returns the bound address info (port/address/family), matching the subset callers read.
    //
    address(): ITlsServerAddress {
        return { port: this.boundPort, address: this.boundHost, family: "IPv4" };
    }

    //
    // Stops the listener and emits `close`. The callback (if given) runs after the listener is closed.
    //
    close(callback?: () => void): this {
        if (this.listenerId !== undefined) {
            const tlsHost = getTlsHost();
            const listenerId = this.listenerId;
            activeTlsServers.delete(listenerId);
            this.listenerId = undefined;
            callHost(() => tlsHost.tlsStopListening(listenerId));
        }
        this.emit("close");
        if (callback) {
            callback();
        }
        return this;
    }

    //
    // Builds a TLSSocket for a native-accepted connection and emits `secureConnection` (internal;
    // called by the inbound dispatcher).
    //
    acceptConnection(connectionId: string): void {
        const socket = new TLSSocket(connectionId);
        activeTlsSockets.set(connectionId, socket);
        this.emit("secureConnection", socket);
    }
}

//
// The subset of a bound server address the tls shim reports.
//
export interface ITlsServerAddress {
    // The numeric bound port.
    port: number;

    // The bound host/interface.
    address: string;

    // The address family (always IPv4 for loopback here).
    family: string;
}

//
// Options accepted by createServer, matching the subset LAN-share uses.
//
export interface ITlsServerOptions {
    // PEM private key.
    key: string;

    // PEM certificate.
    cert: string;
}

//
// Creates a TLS server presenting the given cert/key, optionally registering a `secureConnection`
// listener (matching tls.createServer).
//
export function createServer(options: ITlsServerOptions, connectionListener?: (socket: TLSSocket) => void): Server {
    const server = new Server(options.cert, options.key);
    if (connectionListener) {
        server.on("secureConnection", connectionListener);
    }
    return server;
}

//
// Opens a TLS client connection. Matches the subset of tls.connect callers use: a port, a host, and an
// optional `secureConnect` callback. The handshake completes synchronously in native (tlsConnect
// returns the peer cert), so `secureConnect` is emitted on a microtask.
//
export function connect(port: number, host: string, mode: TlsConnectMode, options?: (() => void) | Record<string, unknown>, callback?: () => void): TLSSocket {
    const actualHost = typeof host === "string" ? host : "127.0.0.1";
    const actualCallback = typeof options === "function" ? options : callback;

    const tlsHost = getTlsHost();
    const resultJson = callHost(() => tlsHost.tlsConnect(actualHost, port, mode)) as string;
    const result = JSON.parse(resultJson) as ITlsConnectResult;
    const socket = new TLSSocket(result.connectionId, result.peerCertBase64);
    activeTlsSockets.set(result.connectionId, socket);

    if (actualCallback) {
        socket.once("secureConnect", actualCallback);
    }

    Promise.resolve().then(() => {
        socket.emit("secureConnect");
    });

    return socket;
}

//
// Opens a TLS client connection in the given trust mode and returns the connected socket WITHOUT
// scheduling a `secureConnect` event. The handshake has already completed in native (the peer cert is
// available immediately), so the caller drives the `secureConnect` timing itself. Used by the `https`
// shim, which must emit the request's `socket` event before firing `secureConnect` so a pinning
// listener attached in the `socket` handler observes the handshake.
//
export function connectClient(port: number, host: string, mode: TlsConnectMode): TLSSocket {
    const tlsHost = getTlsHost();
    const resultJson = callHost(() => tlsHost.tlsConnect(host, port, mode)) as string;
    const result = JSON.parse(resultJson) as ITlsConnectResult;
    const socket = new TLSSocket(result.connectionId, result.peerCertBase64);
    activeTlsSockets.set(result.connectionId, socket);
    return socket;
}

//
// Routes one inbound TLS event (pushed from native) to the right Server or TLSSocket.
//
function dispatchInboundEvent(event: ITlsInboundEvent): void {
    if (event.kind === "connection") {
        if (event.listenerId === undefined || event.connectionId === undefined) {
            return;
        }
        const server = activeTlsServers.get(event.listenerId);
        if (server) {
            server.acceptConnection(event.connectionId);
        }
        return;
    }

    if (event.kind === "data") {
        if (event.connectionId === undefined || event.base64 === undefined) {
            return;
        }
        const socket = activeTlsSockets.get(event.connectionId);
        if (socket) {
            socket.deliverData(event.base64);
        }
        return;
    }

    if (event.kind === "close") {
        if (event.connectionId === undefined) {
            return;
        }
        const socket = activeTlsSockets.get(event.connectionId);
        if (socket) {
            socket.deliverClose();
        }
    }
}

//
// Installs the inbound event entry point native calls to push connection/data/close events into the
// engine. Native passes the event as a JSON string so it crosses the bridge as a single argument.
//
export function installTlsInbound(globalScope: any = globalThis): void {
    globalScope.__tlsEvent = (eventJson: string): void => {
        const event = JSON.parse(eventJson) as ITlsInboundEvent;
        dispatchInboundEvent(event);
    };
}

// Install the inbound entry point on import so it exists before native delivers the first event.
installTlsInbound();

//
// The default export mirrors `import tls from "tls"`.
//
const tlsModule = { TLSSocket, Server, createServer, connect, connectClient, installTlsInbound };

export default tlsModule;

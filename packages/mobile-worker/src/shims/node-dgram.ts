//
// `dgram` shim for the embedded mobile worker.
//
// The bare embedded engine (QuickJS/JavaScriptCore) cannot open UDP sockets, which LAN-share
// discovery needs (the receiver broadcasts `PSIE_RECV:...` and the sender listens for it). This
// shim provides a `dgram.Socket` built on three native host functions (udpBind, udpSend, udpClose)
// plus an inbound event push: native delivers `message` events into the engine by calling
// `globalThis.__udpEvent`, which this module installs.
//
// In the Node unit-test environment a mock host is installed on `globalThis.host` and inbound
// messages are simulated by calling `globalThis.__udpEvent` directly, so the layer is testable
// off-device, matching the `net`/`http` shim convention.
//

import { Buffer } from "buffer";
import { callHost } from "./host-access";

//
// The subset of native host functions the dgram shim calls. Synchronous native callables following
// the same error-envelope convention as the other host functions; udpBind returns a JSON string.
//
export interface IUdpHost {
    // Binds a UDP socket (broadcast enabled when requested) and returns a JSON string { socketId, port }.
    udpBind: (host: string, port: number, broadcast: boolean) => string;

    // Sends base64-encoded bytes as a datagram to the given host/port from a bound socket.
    udpSend: (socketId: string, base64: string, host: string, port: number) => string | null;

    // Closes a UDP socket.
    udpClose: (socketId: string) => string | null;
}

//
// The JSON shape native returns from udpBind.
//
interface IUdpBindResult {
    // The opaque id used to send from / close this socket later.
    socketId: string;

    // The actual bound port (resolved even when port 0 was requested).
    port: number;
}

//
// An inbound UDP event pushed from native into the engine via globalThis.__udpEvent.
//
interface IUdpInboundEvent {
    // The event kind: only "message" (an inbound datagram) for now.
    kind: "message";

    // The socket the datagram arrived on.
    socketId: string;

    // The sender's address.
    address: string;

    // The sender's port.
    port: number;

    // Base64-encoded datagram payload.
    base64: string;
}

//
// Remote-sender info handed to a `message` listener, matching the subset of Node's `RemoteInfo`
// that LAN-share reads (address; port/family included for completeness).
//
export interface IRemoteInfo {
    // The sender's IP address.
    address: string;

    // The sender's port.
    port: number;

    // The address family (always IPv4 here).
    family: string;

    // The datagram size in bytes.
    size: number;
}

//
// Options accepted by createSocket, matching the subset LAN-share uses.
//
export interface ISocketOptions {
    // The socket type; only "udp4" is supported.
    type: "udp4";

    // Whether to allow address reuse (native always reuses; accepted for API compatibility).
    reuseAddr?: boolean;
}

//
// A registered event listener.
//
type UdpListener = (...args: any[]) => void;

//
// Returns the installed native host bridge, throwing a clear error if it is missing.
//
function getUdpHost(): IUdpHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; dgram shim cannot run.");
    }

    return host as IUdpHost;
}

//
// A tiny event emitter shared internally by Socket. Self-contained so the dgram shim does not depend
// on Node's `events` module resolving in the engine (mirrors the net shim's emitter).
//
class TinyEmitter {
    //
    // Listeners registered per event name.
    //
    private udpListeners: Map<string, UdpListener[]> = new Map();

    //
    // Registers a listener for an event.
    //
    on(eventName: string, listener: UdpListener): this {
        const existing = this.udpListeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.udpListeners.set(eventName, [listener]);
        }
        return this;
    }

    //
    // Registers a one-shot listener that removes itself after firing once.
    //
    once(eventName: string, listener: UdpListener): this {
        const wrapper: UdpListener = (...args: any[]) => {
            this.off(eventName, wrapper);
            listener(...args);
        };
        return this.on(eventName, wrapper);
    }

    //
    // Removes a previously registered listener.
    //
    off(eventName: string, listener: UdpListener): this {
        const existing = this.udpListeners.get(eventName);
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
        const handlers = this.udpListeners.get(eventName);
        if (!handlers) {
            return;
        }
        for (const handler of handlers.slice()) {
            handler(...args);
        }
    }
}

//
// Registry of active sockets keyed by socketId, used to route inbound "message" events.
//
const activeUdpSockets: Map<string, Socket> = new Map();

//
// A UDP datagram socket. Inbound datagrams arrive as `message` events (Buffer, RemoteInfo); outbound
// datagrams go out via native udpSend; close() releases the native socket.
//
export class Socket extends TinyEmitter {
    //
    // The opaque native socket id, set once bind() succeeds.
    //
    private socketId: string | undefined = undefined;

    //
    // The bound port, set once bind() succeeds.
    //
    private boundPort = 0;

    //
    // True once the socket has been closed.
    //
    private closed = false;

    //
    // Binds the socket. Node overloads: bind(), bind(port), bind(port, cb), bind(cb). The callback (or
    // any synchronously-attached `listening` listener) fires on a microtask, matching Node's async bind.
    // Broadcast is enabled natively at bind so both sending to and receiving broadcast addresses work;
    // setBroadcast() is therefore a no-op (see below).
    //
    bind(portOrCallback?: number | (() => void), callback?: () => void): this {
        const port = typeof portOrCallback === "number" ? portOrCallback : 0;
        const actualCallback = typeof portOrCallback === "function" ? portOrCallback : callback;

        const host = getUdpHost();
        // Bind to the wildcard address so the socket receives both loopback and broadcast datagrams.
        const resultJson = callHost(() => host.udpBind("0.0.0.0", port, true)) as string;
        const result = JSON.parse(resultJson) as IUdpBindResult;
        this.socketId = result.socketId;
        this.boundPort = result.port;
        activeUdpSockets.set(result.socketId, this);

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
    // No-op: broadcast is enabled natively at bind (LAN-share is the only consumer and always wants
    // it). Kept so LAN-share's `setBroadcast(true)` call resolves.
    //
    setBroadcast(_flag: boolean): void {
        // Intentionally empty.
    }

    //
    // Sends a datagram. Matches Node's send(msg, offset, length, port, address[, callback]); the slice
    // [offset, offset+length) is transmitted. The callback (if given) fires on a microtask.
    //
    send(message: Buffer | Uint8Array | string, offset: number, length: number, port: number, address: string, callback?: (error: Error | null) => void): void {
        if (this.socketId === undefined || this.closed) {
            if (callback) {
                callback(new Error("send on a closed or unbound udp socket"));
            }
            return;
        }
        const full = typeof message === "string" ? Buffer.from(message, "utf8") : Buffer.from(message);
        const slice = full.subarray(offset, offset + length);
        const host = getUdpHost();
        const socketId = this.socketId;
        callHost(() => host.udpSend(socketId, slice.toString("base64"), address, port));
        if (callback) {
            Promise.resolve().then(() => callback(null));
        }
    }

    //
    // Returns the bound address info (port/address/family), matching the subset callers read.
    //
    address(): IRemoteInfo {
        return { address: "0.0.0.0", port: this.boundPort, family: "IPv4", size: 0 };
    }

    //
    // Closes the native socket once and emits `close`. The callback (if given) runs after close.
    //
    close(callback?: () => void): void {
        if (this.closed) {
            if (callback) {
                callback();
            }
            return;
        }
        this.closed = true;
        if (this.socketId !== undefined) {
            const host = getUdpHost();
            const socketId = this.socketId;
            activeUdpSockets.delete(socketId);
            this.socketId = undefined;
            callHost(() => host.udpClose(socketId));
        }
        this.emit("close");
        if (callback) {
            callback();
        }
    }

    //
    // Delivers an inbound datagram pushed from native (internal; called by the inbound dispatcher).
    //
    deliverMessage(base64: string, address: string, port: number): void {
        const buffer = Buffer.from(base64, "base64");
        const remoteInfo: IRemoteInfo = { address, port, family: "IPv4", size: buffer.length };
        this.emit("message", buffer, remoteInfo);
    }
}

//
// Creates a UDP socket. Accepts the type string ("udp4") or an options object, matching
// dgram.createSocket. An optional message listener can be registered inline. Only "udp4" is
// supported: the native host bridge opens IPv4 sockets only, so any other type (notably "udp6")
// throws rather than silently binding an IPv4 socket a caller believes is IPv6.
//
export function createSocket(typeOrOptions: "udp4" | ISocketOptions, messageListener?: (message: Buffer, remoteInfo: IRemoteInfo) => void): Socket {
    const socketType = typeof typeOrOptions === "string" ? typeOrOptions : typeOrOptions.type;
    if (socketType !== "udp4") {
        throw new Error(`dgram shim only supports "udp4" sockets; "${socketType}" is not supported.`);
    }

    const socket = new Socket();
    if (messageListener) {
        socket.on("message", messageListener);
    }
    return socket;
}

//
// Routes one inbound UDP event (pushed from native) to the right Socket.
//
function dispatchInboundEvent(event: IUdpInboundEvent): void {
    if (event.kind !== "message") {
        return;
    }
    const socket = activeUdpSockets.get(event.socketId);
    if (socket) {
        socket.deliverMessage(event.base64, event.address, event.port);
    }
}

//
// Installs the inbound event entry point native calls to push datagrams into the engine. Native passes
// the event as a JSON string so it crosses the bridge as a single argument.
//
export function installUdpInbound(globalScope: any = globalThis): void {
    globalScope.__udpEvent = (eventJson: string): void => {
        const event = JSON.parse(eventJson) as IUdpInboundEvent;
        dispatchInboundEvent(event);
    };
}

// Install the inbound entry point on import so it exists before native delivers the first datagram.
installUdpInbound();

//
// The default export mirrors `import dgram from "dgram"`.
//
const dgramModule = { Socket, createSocket, installUdpInbound };

export default dgramModule;

//
// `http` shim for the embedded mobile worker.
//
// The bare embedded engine (QuickJS/JavaScriptCore) has no `http` module. This shim implements the
// minimal HTTP/1.1 server the express asset server needs, layered on the `net` shim (which is backed
// by the native TCP host functions). `createServer(requestListener)` returns a server that, for each
// accepted connection, parses one request into an `IncomingMessage` (a readable-stream-like source of
// the body) and provides a `ServerResponse` (a writable-stream-like sink) that serialises the status
// line, headers, and Content-Length-framed body back to the socket.
//
// IncomingMessage/ServerResponse are self-contained event emitters (NOT subclasses of the `stream`
// module), because on device the `stream` shim is a minimal whole-buffer implementation with no real
// Readable/Writable plumbing. They expose exactly the duck-typed surface express, raw-body, and the
// `stream/promises` `pipeline` use: on/once/emit, push (req), and write/end/setHeader (res).
//

import { Buffer } from "buffer";
import { connect as netConnect, createServer as netCreateServer, type Server as NetServer, type Socket } from "./node-net";

//
// A registered event listener.
//
type HttpListener = (...args: any[]) => void;

//
// A tiny event emitter providing the subset of the Node EventEmitter surface express, raw-body, and
// on-finished use on these request/response objects.
//
class HttpEmitter {
    //
    // Listeners registered per event name.
    //
    private httpListeners: Map<string, HttpListener[]> = new Map();

    //
    // Registers an event listener.
    //
    on(eventName: string, listener: HttpListener): this {
        const existing = this.httpListeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.httpListeners.set(eventName, [listener]);
        }
        return this;
    }

    //
    // Alias of on(), matching the Node EventEmitter surface.
    //
    addListener(eventName: string, listener: HttpListener): this {
        return this.on(eventName, listener);
    }

    //
    // Registers a one-shot listener that removes itself after firing once.
    //
    once(eventName: string, listener: HttpListener): this {
        const wrapper: HttpListener = (...args: any[]) => {
            this.removeListener(eventName, wrapper);
            listener(...args);
        };
        return this.on(eventName, wrapper);
    }

    //
    // Removes a previously registered listener.
    //
    removeListener(eventName: string, listener: HttpListener): this {
        const existing = this.httpListeners.get(eventName);
        if (existing) {
            const index = existing.indexOf(listener);
            if (index >= 0) {
                existing.splice(index, 1);
            }
        }
        return this;
    }

    //
    // Returns the listeners registered for an event (a copy).
    //
    listeners(eventName: string): HttpListener[] {
        return (this.httpListeners.get(eventName) || []).slice();
    }

    //
    // Emits an event to all registered listeners.
    //
    emit(eventName: string, ...args: any[]): boolean {
        const handlers = this.httpListeners.get(eventName);
        if (!handlers || handlers.length === 0) {
            return false;
        }
        for (const handler of handlers.slice()) {
            handler(...args);
        }
        return true;
    }
}

//
// Reason phrases for the status codes the asset server emits. Unknown codes fall back to "OK".
//
const REASON_PHRASES: Record<number, string> = {
    200: "OK",
    204: "No Content",
    400: "Bad Request",
    404: "Not Found",
    500: "Internal Server Error",
};

//
// Parsed request head (request line + headers).
//
interface IParsedHead {
    // The HTTP method (uppercase).
    method: string;

    // The request target (path + query).
    url: string;

    // Lowercased header name to value map.
    headers: Record<string, string>;
}

//
// Parses the request line and headers from the text before the blank line.
//
function parseHead(headerText: string): IParsedHead {
    const lines = headerText.split("\r\n");
    const requestLine = lines[0] || "";
    const parts = requestLine.split(" ");
    const method = (parts[0] || "GET").toUpperCase();
    const url = parts[1] || "/";

    const headers: Record<string, string> = {};
    for (let index = 1; index < lines.length; index++) {
        const line = lines[index];
        const colon = line.indexOf(":");
        if (colon > 0) {
            const name = line.slice(0, colon).trim().toLowerCase();
            const value = line.slice(colon + 1).trim();
            headers[name] = value;
        }
    }

    return { method, url, headers };
}

//
// An inbound HTTP request, presented as a readable-stream-like source of the request body. Body bytes
// are pushed in by the server as they arrive; consumers (express.json / raw-body) read via the
// `data` / `end` events.
//
export class IncomingMessage extends HttpEmitter {
    //
    // The HTTP method (e.g. GET, POST).
    //
    method: string;

    //
    // The request target (path and query string).
    //
    url: string;

    //
    // Lowercased request headers.
    //
    headers: Record<string, string>;

    //
    // The HTTP version string (always 1.1 here).
    //
    httpVersion = "1.1";

    //
    // True until the request body has fully arrived; raw-body / on-finished read this.
    //
    complete = false;

    //
    // Whether the stream is still readable. Kept true until end.
    //
    readable = true;

    //
    // Body-parser checks `req._body` to skip already-parsed requests; declare it false so a body
    // parser always reads the body (and is not confused by an inherited/stale value).
    //
    _body = false;

    //
    // raw-body reads `stream._readableState`; provide a minimal object so it does not throw.
    //
    _readableState: { encoding: string | null } = { encoding: null };

    //
    // The underlying connection (express reads req.socket; on-finished may attach to it).
    //
    socket: Socket;

    //
    // Alias of socket, matching the Node http request surface.
    //
    connection: Socket;

    //
    // True once a consumer has started reading (a `data` listener attached or resume() called). Until
    // then the request behaves like a paused stream and buffers pushed body bytes.
    //
    private flowing = false;

    //
    // Body chunks pushed before a consumer started reading.
    //
    private buffered: Buffer[] = [];

    //
    // True once the body has fully arrived but the stream is not yet flowing; the `end` fires on flush.
    //
    private endPending = false;

    //
    // Guards against scheduling more than one deferred flush.
    //
    private flushScheduled = false;

    //
    // Builds an incoming message bound to its connection.
    //
    constructor(method: string, url: string, headers: Record<string, string>, socket: Socket) {
        super();
        this.method = method;
        this.url = url;
        this.headers = headers;
        this.socket = socket;
        this.connection = socket;
    }

    //
    // Registers a listener. Attaching a `data` listener starts the stream flowing (matching Node's
    // paused-mode semantics), so body bytes pushed before the body parser attached are still delivered.
    //
    on(eventName: string, listener: (...args: any[]) => void): this {
        super.on(eventName, listener);
        if (eventName === "data" && !this.flowing) {
            this.startFlowing();
        }
        return this;
    }

    //
    // Pushes body bytes (or null to signal end). While paused the bytes are buffered; once flowing they
    // are emitted as `data` events, followed by `end` when null is pushed.
    //
    push(chunk: Buffer | null): boolean {
        if (chunk === null) {
            if (this.flowing && !this.flushScheduled) {
                this.finishEnd();
            }
            else {
                this.endPending = true;
            }
            return false;
        }
        if (this.flowing && !this.flushScheduled) {
            this.emit("data", chunk);
        }
        else {
            this.buffered.push(chunk);
        }
        return true;
    }

    //
    // Starts the stream flowing and schedules the buffered body to be delivered on a microtask, so any
    // listeners the consumer attaches synchronously right after the first one (e.g. raw-body's `end`
    // handler attached just after its `data` handler) are in place before the events fire.
    //
    private startFlowing(): void {
        if (this.flowing) {
            return;
        }
        this.flowing = true;
        this.flushScheduled = true;
        Promise.resolve().then(() => {
            const chunks = this.buffered;
            this.buffered = [];
            this.flushScheduled = false;
            for (const chunk of chunks) {
                this.emit("data", chunk);
            }
            if (this.endPending) {
                this.finishEnd();
            }
        });
    }

    //
    // Emits the terminal `end` and marks the request complete.
    //
    private finishEnd(): void {
        this.complete = true;
        this.readable = false;
        this.emit("end");
    }

    //
    // Starts the stream flowing (paused-mode resume).
    //
    resume(): this {
        if (!this.flowing) {
            this.startFlowing();
        }
        return this;
    }

    //
    // No-op pause to match the readable surface.
    //
    pause(): this {
        return this;
    }

    //
    // No-op setEncoding; the body parsers used here accept Buffers.
    //
    setEncoding(): this {
        return this;
    }

    //
    // No-op unpipe. raw-body calls `unpipe(req)`; when this method is absent that helper falls back to
    // stripping the stream's own `data` listeners (which would discard the body parser's collector).
    // Providing a no-op keeps the listeners intact so the body is read.
    //
    unpipe(): this {
        return this;
    }

    //
    // Forwards the body into a writable destination and returns it, so `source.pipe(dest)` behaves as
    // Node's does.
    //
    // The inbound server parsers consume via `data`/`end` events and never call this, but the AWS SDK
    // pipes a response body into its checksum stream. While this was a no-op that returned the
    // destination untouched, no bytes ever reached that stream: the response never ended, the SDK's
    // collector never finished, and an S3 read simply hung until the 30s retry timeout fired.
    //
    pipe(destination: any): any {
        this.on("data", (chunk: Buffer) => {
            destination.write(chunk);
        });
        this.on("end", () => {
            if (destination.end) {
                destination.end();
            }
        });
        return destination;
    }

    //
    // Marks the stream destroyed (no underlying resource to release here).
    //
    destroy(): this {
        this.readable = false;
        return this;
    }
}

//
// An outbound HTTP response, presented as a writable-stream-like sink. Written chunks are buffered and,
// when the response ends, the full response (status line, headers, Content-Length, body) is serialised
// to the socket in one go and the connection is closed.
//
export class ServerResponse extends HttpEmitter {
    //
    // The HTTP status code to send (defaults to 200).
    //
    statusCode = 200;

    //
    // The optional status message; computed from statusCode when not set.
    //
    statusMessage: string | undefined = undefined;

    //
    // True once the response head has been written to the socket.
    //
    headersSent = false;

    //
    // True once the response has been fully sent.
    //
    finished = false;

    //
    // True once end() has been called (Node writableEnded).
    //
    writableEnded = false;

    //
    // The underlying connection (some middleware reads res.socket).
    //
    socket: Socket;

    //
    // Alias of socket, matching the Node http response surface.
    //
    connection: Socket;

    //
    // Lowercased outbound header name to value map.
    //
    private outboundHeaders: Map<string, string> = new Map();

    //
    // Buffered response body chunks, flushed on end.
    //
    private bodyChunks: Buffer[] = [];

    //
    // Builds a response bound to its connection.
    //
    constructor(socket: Socket) {
        super();
        this.socket = socket;
        this.connection = socket;
    }

    //
    // Sets an outbound header (case-insensitive name).
    //
    setHeader(name: string, value: string | number | string[]): this {
        this.outboundHeaders.set(name.toLowerCase(), Array.isArray(value) ? value.join(", ") : String(value));
        return this;
    }

    //
    // Returns a previously set outbound header (case-insensitive), or undefined.
    //
    getHeader(name: string): string | undefined {
        return this.outboundHeaders.get(name.toLowerCase());
    }

    //
    // Returns whether an outbound header is set (case-insensitive).
    //
    hasHeader(name: string): boolean {
        return this.outboundHeaders.has(name.toLowerCase());
    }

    //
    // Removes a previously set outbound header (case-insensitive).
    //
    removeHeader(name: string): void {
        this.outboundHeaders.delete(name.toLowerCase());
    }

    //
    // Returns the set outbound header names.
    //
    getHeaderNames(): string[] {
        return Array.from(this.outboundHeaders.keys());
    }

    //
    // Records the status code and optional headers (matching res.writeHead). The head is not sent
    // until the response ends, so this only updates the pending status/headers.
    //
    writeHead(statusCode: number, headersOrMessage?: string | Record<string, string | number>, headers?: Record<string, string | number>): this {
        this.statusCode = statusCode;
        let headerObject: Record<string, string | number> | undefined = headers;
        if (typeof headersOrMessage === "string") {
            this.statusMessage = headersOrMessage;
        }
        else if (headersOrMessage) {
            headerObject = headersOrMessage;
        }
        if (headerObject) {
            for (const name of Object.keys(headerObject)) {
                this.setHeader(name, headerObject[name]);
            }
        }
        return this;
    }

    //
    // Buffers a written chunk. Returns true (never applies backpressure).
    //
    write(chunk: Buffer | Uint8Array | string): boolean {
        if (chunk !== undefined && chunk !== null) {
            this.bodyChunks.push(typeof chunk === "string" ? Buffer.from(chunk, "utf8") : Buffer.from(chunk));
        }
        return true;
    }

    //
    // Optionally writes a final chunk, then serialises the full response to the socket and closes the
    // connection. Emits `finish` then `close` (the events on-finished and the pipeline shim await).
    //
    end(chunk?: Buffer | Uint8Array | string): this {
        if (this.finished) {
            return this;
        }
        if (chunk !== undefined && chunk !== null) {
            this.write(chunk);
        }

        const body = Buffer.concat(this.bodyChunks);

        if (!this.outboundHeaders.has("content-length")) {
            this.outboundHeaders.set("content-length", String(body.length));
        }

        // The server closes the connection after each response (no keep-alive), so tell the client not
        // to reuse the socket.
        this.outboundHeaders.set("connection", "close");

        const reason = this.statusMessage || REASON_PHRASES[this.statusCode] || "OK";
        let head = `HTTP/1.1 ${this.statusCode} ${reason}\r\n`;
        for (const [name, value] of this.outboundHeaders) {
            head += `${name}: ${value}\r\n`;
        }
        head += "\r\n";

        this.headersSent = true;
        this.writableEnded = true;
        this.socket.write(Buffer.concat([Buffer.from(head, "utf8"), body]));
        this.socket.end();
        this.finished = true;

        this.emit("finish");
        this.emit("close");
        return this;
    }
}

//
// A minimal HTTP server over the net shim. Each accepted connection carries one request, which is
// parsed and handed to the request listener (the express app).
//
export class Server {
    //
    // The underlying net server accepting TCP connections.
    //
    private netServer: NetServer;

    //
    // The request listener (the express application) invoked per parsed request.
    //
    private requestListener: (req: IncomingMessage, res: ServerResponse) => void;

    //
    // Listeners registered on the http server itself (e.g. `error`, `listening`).
    //
    private serverEmitter: HttpEmitter = new HttpEmitter();

    //
    // Builds a server that routes each accepted connection's parsed request to the listener.
    //
    constructor(requestListener: (req: IncomingMessage, res: ServerResponse) => void) {
        this.requestListener = requestListener;
        this.netServer = netCreateServer((socket: Socket) => this.handleConnection(socket));
    }

    //
    // Registers a server-level event listener.
    //
    on(eventName: string, listener: HttpListener): this {
        this.serverEmitter.on(eventName, listener);
        return this;
    }

    //
    // Registers a one-shot server-level event listener.
    //
    once(eventName: string, listener: HttpListener): this {
        this.serverEmitter.once(eventName, listener);
        return this;
    }

    //
    // Binds the server's loopback port via the net server. The callback (and the `listening` event)
    // fire once bound.
    //
    listen(port: number, host?: string | (() => void), callback?: () => void): this {
        const actualHost = typeof host === "string" ? host : "127.0.0.1";
        const actualCallback = typeof host === "function" ? host : callback;
        this.netServer.listen(port, actualHost, () => {
            this.serverEmitter.emit("listening");
            if (actualCallback) {
                actualCallback();
            }
        });
        return this;
    }

    //
    // Returns the bound address info from the net server.
    //
    address(): { port: number; address: string; family: string } {
        return this.netServer.address();
    }

    //
    // Closes the server; the callback runs once the listener is stopped.
    //
    close(callback?: () => void): this {
        this.netServer.close(callback);
        this.serverEmitter.emit("close");
        return this;
    }

    //
    // Parses one request off an accepted connection and dispatches it to the request listener.
    //
    private handleConnection(socket: Socket): void {
        let buffer = Buffer.alloc(0);
        let headersParsed = false;
        let request: IncomingMessage | undefined = undefined;
        let bodyRemaining = 0;

        const feedBody = (chunk: Buffer): void => {
            if (!request) {
                return;
            }
            if (bodyRemaining > 0) {
                const take = chunk.subarray(0, bodyRemaining);
                request.push(take);
                bodyRemaining -= take.length;
            }
            if (bodyRemaining <= 0) {
                request.push(null);
            }
        };

        socket.on("data", (chunk: Buffer) => {
            if (headersParsed) {
                feedBody(chunk);
                return;
            }

            buffer = Buffer.concat([buffer, chunk]);
            const terminator = buffer.indexOf("\r\n\r\n");
            if (terminator === -1) {
                return;
            }

            const headerText = buffer.subarray(0, terminator).toString("utf8");
            const remainder = buffer.subarray(terminator + 4);
            const parsed = parseHead(headerText);
            headersParsed = true;

            request = new IncomingMessage(parsed.method, parsed.url, parsed.headers, socket);
            const response = new ServerResponse(socket);

            const contentLength = parseInt(parsed.headers["content-length"] || "0", 10);
            bodyRemaining = Number.isNaN(contentLength) ? 0 : contentLength;

            this.requestListener(request, response);
            this.serverEmitter.emit("request", request, response);

            if (bodyRemaining > 0 && remainder.length > 0) {
                feedBody(remainder);
            }
            else if (bodyRemaining <= 0) {
                request.push(null);
            }
        });

        socket.on("end", () => {
            if (request && bodyRemaining > 0) {
                request.push(null);
            }
        });
    }
}

//
// Creates an HTTP server bound to the given request listener (the express app), mirroring http.createServer.
//
export function createServer(requestListener: (req: IncomingMessage, res: ServerResponse) => void): Server {
    return new Server(requestListener);
}

//
// Standard status code to reason-phrase map. Express reads `http.STATUS_CODES` for res.statusMessage
// lookups; only the codes the asset server emits need real phrases, but a fuller set is harmless.
//
export const STATUS_CODES: Record<number, string> = {
    200: "OK",
    201: "Created",
    204: "No Content",
    301: "Moved Permanently",
    302: "Found",
    304: "Not Modified",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    500: "Internal Server Error",
    501: "Not Implemented",
    503: "Service Unavailable",
};

//
// The HTTP methods express registers app.METHOD routes for. Express falls back to its own list when
// `http.METHODS` is absent, but providing it keeps the two in sync.
//
export const METHODS: string[] = [
    "GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH",
];

//
// The transport surface the client needs from a socket. Both `node-net`'s Socket and `node-tls`'s
// TLSSocket satisfy it, which is what lets one client serve http and https.
//
export interface IClientTransport {
    // Sends bytes over the connection.
    write(chunk: Buffer | Uint8Array | string): boolean;

    // Closes the connection.
    destroy(): void;

    // Registers a listener for `data`, `end` or `close`.
    on(eventName: string, listener: (...args: any[]) => void): any;

    // Raises an event on the transport (used to signal the TLS handshake to a pinning listener).
    emit(eventName: string, ...args: any[]): void;
}

//
// A client HTTP response: an IncomingMessage carrying the numeric status code from the response line.
//
export interface IClientResponse extends IncomingMessage {
    // The HTTP status code from the response status line.
    statusCode: number;
}

//
// The request options the client accepts, matching the subset its callers pass.
//
export interface IClientRequestOptions {
    // The target host. Node accepts either spelling; `hostname` wins when both are given.
    hostname?: string;

    // The target host, as `@smithy/node-http-handler` spells it.
    host?: string;

    // The target port. Defaults to the scheme's standard port.
    port?: number;

    // The request target (path and query string).
    path?: string;

    // The HTTP method.
    method?: string;

    // Outbound headers.
    headers?: Record<string, string | number | undefined>;

    // Accepted and ignored: one connection is opened per request, so there is no pool to configure.
    agent?: unknown;

    // Accepted and ignored; no caller sends HTTP basic auth.
    auth?: string;

    // Node's TLS trust option. Only the https shim acts on it; over plain TCP there is nothing to
    // validate, so it is accepted and ignored here.
    rejectUnauthorized?: boolean;
}

//
// Parsed response head: the status line plus the headers before the blank line.
//
interface IParsedResponseHead {
    // The numeric HTTP status code.
    statusCode: number;

    // Lowercased header name to value map.
    headers: Record<string, string>;
}

//
// Parses the response status line and headers out of the head text.
//
function parseResponseHead(headerText: string): IParsedResponseHead {
    const lines = headerText.split("\r\n");
    const statusLine = lines[0] || "HTTP/1.1 200 OK";
    const parts = statusLine.split(" ");
    const statusCode = parseInt(parts[1] || "200", 10);

    const headers: Record<string, string> = {};
    for (let index = 1; index < lines.length; index++) {
        const line = lines[index];
        const colon = line.indexOf(":");
        if (colon > 0) {
            headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
        }
    }

    return { statusCode: Number.isNaN(statusCode) ? 200 : statusCode, headers };
}

//
// Opens the connection a request will run over. The https shim supplies a TLS one; plain http uses
// net.connect. Keeping it a parameter is what lets the scheme pick the transport without this module
// knowing anything about TLS.
//
export type ClientSocketFactory = (port: number, hostname: string) => IClientTransport;

//
// An outbound client request over a native transport, shared by the http and https shims. Body bytes
// written before the connection is ready are buffered and flushed once it is.
//
export class ClientRequest extends HttpEmitter {
    //
    // The connection this request is sent over.
    //
    // Deliberately NOT named `socket`. TypeScript's `private` hides nothing at runtime, and a
    // library that finds a `socket` property on a request treats it as a Node net.Socket and calls
    // the whole of that contract on it. IClientTransport has five members, so the AWS SDK's
    // `request.socket.setTimeout(...)` threw "not a function" and failed every create-database
    // against S3 on a device. Under this name the SDK takes its own `else` branch and calls
    // ClientRequest.setTimeout below, which is what that method exists for.
    //
    private transport: IClientTransport;

    //
    // Buffered request body chunks, flushed when the request is sent.
    //
    private bodyChunks: Buffer[] = [];

    //
    // True once the request has been aborted via destroy().
    //
    private aborted = false;

    //
    // How long the connection may be idle before the request times out, as asked for by setTimeout.
    // Undefined when no caller has asked for a timeout, in which case none is enforced.
    //
    private inactivityTimeoutMs: number | undefined = undefined;

    //
    // The running inactivity timer, restarted whenever bytes move and cleared on teardown.
    //
    private inactivityTimer: NodeJS.Timeout | undefined = undefined;

    //
    // Opens the connection and schedules the send. `socket` and, for TLS, `secureConnect` are raised on
    // microtasks before the request goes out, so a caller that pins the certificate can attach its
    // listener and abort in time.
    //
    constructor(options: IClientRequestOptions, callback: ((response: IClientResponse) => void) | undefined,
                socketFactory: ClientSocketFactory, signalsHandshake: boolean) {
        super();
        const hostname = options.hostname || options.host || "";
        this.transport = socketFactory(resolvePort(options, signalsHandshake), hostname);

        Promise.resolve().then(() => {
            this.emit("socket", this.transport);
            Promise.resolve().then(() => {
                if (signalsHandshake) {
                    this.transport.emit("secureConnect");
                }
                Promise.resolve().then(() => {
                    if (this.aborted) {
                        return;
                    }
                    this.sendRequest(options, callback, signalsHandshake);
                });
            });
        });
    }

    //
    // Buffers a request body chunk.
    //
    write(chunk: Buffer | Uint8Array | string): boolean {
        this.bodyChunks.push(typeof chunk === "string" ? Buffer.from(chunk, "utf8") : Buffer.from(chunk));
        return true;
    }

    //
    // Optionally buffers a final body chunk. The send happens after the connection sequence.
    //
    end(chunk?: Buffer | Uint8Array | string): void {
        if (chunk !== undefined && chunk !== null) {
            this.write(chunk);
        }
    }

    //
    // Registers an inactivity timeout and enforces it.
    //
    // It used to only record the listener, on the reasoning that the native transports report no
    // socket-level timeout so the caller's own timer would enforce the deadline. There is no such
    // timer: this IS the caller's timer. The AWS SDK builds its client with requestTimeout 30000
    // (see CloudStorage) and enforces it by calling this and destroying the request when it fires,
    // so recording the listener and never calling it meant a request that stalled stalled for ever.
    // On a device that showed up as create-database never finishing and never failing.
    //
    // Inactivity, not total duration, matching Node: any traffic in either direction restarts the
    // clock, so a large slow transfer is not cut off while a dead connection still is.
    //
    setTimeout(timeoutMs: number, callback?: (...args: any[]) => void): this {
        if (callback) {
            this.on("timeout", callback);
        }
        this.inactivityTimeoutMs = timeoutMs;
        this.restartInactivityTimer();
        return this;
    }

    //
    // Stops the idle clock for good, used once the request can no longer be waiting on anything.
    //
    private stopInactivityTimer(): void {
        this.inactivityTimeoutMs = undefined;
        this.restartInactivityTimer();
    }

    //
    // Starts the inactivity clock again, or stops it when no timeout has been asked for. Called
    // whenever bytes move in either direction, and on teardown.
    //
    private restartInactivityTimer(): void {
        if (this.inactivityTimer !== undefined) {
            clearTimeout(this.inactivityTimer);
            this.inactivityTimer = undefined;
        }
        if (this.inactivityTimeoutMs === undefined || this.aborted) {
            return;
        }
        this.inactivityTimer = setTimeout(() => {
            this.inactivityTimer = undefined;
            this.emit("timeout");
        }, this.inactivityTimeoutMs);
    }

    //
    // Aborts the request, closing the connection and emitting `error` when a reason is given.
    //
    destroy(error?: Error): void {
        if (this.aborted) {
            return;
        }
        this.stopInactivityTimer();
        this.aborted = true;
        this.transport.destroy();
        if (error) {
            this.emit("error", error);
        }
    }

    //
    // Whether the request has been aborted.
    //
    get destroyed(): boolean {
        return this.aborted;
    }

    //
    // Writes the request line, headers and body to the transport, then parses the response off the
    // inbound bytes and dispatches it.
    //
    private sendRequest(options: IClientRequestOptions, callback: ((response: IClientResponse) => void) | undefined,
                        signalsHandshake: boolean): void {
        const body = Buffer.concat(this.bodyChunks);
        const method = (options.method || "GET").toUpperCase();
        const port = resolvePort(options, signalsHandshake);
        const hostname = options.hostname || options.host || "";

        let head = `${method} ${options.path || "/"} HTTP/1.1\r\n`;
        const headers = options.headers || {};
        // Only supply a Host header when the caller has not. The AWS SDK sets its own `host` header and
        // signs it, and sending both spellings puts two Host headers on the wire, which a conforming
        // server rejects outright (MinIO answers 400 Bad Request). The comparison is case-insensitive
        // because the header name is.
        const callerSuppliedHost = Object.keys(headers).some(name => name.toLowerCase() === "host");
        if (!callerSuppliedHost) {
            // Omit the port from the Host header when it is the scheme's default, so an AWS SigV4 signature
            // (which canonicalises the host without the default port) matches the header that is sent.
            // Non-default ports (LAN share) keep the explicit `:port`.
            head += `Host: ${port === 443 || port === 80 ? hostname : `${hostname}:${port}`}\r\n`;
        }
        for (const name of Object.keys(headers)) {
            const value = headers[name];
            if (value !== undefined) {
                head += `${name}: ${value}\r\n`;
            }
        }
        head += "Connection: close\r\n\r\n";

        this.setupResponseParsing(callback, method);

        this.transport.write(Buffer.from(head, "utf8"));
        if (body.length > 0) {
            this.transport.write(body);
        }

        // The request is on the wire, so the idle clock starts here.
        this.restartInactivityTimer();
    }

    //
    // Accumulates inbound bytes, parses the response head once the blank line arrives, dispatches the
    // response, then feeds the body until Content-Length is satisfied.
    //
    private setupResponseParsing(callback: ((response: IClientResponse) => void) | undefined, method: string): void {
        let buffer = Buffer.alloc(0);
        let headParsed = false;
        let response: IClientResponse | undefined = undefined;
        let bodyRemaining = 0;
        // A HEAD response carries the object's Content-Length header but NO body, so never wait for
        // body bytes on a HEAD request (S3's HeadObject would otherwise hang the response forever).
        const expectsBody = method !== "HEAD";

        const feedBody = (chunk: Buffer): void => {
            if (!response) {
                return;
            }
            if (bodyRemaining > 0) {
                const take = chunk.subarray(0, bodyRemaining);
                response.push(take);
                bodyRemaining -= take.length;
            }
            if (bodyRemaining <= 0) {
                response.push(null);
                this.stopInactivityTimer();
            }
        };

        this.transport.on("data", (chunk: Buffer) => {
            // Bytes arrived, so the connection is not idle.
            this.restartInactivityTimer();
            if (headParsed) {
                feedBody(chunk);
                return;
            }
            buffer = Buffer.concat([buffer, chunk]);
            const terminator = buffer.indexOf("\r\n\r\n");
            if (terminator === -1) {
                return;
            }
            const headerText = buffer.subarray(0, terminator).toString("utf8");
            const remainder = buffer.subarray(terminator + 4);
            const parsed = parseResponseHead(headerText);
            headParsed = true;

            response = new IncomingMessage("", "", parsed.headers, this.transport as unknown as Socket) as IClientResponse;
            response.statusCode = parsed.statusCode;

            const contentLength = parseInt(parsed.headers["content-length"] || "0", 10);
            bodyRemaining = expectsBody && !Number.isNaN(contentLength) ? contentLength : 0;

            this.emit("response", response);
            if (callback) {
                callback(response);
            }

            if (bodyRemaining > 0 && remainder.length > 0) {
                feedBody(remainder);
            }
            else if (bodyRemaining <= 0) {
                response.push(null);
                this.stopInactivityTimer();
            }
        });

        this.transport.on("close", () => {
            // Nothing more can arrive, so the idle clock must not outlive the connection and fire a
            // timeout at a request that has already finished.
            this.stopInactivityTimer();
        });

        this.transport.on("end", () => {
            if (response && bodyRemaining > 0) {
                response.push(null);
                this.stopInactivityTimer();
            }
        });
    }
}

//
// Resolves the target port, defaulting to the scheme's standard port when the caller gave none.
//
function resolvePort(options: IClientRequestOptions, isTls: boolean): number {
    if (options.port !== undefined && options.port !== null) {
        const port = typeof options.port === "string" ? parseInt(options.port, 10) : options.port;
        if (!Number.isNaN(port)) {
            return port;
        }
    }
    return isTls ? 443 : 80;
}

//
// Makes an outbound plain-HTTP request, mirroring `http.request(options, callback)`. The connection is
// plain TCP through the native bridge, so an `http://` endpoint is reached as `http://` with no TLS
// anywhere in the path.
//
export function request(options: IClientRequestOptions, callback?: (response: IClientResponse) => void): ClientRequest {
    return new ClientRequest(options, callback, (port, hostname) => netConnect(port, hostname) as unknown as IClientTransport, false);
}

//
// The connection-options holder Node calls an Agent. One connection is opened per request and closed,
// so there is no pool: the object exists to be constructed, inspected and passed along.
//
export class Agent {
    //
    // Whether the caller asked for keep-alive. Reported back but not acted on.
    //
    readonly keepAlive: boolean;

    //
    // The keep-alive interval the caller asked for. Reported back but not acted on.
    //
    readonly keepAliveMsecs: number;

    //
    // The socket ceiling the caller asked for. Reported back but not acted on.
    //
    readonly maxSockets: number;

    //
    // Live sockets per origin. Always empty, since no connection outlives its request.
    //
    readonly sockets: Record<string, unknown[]> = {};

    //
    // Queued requests per origin. Always empty, since no request ever waits for a socket.
    //
    readonly requests: Record<string, unknown[]> = {};

    //
    // Builds an agent from the options a caller supplies.
    //
    constructor(options?: { keepAlive?: boolean; keepAliveMsecs?: number; maxSockets?: number }) {
        this.keepAlive = options?.keepAlive === true;
        this.keepAliveMsecs = options?.keepAliveMsecs === undefined ? 1000 : options.keepAliveMsecs;
        this.maxSockets = options?.maxSockets === undefined ? Infinity : options.maxSockets;
    }

    //
    // Releases the agent's connections. There are none, so this does nothing.
    //
    destroy(): void {
        // No pooled connections exist to close.
    }
}

//
// The default export mirrors `import http from "http"`.
//
const httpModule = { createServer, Server, IncomingMessage, ServerResponse, STATUS_CODES, METHODS, request, Agent, ClientRequest };

export default httpModule;

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
import { createServer as netCreateServer, type Server as NetServer, type Socket } from "./node-net";

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
    // No-op pipe; the body parsers used here consume via `data`/`end` events, not piping.
    //
    pipe(destination: any): any {
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
// The default export mirrors `import http from "http"`.
//
const httpModule = { createServer, Server, IncomingMessage, ServerResponse, STATUS_CODES, METHODS };

export default httpModule;

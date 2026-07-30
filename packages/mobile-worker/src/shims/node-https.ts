//
// `https` shim for the embedded mobile worker.
//
// LAN-share's receiver runs an HTTPS server with a runtime self-signed cert, and its sender makes a
// cert-pinned HTTPS request. This shim provides both, layered on the `tls` shim (native TLS transport)
// and reusing the HTTP request/response parsing from the `http` shim:
//   - createServer({ key, cert }, requestListener): a TLS server that parses one HTTP request per
//     accepted connection into an IncomingMessage / ServerResponse (same objects the http shim uses).
//   - request(options, callback): a client that opens a TLS connection, emits `socket` (so a pinning
//     listener can attach), fires `secureConnect` (so the pin is checked before the request is sent),
//     writes the HTTP request, and parses the response.
//
// In the Node unit-test environment a mock host is installed on `globalThis.host`, so the layer is
// testable off-device via the tls shim's mock, matching the other shims.
//

import { Buffer } from "buffer";
import { IncomingMessage, ServerResponse } from "./node-http";
import { Server as TlsServer, connectClient, type TLSSocket, type ITlsServerOptions } from "./node-tls";
import type { Socket as NetSocket } from "./node-net";

//
// A registered event listener.
//
type HttpsListener = (...args: any[]) => void;

//
// A tiny event emitter for the client request object (mirrors the other shims' emitters).
//
class TinyEmitter {
    //
    // Listeners registered per event name.
    //
    private httpsListeners: Map<string, HttpsListener[]> = new Map();

    //
    // Registers a listener for an event.
    //
    on(eventName: string, listener: HttpsListener): this {
        const existing = this.httpsListeners.get(eventName);
        if (existing) {
            existing.push(listener);
        }
        else {
            this.httpsListeners.set(eventName, [listener]);
        }
        return this;
    }

    //
    // Emits an event to all registered listeners.
    //
    emit(eventName: string, ...args: any[]): void {
        const handlers = this.httpsListeners.get(eventName);
        if (!handlers) {
            return;
        }
        for (const handler of handlers.slice()) {
            handler(...args);
        }
    }
}

//
// Parses an HTTP response head (status line + headers) from the text before the blank line.
//
interface IParsedResponseHead {
    // The numeric HTTP status code.
    statusCode: number;

    // Lowercased header name to value map.
    headers: Record<string, string>;
}

//
// Parses the response status line and headers.
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
            const name = line.slice(0, colon).trim().toLowerCase();
            const value = line.slice(colon + 1).trim();
            headers[name] = value;
        }
    }

    return { statusCode: Number.isNaN(statusCode) ? 200 : statusCode, headers };
}

//
// A client HTTP response: an IncomingMessage extended with the numeric statusCode the response line
// carried (LAN-share reads response.statusCode and the body via data/end).
//
export interface IClientResponse extends IncomingMessage {
    // The HTTP status code from the response status line.
    statusCode: number;
}

//
// The subset of request options this shim supports (matching what LAN-share passes).
//
export interface IRequestOptions {
    // The target host.
    hostname: string;

    // The target port.
    port: number;

    // The request path (with query).
    path: string;

    // The HTTP method.
    method: string;

    // Outbound headers.
    headers?: Record<string, string | number>;

    // Ignored here (the tls shim never validates the cert; pinning is done by the caller).
    rejectUnauthorized?: boolean;
}

//
// An outbound client request. Buffers the body from write()/end(), then (after `socket`/`secureConnect`
// are emitted so the caller can pin) writes the HTTP request and parses the response.
//
export class ClientRequest extends TinyEmitter {
    //
    // The underlying TLS connection.
    //
    private socket: TLSSocket;

    //
    // Buffered request body chunks, flushed when the request is sent.
    //
    private bodyChunks: Buffer[] = [];

    //
    // True once the request has been aborted via destroy().
    //
    private aborted = false;

    //
    // Builds the request, opens the TLS connection, and schedules the send after the handshake. The
    // connection trusts any certificate at the transport level; the caller pins it in its
    // `secureConnect` handler and destroys the request on a mismatch.
    //
    constructor(options: IRequestOptions, callback: (response: IClientResponse) => void) {
        super();
        this.socket = connectClient(options.port, options.hostname);

        // Sequence the events so a `socket` handler that attaches a `secureConnect` listener observes
        // the handshake, then send the request only if the caller did not abort during pinning.
        Promise.resolve().then(() => {
            this.emit("socket", this.socket);
            Promise.resolve().then(() => {
                this.socket.emit("secureConnect");
                Promise.resolve().then(() => {
                    if (this.aborted) {
                        return;
                    }
                    this.sendRequest(options, callback);
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
    // Optionally buffers a final body chunk. The actual send happens after the pinning handshake.
    //
    end(chunk?: Buffer | Uint8Array | string): void {
        if (chunk !== undefined && chunk !== null) {
            this.write(chunk);
        }
    }

    //
    // Aborts the request, closing the socket and emitting `error` (LAN-share calls this on a pinning
    // mismatch and rejects via the `error` listener).
    //
    destroy(error?: Error): void {
        if (this.aborted) {
            return;
        }
        this.aborted = true;
        this.socket.destroy();
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
    // Writes the HTTP request line, headers, and body to the TLS socket, then parses the response off
    // the socket's inbound bytes and dispatches it to the response callback.
    //
    private sendRequest(options: IRequestOptions, callback: (response: IClientResponse) => void): void {
        const body = Buffer.concat(this.bodyChunks);

        let head = `${options.method} ${options.path} HTTP/1.1\r\n`;
        // Omit the port from the Host header when it is the HTTPS/HTTP default, so an AWS SigV4
        // signature (which canonicalises the host without the default port) matches the sent header.
        // Non-default ports (LAN share) keep the explicit `:port`.
        const hostHeader = options.port === 443 || options.port === 80 ? options.hostname : `${options.hostname}:${options.port}`;
        head += `Host: ${hostHeader}\r\n`;
        const headers = options.headers || {};
        for (const name of Object.keys(headers)) {
            head += `${name}: ${headers[name]}\r\n`;
        }
        head += "Connection: close\r\n\r\n";

        this.setupResponseParsing(callback, options.method);

        this.socket.write(Buffer.from(head, "utf8"));
        if (body.length > 0) {
            this.socket.write(body);
        }
    }

    //
    // Accumulates inbound bytes from the TLS socket, parses the response head once the blank line
    // arrives, builds the response, dispatches it, and feeds the body until Content-Length is satisfied.
    //
    private setupResponseParsing(callback: (response: IClientResponse) => void, method: string): void {
        let buffer = Buffer.alloc(0);
        let headParsed = false;
        let response: IClientResponse | undefined = undefined;
        let bodyRemaining = 0;
        // A HEAD response carries the object's Content-Length header but NO body, so never wait for
        // body bytes on a HEAD request (S3's HeadObject would otherwise hang the response forever).
        const expectsBody = method.toUpperCase() !== "HEAD";

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
            }
        };

        this.socket.on("data", (chunk: Buffer) => {
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

            response = new IncomingMessage("", "", parsed.headers, this.socket as unknown as NetSocket) as IClientResponse;
            response.statusCode = parsed.statusCode;

            const contentLength = parseInt(parsed.headers["content-length"] || "0", 10);
            bodyRemaining = expectsBody && !Number.isNaN(contentLength) ? contentLength : 0;

            callback(response);

            if (bodyRemaining > 0 && remainder.length > 0) {
                feedBody(remainder);
            }
            else if (bodyRemaining <= 0) {
                response.push(null);
            }
        });

        this.socket.on("end", () => {
            if (response && bodyRemaining > 0) {
                response.push(null);
            }
        });
    }
}

//
// An HTTPS server: a TLS server that parses one HTTP request per accepted connection and dispatches it
// to the request listener, exactly like the http shim's server but over TLS.
//
export class Server {
    //
    // The underlying TLS server accepting encrypted connections.
    //
    private tlsServer: TlsServer;

    //
    // The request listener invoked per parsed request.
    //
    private requestListener: (req: IncomingMessage, res: ServerResponse) => void;

    //
    // Builds a server presenting the given cert/key and routing parsed requests to the listener.
    //
    constructor(options: ITlsServerOptions, requestListener: (req: IncomingMessage, res: ServerResponse) => void) {
        this.requestListener = requestListener;
        this.tlsServer = new TlsServer(options.cert, options.key);
        this.tlsServer.on("secureConnection", (socket: TLSSocket) => this.handleConnection(socket));
    }

    //
    // Binds the server's loopback port via the TLS server. The callback fires once bound.
    //
    listen(port: number, host?: string | (() => void), callback?: () => void): this {
        this.tlsServer.listen(port, host as any, callback);
        return this;
    }

    //
    // Returns the bound address info from the TLS server.
    //
    address(): { port: number; address: string; family: string } {
        return this.tlsServer.address();
    }

    //
    // Closes the server; the callback runs once the listener is stopped.
    //
    close(callback?: () => void): this {
        this.tlsServer.close(callback);
        return this;
    }

    //
    // Parses one HTTP request off an accepted TLS connection and dispatches it to the request listener.
    //
    private handleConnection(socket: TLSSocket): void {
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
            const lines = headerText.split("\r\n");
            const requestLine = (lines[0] || "").split(" ");
            const method = (requestLine[0] || "GET").toUpperCase();
            const url = requestLine[1] || "/";
            const headers: Record<string, string> = {};
            for (let index = 1; index < lines.length; index++) {
                const colon = lines[index].indexOf(":");
                if (colon > 0) {
                    headers[lines[index].slice(0, colon).trim().toLowerCase()] = lines[index].slice(colon + 1).trim();
                }
            }
            headersParsed = true;

            request = new IncomingMessage(method, url, headers, socket as unknown as NetSocket);
            const response = new ServerResponse(socket as unknown as NetSocket);

            const contentLength = parseInt(headers["content-length"] || "0", 10);
            bodyRemaining = Number.isNaN(contentLength) ? 0 : contentLength;

            this.requestListener(request, response);

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
// Creates an HTTPS server, mirroring https.createServer({ key, cert }, requestListener).
//
export function createServer(options: ITlsServerOptions, requestListener: (req: IncomingMessage, res: ServerResponse) => void): Server {
    return new Server(options, requestListener);
}

//
// Makes an HTTPS request, mirroring https.request(options, callback). Returns a ClientRequest.
//
// LAN share is the only caller. It pins the peer certificate itself, so the connection trusts any
// certificate at the transport level and validation is left to the caller's `secureConnect` handler.
//
export function request(options: IRequestOptions, callback: (response: IClientResponse) => void): ClientRequest {
    return new ClientRequest(options, callback);
}

//
// The options an Agent is constructed with.
//
export interface IAgentOptions {
    // Whether to hold connections open between requests.
    keepAlive?: boolean;

    // How often to probe a held-open connection, in milliseconds.
    keepAliveMsecs?: number;

    // The most connections to open per origin.
    maxSockets?: number;
}

//
// The connection-options holder Node calls an Agent. This shim opens one connection per request and
// closes it, so there is no pool: the object exists to be constructed, inspected and passed along,
// which is all the AWS SDK does with it.
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
    constructor(options?: IAgentOptions) {
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
// The default export mirrors `import https from "https"`.
//
const httpsModule = { Server, ClientRequest, Agent, createServer, request };

export default httpsModule;

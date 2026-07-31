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
import { ClientRequest, IncomingMessage, ServerResponse, type IClientRequestOptions, type IClientResponse, type IClientTransport } from "./node-http";
import { Server as TlsServer, connectClient, type TLSSocket, type ITlsServerOptions } from "./node-tls";
import type { Socket as NetSocket } from "./node-net";

export { ClientRequest };
export type { IClientResponse };

//
// The request options this shim accepts. Identical to the http client's, since the only difference
// between the two schemes is the transport and whether `rejectUnauthorized` is acted on.
//
export type IRequestOptions = IClientRequestOptions;

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
// Trust follows Node's own option rather than the caller's identity: without `rejectUnauthorized:
// false` the certificate chain and hostname are validated natively, so an ordinary request (the AWS
// SDK's, say) is safe by default and cannot silently get trust-all. LAN share passes false because it
// presents a runtime self-signed cert and pins the fingerprint itself.
//
// The framing and response parsing are the http shim's; only the transport differs, and `true` tells
// the client to raise `secureConnect` so a pinning caller sees the handshake before the request goes.
//
export function request(options: IRequestOptions, callback?: (response: IClientResponse) => void): ClientRequest {
    const rejectUnauthorized = options.rejectUnauthorized !== false;
    return new ClientRequest(
        options,
        callback,
        (port, hostname) => connectClient(port, hostname, rejectUnauthorized) as unknown as IClientTransport,
        true,
    );
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

import { Buffer } from "buffer";
import { createServer, request, IncomingMessage, type ServerResponse } from "../../shims/node-http";
import { installMockTcpHost, uninstallMockTcpHost, roundTripRequest } from "./tcp-mock-host";

//
// Reads a readable request body stream to a Buffer.
//
function readBody(request: IncomingMessage): Promise<Buffer> {
    return new Promise<Buffer>(resolve => {
        const chunks: Buffer[] = [];
        request.on("data", (chunk: Buffer) => chunks.push(chunk));
        request.on("end", () => resolve(Buffer.concat(chunks)));
    });
}

describe("http shim", () => {
    afterEach(() => {
        uninstallMockTcpHost();
    });

    test("parses the request line and headers into an IncomingMessage", async () => {
        const mock = installMockTcpHost("L-http-1", 8080);

        let captured: IncomingMessage | undefined = undefined;
        const server = createServer((request: IncomingMessage, response: ServerResponse) => {
            captured = request;
            response.statusCode = 200;
            response.end("ok");
        });
        server.listen(0, "127.0.0.1");

        const requestBytes = Buffer.from("GET /asset?id=a&type=thumb HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
        await roundTripRequest(mock, requestBytes);

        expect(captured!.method).toBe("GET");
        expect(captured!.url).toBe("/asset?id=a&type=thumb");
        expect(captured!.headers.host).toBe("localhost");
    });

    test("serialises status line, headers, and Content-Length-framed body", async () => {
        const mock = installMockTcpHost("L-http-2", 8080);

        const server = createServer((_request: IncomingMessage, response: ServerResponse) => {
            response.statusCode = 200;
            response.setHeader("Content-Type", "text/plain");
            response.end("hello");
        });
        server.listen(0, "127.0.0.1");

        const responseBytes = await roundTripRequest(mock, Buffer.from("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n"));
        const text = responseBytes.toString("utf8");

        expect(text.startsWith("HTTP/1.1 200 OK\r\n")).toBe(true);
        expect(text).toContain("content-type: text/plain\r\n");
        expect(text).toContain("content-length: 5\r\n");
        expect(text.endsWith("\r\n\r\nhello")).toBe(true);
    });

    test("delivers the request body to the handler", async () => {
        const mock = installMockTcpHost("L-http-3", 8080);

        let body: Buffer | undefined = undefined;
        const server = createServer((request: IncomingMessage, response: ServerResponse) => {
            readBody(request).then(read => {
                body = read;
                response.statusCode = 204;
                response.end();
            });
        });
        server.listen(0, "127.0.0.1");

        const payload = "hello-body";
        const requestBytes = Buffer.from(`POST /x HTTP/1.1\r\nContent-Length: ${payload.length}\r\n\r\n${payload}`);
        await roundTripRequest(mock, requestBytes);

        expect(body!.toString()).toBe(payload);
    });
});

//
// Unit tests for the outbound client half: a plain-TCP HTTP client over the native tcpConnect. This is
// what makes an `http://` endpoint reachable as `http://`, with no TLS anywhere in the path.
//
describe("http shim outbound request", () => {

    //
    // Installs a mock native host that records the connect target and the bytes written, and lets the
    // test push a response back through the inbound event entry point.
    //
    function installClientHost() {
        const writes: Buffer[] = [];
        const connects: Array<{ host: string; port: number }> = [];
        const tcpConnect = jest.fn((host: string, port: number) => {
            connects.push({ host, port });
            return JSON.stringify({ connectionId: "C-out" });
        });
        (globalThis as any).host = {
            platform: "android",
            tcpConnect,
            tcpWrite: (_connectionId: string, base64: string): null => {
                writes.push(Buffer.from(base64, "base64"));
                return null;
            },
            tcpClose: (): null => null,
        };
        return { writes, connects, tcpConnect };
    }

    //
    // Pushes response bytes to the client as an inbound `data` event.
    //
    function deliver(bytes: Buffer): void {
        (globalThis as any).__tcpEvent(JSON.stringify({ kind: "data", connectionId: "C-out", base64: bytes.toString("base64") }));
    }

    //
    // Awaits enough microtasks for the client to connect and send.
    //
    async function flush(times: number): Promise<void> {
        for (let index = 0; index < times; index++) {
            await Promise.resolve();
        }
    }

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("connects over plain TCP, with no TLS in the path", async () => {
        const mock = installClientHost();

        request({ hostname: "minio.test", port: 9000, path: "/bucket", method: "GET" });
        await flush(10);

        expect(mock.connects).toEqual([{ host: "minio.test", port: 9000 }]);
    });

    test("defaults to port 80 rather than the HTTPS port", async () => {
        const mock = installClientHost();

        request({ hostname: "minio.test", path: "/", method: "GET" });
        await flush(10);

        expect(mock.connects[0].port).toBe(80);
    });

    test("sends a request line and Host header, omitting the default port so a signature matches", async () => {
        const mock = installClientHost();

        request({ hostname: "minio.test", port: 80, path: "/bucket?list=1", method: "GET" });
        await flush(10);

        const sent = Buffer.concat(mock.writes).toString("utf8");
        expect(sent).toContain("GET /bucket?list=1 HTTP/1.1\r\n");
        expect(sent).toContain("Host: minio.test\r\n");
    });

    test("does not add a Host header when the caller already supplied one", async () => {
        const mock = installClientHost();

        // The AWS SDK signs its own lowercase `host` header. Sending ours as well puts two Host headers
        // on the wire, which a conforming server rejects (MinIO answers 400 Bad Request).
        request({ hostname: "minio.test", port: 9000, path: "/", method: "GET", headers: { host: "minio.test:9000" } });
        await flush(10);

        const sent = Buffer.concat(mock.writes).toString("utf8");
        const hostHeaderCount = sent.split("\r\n").filter(line => line.toLowerCase().startsWith("host:")).length;
        expect(hostHeaderCount).toBe(1);
    });

    test("keeps a non-default port in the Host header", async () => {
        const mock = installClientHost();

        request({ hostname: "minio.test", port: 9000, path: "/", method: "GET" });
        await flush(10);

        expect(Buffer.concat(mock.writes).toString("utf8")).toContain("Host: minio.test:9000\r\n");
    });

    test("parses a response and delivers its body", async () => {
        const mock = installClientHost();

        let statusCode = 0;
        let body = "";
        request({ hostname: "minio.test", port: 9000, path: "/", method: "GET" }, response => {
            statusCode = response.statusCode;
            response.on("data", (chunk: Buffer) => { body += chunk.toString(); });
        });
        await flush(10);

        deliver(Buffer.from("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", "utf8"));
        await flush(10);

        expect(statusCode).toBe(200);
        expect(body).toBe("hello");
    });

    test("accepts `host` as well as `hostname`, which is how the AWS SDK spells it", async () => {
        const mock = installClientHost();

        request({ host: "minio.test", port: 9000, path: "/", method: "GET" });
        await flush(10);

        expect(mock.connects[0].host).toBe("minio.test");
    });

    test("writes the request body after the head", async () => {
        const mock = installClientHost();

        const req = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT" });
        req.write(Buffer.from("payload"));
        await flush(10);

        expect(Buffer.concat(mock.writes).toString("utf8").endsWith("payload")).toBe(true);
    });

    test("destroy() before the send stops the request going out", async () => {
        const mock = installClientHost();

        const req = request({ hostname: "minio.test", port: 9000, path: "/", method: "GET" });
        req.destroy();
        await flush(10);

        expect(mock.writes.length).toBe(0);
        expect(req.destroyed).toBe(true);
    });

    //
    // The AWS SDK reaches for `request.socket` and, when it finds one, calls the Node net.Socket
    // contract on it: setTimeout, removeListener, setKeepAlive. The transport underneath this shim
    // has none of those, so exposing it under that name made every S3 request throw "not a function"
    // once the SDK's deferred timeout fired, which failed create-database against S3 on device.
    // Exactly the branch @smithy/node-http-handler takes, asserted here so the property cannot come
    // back under that name.
    //
    test("a client request offers no socket, so a Node socket contract is never called on the transport", async () => {
        installClientHost();

        const req: any = request({ hostname: "minio.test", port: 9000, path: "/", method: "GET" });
        await flush(10);

        expect(req.socket).toBeUndefined();
        expect(typeof req.setTimeout).toBe("function");

        // set-socket-timeout.js, verbatim in structure: with no socket it must reach the request's
        // own setTimeout, which this shim does implement.
        let reachedRequestSetTimeout = false;
        const onTimeout = () => {};
        if (req.socket) {
            req.socket.setTimeout(1000, onTimeout);
        }
        else {
            req.setTimeout(1000, onTimeout);
            reachedRequestSetTimeout = true;
        }

        expect(reachedRequestSetTimeout).toBe(true);
    });
});

//
// Unit tests for piping a response body onward. The AWS SDK pipes every S3 response into its checksum
// stream, so a pipe that drops the bytes makes an S3 read hang rather than fail.
//
describe("http shim IncomingMessage pipe", () => {

    //
    // A writable destination that records what it received and whether it was ended.
    //
    function createDestination() {
        const chunks: Buffer[] = [];
        let ended = false;
        return {
            chunks,
            wasEnded: () => ended,
            write: (chunk: Buffer) => { chunks.push(chunk); return true; },
            end: () => { ended = true; },
        };
    }

    //
    // Awaits enough microtasks for the deferred flush to run.
    //
    async function flush(): Promise<void> {
        for (let index = 0; index < 5; index++) {
            await Promise.resolve();
        }
    }

    test("forwards body bytes into the destination", async () => {
        const message = new IncomingMessage("GET", "/", {}, undefined as any);
        const destination = createDestination();

        message.pipe(destination);
        message.push(Buffer.from("body-bytes"));
        await flush();

        expect(Buffer.concat(destination.chunks).toString()).toBe("body-bytes");
    });

    test("ends the destination when the body ends", async () => {
        const message = new IncomingMessage("GET", "/", {}, undefined as any);
        const destination = createDestination();

        message.pipe(destination);
        message.push(Buffer.from("x"));
        message.push(null);
        await flush();

        expect(destination.wasEnded()).toBe(true);
    });

    test("delivers bytes pushed before the pipe was attached", async () => {
        const message = new IncomingMessage("GET", "/", {}, undefined as any);
        const destination = createDestination();

        message.push(Buffer.from("early"));
        message.push(null);
        message.pipe(destination);
        await flush();

        expect(Buffer.concat(destination.chunks).toString()).toBe("early");
        expect(destination.wasEnded()).toBe(true);
    });

    test("returns the destination, so pipe chains read as they do in Node", () => {
        const message = new IncomingMessage("GET", "/", {}, undefined as any);
        const destination = createDestination();

        expect(message.pipe(destination)).toBe(destination);
    });
});

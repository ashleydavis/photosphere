import { Buffer } from "buffer";
import { createServer, request, type IncomingMessage, type ServerResponse } from "../../shims/node-http";
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
// Unit tests for the outbound client half. It is deliberately not implemented: the host bridge has no
// outbound plain-TCP connect, so the export exists only because the AWS SDK's instance-metadata
// credential provider imports it at module load. The test pins that it refuses loudly rather than
// hanging or quietly doing nothing, so the gap cannot be mistaken for working code.
//
describe("http shim outbound request", () => {

    test("request refuses by name, naming the missing transport", () => {
        expect(() => request({ hostname: "169.254.169.254", port: 80, path: "/latest/meta-data" }))
            .toThrow(/NOT IMPLEMENTED/);
        expect(() => request({ hostname: "169.254.169.254", port: 80, path: "/latest/meta-data" }))
            .toThrow(/outbound plain-TCP connect/);
    });
});

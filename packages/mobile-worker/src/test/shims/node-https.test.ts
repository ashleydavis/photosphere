import { Buffer } from "buffer";
import { createServer, request } from "../../shims/node-https";

//
// The server certificate DER the loopback mock reports to a connecting client.
//
const SERVER_CERT_DER = Buffer.from("server-certificate-der-bytes");

//
// Installs a mock native TLS host that loops a single client connection to a single server-accepted
// connection: tlsConnect schedules the server "connection" event, and each tlsWrite is delivered to the
// peer connection as a "data" event (on a microtask, mimicking native pushing events).
//
function installLoopbackTlsHost(): void {
    const clientConnId = "client-1";
    const serverConnId = "server-1";

    const deliver = (event: Record<string, unknown>): void => {
        Promise.resolve().then(() => (globalThis as any).__tlsEvent(JSON.stringify(event)));
    };

    (globalThis as any).host = {
        platform: "android",
        tlsListen: (): string => JSON.stringify({ listenerId: "L1", port: 8443 }),
        tlsConnect: (): string => {
            deliver({ kind: "connection", listenerId: "L1", connectionId: serverConnId });
            return JSON.stringify({ connectionId: clientConnId, peerCertBase64: SERVER_CERT_DER.toString("base64") });
        },
        tlsWrite: (connectionId: string, base64: string): null => {
            const peer = connectionId === clientConnId ? serverConnId : clientConnId;
            deliver({ kind: "data", connectionId: peer, base64 });
            return null;
        },
        tlsClose: (connectionId: string): null => {
            const peer = connectionId === clientConnId ? serverConnId : clientConnId;
            deliver({ kind: "close", connectionId: peer });
            return null;
        },
        tlsStopListening: (): null => null,
    };
}

//
// Awaits enough microtasks for a full client<->server round trip through the loopback mock.
//
async function flush(times: number): Promise<void> {
    for (let index = 0; index < times; index++) {
        await Promise.resolve();
    }
}

describe("https shim end-to-end (loopback)", () => {
    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("GET round-trips a response and the client can pin the server certificate", async () => {
        installLoopbackTlsHost();

        const server = createServer({ key: "KEY", cert: "CERT" }, (req, res) => {
            if (req.method === "GET" && req.url === "/pairing-code-hash") {
                res.writeHead(200, { "Content-Type": "application/json" });
                res.end(JSON.stringify({ codeHash: "abc123" }));
                return;
            }
            res.writeHead(404, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Not found" }));
        });
        server.listen(0);
        await flush(2);

        let statusCode = 0;
        let body = "";
        let pinnedFingerprintSource: Buffer | undefined = undefined;

        const req = request({ hostname: "127.0.0.1", port: 8443, path: "/pairing-code-hash", method: "GET" }, response => {
            statusCode = response.statusCode;
            response.on("data", (chunk: Buffer) => { body += chunk.toString(); });
        });
        req.on("socket", socket => {
            socket.on("secureConnect", () => {
                pinnedFingerprintSource = socket.getPeerCertificate().raw;
            });
        });
        req.end();

        await flush(40);

        expect(statusCode).toBe(200);
        expect(JSON.parse(body).codeHash).toBe("abc123");
        expect(pinnedFingerprintSource!.equals(SERVER_CERT_DER)).toBe(true);
    });

    test("POST delivers the request body to the server and returns its response", async () => {
        installLoopbackTlsHost();

        let receivedBody = "";
        const server = createServer({ key: "KEY", cert: "CERT" }, (req, res) => {
            const chunks: Buffer[] = [];
            req.on("data", (chunk: Buffer) => chunks.push(chunk));
            req.on("end", () => {
                receivedBody = Buffer.concat(chunks).toString();
                const parsed = JSON.parse(receivedBody);
                if (parsed.codeHash === "abc123") {
                    res.writeHead(200, { "Content-Type": "application/json" });
                    res.end(JSON.stringify({ success: true }));
                }
                else {
                    res.writeHead(403, { "Content-Type": "application/json" });
                    res.end(JSON.stringify({ error: "Invalid pairing code" }));
                }
            });
        });
        server.listen(0);
        await flush(2);

        const payload = JSON.stringify({ codeHash: "abc123", payload: { type: "secret", value: "x" } });
        let statusCode = 0;
        let body = "";
        const req = request({
            hostname: "127.0.0.1",
            port: 8443,
            path: "/share-payload",
            method: "POST",
            headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) },
        }, response => {
            statusCode = response.statusCode;
            response.on("data", (chunk: Buffer) => { body += chunk.toString(); });
        });
        req.write(payload);
        req.end();

        await flush(40);

        expect(receivedBody).toBe(payload);
        expect(statusCode).toBe(200);
        expect(JSON.parse(body).success).toBe(true);
    });
});

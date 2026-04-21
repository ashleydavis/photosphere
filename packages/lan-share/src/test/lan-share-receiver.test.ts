import { createHash } from "crypto";
import { LanShareReceiver } from "../lib/lan-share-receiver";

test("cancel resolves receive with null", async () => {
    const receiver = new LanShareReceiver(60000);
    await receiver.start("1234");

    const receivePromise = receiver.receive();
    receiver.cancel();

    const result = await receivePromise;
    expect(result).toBeNull();
});

test("receive times out and returns null", async () => {
    const receiver = new LanShareReceiver(500); // 500ms timeout
    await receiver.start("1234");

    const result = await receiver.receive();
    expect(result).toBeNull();
}, 10000);

test("GET /pairing-code-hash returns hash of the provided code", async () => {
    const code = "5678";
    const receiver = new LanShareReceiver(10000);
    await receiver.start(code);

    const httpsServer = (receiver as any).httpsServer;
    const port = httpsServer.address().port;

    const { request } = await import("https");
    const responseBody = await new Promise<string>((resolve, reject) => {
        const req = request(
            {
                hostname: "127.0.0.1",
                port,
                path: "/pairing-code-hash",
                method: "GET",
                rejectUnauthorized: false,
            },
            (response) => {
                const chunks: Buffer[] = [];
                response.on("data", (chunk: Buffer) => chunks.push(chunk));
                response.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
            }
        );
        req.on("error", reject);
        req.end();
    });

    const expected = createHash("sha256").update(code).digest("hex");
    const parsed = JSON.parse(responseBody);
    expect(parsed.codeHash).toBe(expected);

    receiver.cancel();
}, 15000);

test("accepts payload with correct code hash", async () => {
    const code = "2468";
    const receiver = new LanShareReceiver(10000);
    await receiver.start(code);

    const receivePromise = receiver.receive();

    const httpsServer = (receiver as any).httpsServer;
    const port = httpsServer.address().port;

    const codeHash = createHash("sha256").update(code).digest("hex");
    const body = JSON.stringify({ codeHash, payload: { message: "hello" } });

    const { request } = await import("https");
    await new Promise<void>((resolve, reject) => {
        const req = request(
            {
                hostname: "127.0.0.1",
                port,
                path: "/share-payload",
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "Content-Length": Buffer.byteLength(body),
                },
                rejectUnauthorized: false,
            },
            (response) => {
                expect(response.statusCode).toBe(200);
                resolve();
            }
        );
        req.on("error", reject);
        req.write(body);
        req.end();
    });

    const result = await receivePromise;
    expect(result).toEqual({ message: "hello" });
}, 15000);

test("rejects payload with wrong code hash", async () => {
    const receiver = new LanShareReceiver(10000);
    await receiver.start("1234");

    const receivePromise = receiver.receive();

    const httpsServer = (receiver as any).httpsServer;
    const port = httpsServer.address().port;

    const wrongCodeHash = createHash("sha256").update("0000").digest("hex");
    const body = JSON.stringify({ codeHash: wrongCodeHash, payload: { message: "bad" } });

    const { request } = await import("https");
    const statusCode = await new Promise<number>((resolve, reject) => {
        const req = request(
            {
                hostname: "127.0.0.1",
                port,
                path: "/share-payload",
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "Content-Length": Buffer.byteLength(body),
                },
                rejectUnauthorized: false,
            },
            (response) => {
                resolve(response.statusCode!);
            }
        );
        req.on("error", reject);
        req.write(body);
        req.end();
    });

    expect(statusCode).toBe(403);

    receiver.cancel();
    const result = await receivePromise;
    expect(result).toBeNull();
}, 15000);

test("aborts and returns 429 after exceeding the request budget", async () => {
    const receiver = new LanShareReceiver(10000);
    await receiver.start("1234");

    const receivePromise = receiver.receive();

    const httpsServer = (receiver as any).httpsServer;
    const port = httpsServer.address().port;

    const wrongCodeHash = createHash("sha256").update("0000").digest("hex");
    const body = JSON.stringify({ codeHash: wrongCodeHash, payload: {} });

    const { request } = await import("https");

    // Send MAX_REQUESTS+1 (6) requests — the 6th triggers the abort (count > 5).
    let lastStatus = 0;
    for (let attempt = 0; attempt < 6; attempt++) {
        lastStatus = await new Promise<number>((resolve, reject) => {
            const req = request(
                {
                    hostname: "127.0.0.1",
                    port,
                    path: "/share-payload",
                    method: "POST",
                    headers: {
                        "Content-Type": "application/json",
                        "Content-Length": Buffer.byteLength(body),
                    },
                    rejectUnauthorized: false,
                },
                (response) => {
                    response.on("data", () => {});
                    response.on("end", () => resolve(response.statusCode!));
                }
            );
            req.on("error", reject);
            req.write(body);
            req.end();
        });
    }

    // The 5th request should have triggered a 429 and abort.
    expect(lastStatus).toBe(429);

    const result = await receivePromise;
    expect(result).toBeNull();
}, 15000);

test("does not abort when request count stays within budget", async () => {
    const code = "9876";
    const receiver = new LanShareReceiver(10000);
    await receiver.start(code);

    const receivePromise = receiver.receive();

    const httpsServer = (receiver as any).httpsServer;
    const port = httpsServer.address().port;

    const { request } = await import("https");

    // GET /pairing-code-hash (request 1)
    const hashStatus = await new Promise<number>((resolve, reject) => {
        const req = request(
            { hostname: "127.0.0.1", port, path: "/pairing-code-hash", method: "GET", rejectUnauthorized: false },
            (response) => {
                response.on("data", () => {});
                response.on("end", () => resolve(response.statusCode!));
            }
        );
        req.on("error", reject);
        req.end();
    });
    expect(hashStatus).toBe(200);

    // POST /share-payload with correct hash (request 2)
    const codeHash = createHash("sha256").update(code).digest("hex");
    const body = JSON.stringify({ codeHash, payload: { message: "ok" } });
    const payloadStatus = await new Promise<number>((resolve, reject) => {
        const req = request(
            {
                hostname: "127.0.0.1",
                port,
                path: "/share-payload",
                method: "POST",
                headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
                rejectUnauthorized: false,
            },
            (response) => {
                response.on("data", () => {});
                response.on("end", () => resolve(response.statusCode!));
            }
        );
        req.on("error", reject);
        req.write(body);
        req.end();
    });
    expect(payloadStatus).toBe(200);

    const result = await receivePromise;
    expect(result).toEqual({ message: "ok" });
}, 15000);

import { createHash } from "crypto";
import { LanShareReceiver } from "../lib/lan-share-receiver";

test("start returns a 4-digit pairing code", async () => {
    const receiver = new LanShareReceiver(5000);
    const info = await receiver.start();

    expect(info.code).toMatch(/^\d{4}$/);
    expect(parseInt(info.code, 10)).toBeGreaterThanOrEqual(1000);
    expect(parseInt(info.code, 10)).toBeLessThanOrEqual(9999);

    receiver.cancel();
});

test("cancel resolves receive with null", async () => {
    const receiver = new LanShareReceiver(60000);
    await receiver.start();

    // Start receiving then cancel immediately
    const receivePromise = receiver.receive();
    receiver.cancel();

    const result = await receivePromise;
    expect(result).toBeNull();
});

test("receive times out and returns null", async () => {
    const receiver = new LanShareReceiver(500); // 500ms timeout
    await receiver.start();

    const result = await receiver.receive();
    expect(result).toBeNull();
}, 10000);

test("accepts payload with correct pin hash", async () => {
    const receiver = new LanShareReceiver(10000);
    const info = await receiver.start();

    const receivePromise = receiver.receive();

    // Get the server address
    const httpsServer = (receiver as any).httpsServer;
    const address = httpsServer.address();
    const port = address.port;

    // Send a payload with the correct pin hash
    const pinHash = createHash("sha256").update(info.code).digest("hex");
    const body = JSON.stringify({ pinHash, payload: { message: "hello" } });

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

test("rejects payload with wrong pin hash", async () => {
    const receiver = new LanShareReceiver(10000);
    await receiver.start();

    const receivePromise = receiver.receive();

    const httpsServer = (receiver as any).httpsServer;
    const address = httpsServer.address();
    const port = address.port;

    // Send with a wrong pin hash
    const wrongPinHash = createHash("sha256").update("0000").digest("hex");
    const body = JSON.stringify({ pinHash: wrongPinHash, payload: { message: "bad" } });

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

test("aborts after 3 failed pin attempts", async () => {
    const receiver = new LanShareReceiver(10000);
    await receiver.start();

    const receivePromise = receiver.receive();

    const httpsServer = (receiver as any).httpsServer;
    const address = httpsServer.address();
    const port = address.port;

    const wrongPinHash = createHash("sha256").update("0000").digest("hex");
    const body = JSON.stringify({ pinHash: wrongPinHash, payload: {} });

    const { request } = await import("https");

    // Send 3 wrong attempts
    for (let attempt = 0; attempt < 3; attempt++) {
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
                    expect(response.statusCode).toBe(403);
                    // Drain the response to avoid hanging
                    response.on("data", () => {});
                    response.on("end", () => resolve());
                }
            );
            req.on("error", reject);
            req.write(body);
            req.end();
        });
    }

    // The receiver should have aborted — receive resolves with null
    const result = await receivePromise;
    expect(result).toBeNull();
}, 15000);

import { createHash } from "crypto";
import { LanShareSender } from "../lib/lan-share-sender";
import { LanShareReceiver } from "../lib/lan-share-receiver";

test("cancel stops the sender", () => {
    const sender = new LanShareSender({ data: "test" });
    // Should not throw
    sender.cancel();
});

test("waitForReceiver returns endpoint or null within timeout", async () => {
    // This test verifies the timeout mechanism works — the sender should
    // resolve within the timeout period. If another test's receiver is
    // broadcasting on the same machine, it may discover that receiver,
    // which is also a valid outcome.
    const sender = new LanShareSender({ data: "test" });
    const result = await sender.waitForReceiver(500);
    // Either null (nothing found) or a valid endpoint shape
    if (result !== null) {
        expect(result.port).toBeGreaterThan(0);
        expect(typeof result.address).toBe("string");
        expect(typeof result.certFingerprint).toBe("string");
    }
}, 10000);

test("full send-receive round trip", async () => {
    const payload = { message: "hello from sender", count: 42 };

    // Start receiver
    const receiver = new LanShareReceiver(15000);
    const receiverInfo = await receiver.start();
    const receivePromise = receiver.receive();

    // Start sender
    const sender = new LanShareSender(payload);
    const endpoint = await sender.waitForReceiver(10000);

    expect(endpoint).not.toBeNull();
    expect(endpoint!.port).toBeGreaterThan(0);
    expect(endpoint!.certFingerprint).toMatch(/^[0-9a-f]{64}$/);

    // Send with correct pin
    const success = await sender.send(endpoint!, receiverInfo.code);
    expect(success).toBe(true);

    // Receiver should have the payload
    const received = await receivePromise;
    expect(received).toEqual(payload);
}, 30000);

test("send returns false for wrong pin", async () => {
    const payload = { message: "test" };

    const receiver = new LanShareReceiver(15000);
    await receiver.start();
    const receivePromise = receiver.receive();

    const sender = new LanShareSender(payload);
    const endpoint = await sender.waitForReceiver(10000);

    expect(endpoint).not.toBeNull();

    // Send with wrong pin
    const success = await sender.send(endpoint!, "0000");
    expect(success).toBe(false);

    receiver.cancel();
    await receivePromise;
}, 30000);

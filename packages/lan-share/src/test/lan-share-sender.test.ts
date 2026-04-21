import { LanShareSender } from "../lib/lan-share-sender";
import { LanShareReceiver } from "../lib/lan-share-receiver";

test("cancel stops the sender", () => {
    const sender = new LanShareSender({ data: "test" });
    // Should not throw
    sender.cancel();
});

test("pairingCode is a 4-digit string when not supplied", () => {
    const sender = new LanShareSender({ data: "test" });
    expect(sender.pairingCode).toMatch(/^\d{4}$/);
    expect(parseInt(sender.pairingCode, 10)).toBeGreaterThanOrEqual(1000);
    expect(parseInt(sender.pairingCode, 10)).toBeLessThanOrEqual(9999);
});

test("pairingCode uses the supplied value when provided", () => {
    const sender = new LanShareSender({ data: "test" }, "4321");
    expect(sender.pairingCode).toBe("4321");
});

test("waitForReceiver returns endpoint or null within timeout", async () => {
    const sender = new LanShareSender({ data: "test" });
    const result = await sender.waitForReceiver(500);
    if (result !== null) {
        expect(result.port).toBeGreaterThan(0);
        expect(typeof result.address).toBe("string");
        expect(typeof result.certFingerprint).toBe("string");
    }
}, 10000);

test("full send-receive round trip", async () => {
    const payload = { message: "hello from sender", count: 42 };
    const code = "7777";

    // Start receiver with the known code
    const receiver = new LanShareReceiver(15000);
    await receiver.start(code);
    const receivePromise = receiver.receive();

    // Start sender with the same code
    const sender = new LanShareSender(payload, code);
    expect(sender.pairingCode).toBe(code);

    const endpoint = await sender.waitForReceiver(10000);
    expect(endpoint).not.toBeNull();
    expect(endpoint!.port).toBeGreaterThan(0);
    expect(endpoint!.certFingerprint).toMatch(/^[0-9a-f]{64}$/);

    const success = await sender.send(endpoint!);
    expect(success).toBe(true);

    const received = await receivePromise;
    expect(received).toEqual(payload);
}, 30000);

test("send returns false when receiver has a different pairing code", async () => {
    const payload = { message: "test" };

    // Receiver was given code "1111" but sender has "2222"
    const receiver = new LanShareReceiver(15000);
    await receiver.start("1111");
    const receivePromise = receiver.receive();

    const sender = new LanShareSender(payload, "2222");
    const endpoint = await sender.waitForReceiver(10000);
    expect(endpoint).not.toBeNull();

    const success = await sender.send(endpoint!);
    expect(success).toBe(false);

    receiver.cancel();
    await receivePromise;
}, 30000);

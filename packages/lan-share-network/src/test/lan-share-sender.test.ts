import { LanShareSender } from "../lib/lan-share-sender";
import { LanShareReceiver } from "../lib/lan-share-receiver";

test("cancel stops the sender", () => {
    const sender = new LanShareSender({ data: "test" });
    // Should not throw
    sender.cancel();
});

test("cancel ends a wait in progress instead of leaving it to time out", async () => {
    const sender = new LanShareSender({ data: "test" });

    // The timeout is far longer than this test is allowed to take, so the wait can only finish
    // because cancel() ended it. Closing the discovery socket alone used to leave this promise
    // pending for the full timeout, which is what made Ctrl+C on a waiting sender look dead.
    const waiting = sender.waitForReceiver(60000);
    const startedAt = Date.now();

    sender.cancel();

    const result = await waiting;
    expect(result).toBeNull();
    expect(Date.now() - startedAt).toBeLessThan(5000);
}, 10000);

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

// Covers the fix for the intermittent LAN-share failure where the receiver never reached its review step: a sender
// used to take the first receiver it heard on the subnet, and a pairing-code mismatch then ended
// the share for good, so any unrelated share announcing during the test's discovery window failed
// it.
test("discovery ignores a receiver whose pairing code is not the one being looked for", async () => {
    const payload = { message: "test" };

    // Stands in for an unrelated share happening at the same time: another worktree's smoke tests,
    // another machine on the LAN, or the app itself. It announces on the same machine-wide
    // discovery port, so this sender hears it.
    const foreignReceiver = new LanShareReceiver(15000);
    await foreignReceiver.start("1111");
    const foreignReceivePromise = foreignReceiver.receive();

    const sender = new LanShareSender(payload, "2222");
    const endpoint = await sender.waitForReceiver(3000);

    // The sender used to accept this stranger, fail the pairing-code check, and end the share for
    // good, because a mismatch is fatal and the discovery socket is closed by then. It must now
    // hold out for its own receiver instead.
    expect(endpoint).toBeNull();

    // Holding out must not make a mistyped code look like an absent device. The sender records
    // that it heard somebody, so the caller can tell the two apart.
    expect(sender.sawMismatchedReceiver).toBe(true);

    foreignReceiver.cancel();
    await foreignReceivePromise;
}, 30000);

// There is deliberately no test for the opposite case, "a sender that hears nothing does not
// report a mismatched receiver". Its assertion is about the absence of foreign broadcasts, and the
// discovery port is machine-wide with announcements going to the whole subnet, so any other share
// running anywhere nearby makes it fail. Writing it caught itself: it went red the first time it
// ran, because a noise generator from the reproduction of this very bug was still advertising. A
// test that depends on nobody else on the network sharing at that moment is a flaky test, which is
// the opposite of what this work is for.

test("send returns false when the receiver it is given has a different pairing code", async () => {
    const payload = { message: "test" };

    // The endpoint is obtained by a sender that does hold the matching code, because discovery now
    // refuses to hand a mismatched receiver to anybody. The pairing-code check inside send() is a
    // second line of defence and is still worth covering on its own.
    const receiver = new LanShareReceiver(15000);
    await receiver.start("1111");
    const receivePromise = receiver.receive();

    const matchingSender = new LanShareSender(payload, "1111");
    const endpoint = await matchingSender.waitForReceiver(10000);
    expect(endpoint).not.toBeNull();

    const mismatchedSender = new LanShareSender(payload, "2222");
    const success = await mismatchedSender.send(endpoint!);
    expect(success).toBe(false);

    receiver.cancel();
    await receivePromise;
}, 30000);

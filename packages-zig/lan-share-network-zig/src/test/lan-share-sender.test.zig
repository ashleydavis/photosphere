const std = @import("std");
const lan_share = @import("lan-share-network-zig");
const pairing_code = @import("pairing-code.zig");
const utils = @import("utils-zig");

const LanShareSender = lan_share.lan_share_sender.LanShareSender;
const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;
const IReceiverEndpoint = lan_share.lan_share_types.IReceiverEndpoint;

//
// Makes the `{ data: "test" }` payload of the TypeScript tests (or another one-field object).
//
fn objectPayload(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, name, value);
    return .{ .object = object };
}

//
// What the waiting thread of "cancel ends a wait in progress" leaves for the test to check.
//
const IWaitOutcome = struct {
    // The endpoint the wait returned.
    endpoint: ?IReceiverEndpoint = null,

    // The error the wait returned, if any.
    failure: ?anyerror = null,
};

//
// Runs waitForReceiver on a thread of its own (the TypeScript test holds the wait's promise instead).
//
fn waitOnThread(sender: *LanShareSender, timeoutMs: i64, outcome: *IWaitOutcome) void {
    outcome.endpoint = sender.waitForReceiver(std.testing.io, timeoutMs) catch |err| {
        outcome.failure = err;
        return;
    };
}

//
// Starts a receiver and finds it with a sender that holds the receiver's code. The sender is listening before the receiver
// starts, so it hears the announcement the receiver makes as it starts. A sender that began listening after that would wait
// for the receiver's next announcement, which comes a second later.
//
fn startAndDiscover(receiver: *LanShareReceiver, sender: *LanShareSender, code: []const u8) !IReceiverEndpoint {
    var outcome: IWaitOutcome = .{};
    const waiting = try std.Thread.spawn(.{}, waitOnThread, .{ sender, 10000, &outcome });
    var attempts: usize = 0;
    while (!sender.isWaiting.load(.acquire)) {
        attempts += 1;
        if (attempts > 5000) {
            sender.cancel();
            waiting.join();
            return error.SenderNeverStartedListening;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    receiver.start(code) catch |err| {
        sender.cancel();
        waiting.join();
        return err;
    };
    waiting.join();
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(outcome.endpoint != null);
    return outcome.endpoint.?;
}

test "cancel stops the sender" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), null);
    // Should not throw
    sender.cancel();
}

test "cancel ends a wait in progress instead of leaving it to time out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), try pairing_code.pairingCode());

    // The timeout is far longer than this test is allowed to take, so the wait can only finish
    // because cancel() ended it.
    var outcome: IWaitOutcome = .{};
    const waiting = try std.Thread.spawn(.{}, waitOnThread, .{ &sender, 60000, &outcome });
    while (!sender.isWaiting.load(.acquire)) {
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    const startedAt = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();

    sender.cancel();

    waiting.join();
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(outcome.endpoint == null);
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - startedAt < 5000);
}

test "pairingCode is a 4-digit string when not supplied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), null);
    try std.testing.expectEqual(@as(usize, 4), sender.pairingCode.len);
    const code = try std.fmt.parseInt(u32, sender.pairingCode, 10);
    try std.testing.expect(code >= 1000);
    try std.testing.expect(code <= 9999);
}

test "pairingCode uses the supplied value when provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), "4321");
    try std.testing.expectEqualStrings("4321", sender.pairingCode);
}

test "waitForReceiver returns endpoint or null within timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), null);
    // The wait is on the socket, which no virtual clock reaches, so the timeout is kept short.
    const result = try sender.waitForReceiver(std.testing.io, 50);
    if (result) |endpoint| {
        try std.testing.expect(endpoint.port > 0);
        try std.testing.expect(endpoint.address.len > 0);
        try std.testing.expect(endpoint.certFingerprint.len > 0);
    }
}

test "full send-receive round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var payloadObject: std.json.ObjectMap = .empty;
    try payloadObject.put(allocator, "message", .{ .string = "hello from sender" });
    try payloadObject.put(allocator, "count", .{ .integer = 42 });
    const payload: std.json.Value = .{ .object = payloadObject };
    const code = try pairing_code.pairingCode();

    // Start receiver with the known code
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();

    // Start sender with the same code
    var sender = try LanShareSender.init(allocator, std.testing.io, payload, code);
    try std.testing.expectEqualStrings(code, sender.pairingCode);

    const endpoint = try startAndDiscover(&receiver, &sender, code);
    try std.testing.expect(endpoint.port > 0);
    try std.testing.expectEqual(@as(usize, 64), endpoint.certFingerprint.len);
    for (endpoint.certFingerprint) |character| {
        try std.testing.expect(std.ascii.isDigit(character) or (character >= 'a' and character <= 'f'));
    }

    const success = try sender.send(endpoint);
    try std.testing.expect(success);

    const received = (try receiver.receive()).?;
    try std.testing.expectEqual(@as(usize, 2), received.object.count());
    try std.testing.expectEqualStrings("hello from sender", received.object.get("message").?.string);
    try std.testing.expectEqual(@as(i64, 42), received.object.get("count").?.integer);
}

// Covers the fix for the intermittent LAN-share failure where the receiver never reached its review step: a sender
// used to take the first receiver it heard on the subnet, and a pairing-code mismatch then ended
// the share for good, so any unrelated share announcing during the test's discovery window failed
// it.
test "discovery ignores a receiver whose pairing code is not the one being looked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const foreignCode = try pairing_code.pairingCode();

    // Stands in for an unrelated share happening at the same time: another worktree's smoke tests,
    // another machine on the LAN, or the app itself. It announces on the same machine-wide
    // discovery port, so this sender hears it.
    var foreignReceiver = LanShareReceiver.init(std.testing.io, 15000);
    defer foreignReceiver.deinit();

    // The sender is listening before the stranger announces, so it hears the announcement the stranger makes as it starts, and
    // the test does not wait for the next one a second later. The wait has no timeout the test could run out of: it goes on
    // until the sender is cancelled, which is what shows that it held out.
    var sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "message", .{ .string = "test" }), try pairing_code.otherPairingCode(foreignCode));
    var outcome: IWaitOutcome = .{};
    const waiting = try std.Thread.spawn(.{}, waitOnThread, .{ &sender, 60000, &outcome });
    while (!sender.isWaiting.load(.acquire)) {
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try foreignReceiver.start(foreignCode);

    // The sender has heard the stranger once it has recorded it. A sender that took the stranger would have ended its wait by
    // then, so the loop stops in that case too and the check below fails.
    while (!@atomicLoad(bool, &sender.sawMismatchedReceiver, .acquire) and sender.isWaiting.load(.acquire)) {
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    // The sender used to accept this stranger, fail the pairing-code check, and end the share for
    // good, because a mismatch is fatal and the discovery socket is closed by then. It must now
    // hold out for its own receiver instead: it is still waiting, and cancelling it ends the wait with no receiver.
    try std.testing.expect(sender.isWaiting.load(.acquire));
    sender.cancel();
    waiting.join();
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(outcome.endpoint == null);

    // Holding out must not make a mistyped code look like an absent device. The sender records
    // that it heard somebody, so the caller can tell the two apart.
    try std.testing.expect(sender.sawMismatchedReceiver);

    foreignReceiver.cancel();
    _ = try foreignReceiver.receive();
}

test "send returns false when the receiver it is given has a different pairing code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try objectPayload(allocator, "message", .{ .string = "test" });
    const code = try pairing_code.pairingCode();

    // The endpoint is obtained by a sender that does hold the matching code, because discovery now
    // refuses to hand a mismatched receiver to anybody. The pairing-code check inside send() is a
    // second line of defence and is still worth covering on its own.
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();

    var matchingSender = try LanShareSender.init(allocator, std.testing.io, payload, code);
    const endpoint = try startAndDiscover(&receiver, &matchingSender, code);

    var mismatchedSender = try LanShareSender.init(allocator, std.testing.io, payload, try pairing_code.otherPairingCode(code));
    const success = try mismatchedSender.send(endpoint);
    try std.testing.expect(!success);

    receiver.cancel();
    _ = try receiver.receive();
}

test "the pairing code hash response is read as JSON.parse reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const matches = lan_share.lan_share_sender.pairingCodeHashMatches;

    try std.testing.expect(try matches(allocator, "{\"codeHash\":\"abc\"}", "abc"));

    // JSON.parse keeps the last value of a repeated key.
    try std.testing.expect(try matches(allocator, "{\"codeHash\":\"xyz\",\"codeHash\":\"abc\"}", "abc"));

    // A codeHash that is missing or not a string, or a body that is not an object, is not the code hash.
    try std.testing.expect(!try matches(allocator, "{}", "abc"));
    try std.testing.expect(!try matches(allocator, "{\"codeHash\":1}", "abc"));
    try std.testing.expect(!try matches(allocator, "[\"abc\"]", "abc"));
    try std.testing.expect(!try matches(allocator, "\"abc\"", "abc"));

    // `null.codeHash` throws.
    try std.testing.expectError(error.Thrown, matches(allocator, "null", "abc"));
    try std.testing.expectEqualStrings("TypeError", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("null is not an object (evaluating 'hashBody.codeHash')", utils.errors.lastErrorMessage());
}

test "the announced port is read as parseInt(text, 10) reads it" {
    const parsePort = lan_share.lan_share_sender.parseIntLikeJavaScript;
    try std.testing.expectEqual(@as(?u16, 5000), parsePort("5000"));

    // parseInt skips the whitespace String.prototype.trim removes, takes a sign and stops at the first non-digit.
    try std.testing.expectEqual(@as(?u16, 5000), parsePort("\u{00A0}5000"));
    try std.testing.expectEqual(@as(?u16, 5000), parsePort("+5000abc"));
    try std.testing.expectEqual(@as(?u16, 0), parsePort("0x10"));

    // NaN is not a port.
    try std.testing.expectEqual(@as(?u16, null), parsePort("port"));
    try std.testing.expectEqual(@as(?u16, null), parsePort(""));
}

//
// Sends a payload from a sender to a receiver with the same pairing code and returns what the receiver received.
//
fn sendAndReceive(allocator: std.mem.Allocator, payload: std.json.Value) !?std.json.Value {
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    var sender = try LanShareSender.init(allocator, std.testing.io, payload, code);
    const endpoint = try startAndDiscover(&receiver, &sender, code);
    try std.testing.expect(try sender.send(endpoint));
    return receiver.receive();
}

test "a falsy payload is received as no payload, as the callers' `if (!rawPayload)` reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try sendAndReceive(allocator, .{ .bool = false })) == null);
    try std.testing.expect((try sendAndReceive(allocator, .{ .integer = 0 })) == null);
    try std.testing.expect((try sendAndReceive(allocator, .{ .string = "" })) == null);
    try std.testing.expectEqualStrings("x", (try sendAndReceive(allocator, .{ .string = "x" })).?.string);
}

//
// What announceUntilStopped sends, and when to stop.
//
const IAnnouncer = struct {
    // The datagrams to send, in order, every round.
    datagrams: []const []const u8,

    // Set to stop sending.
    stop: std.atomic.Value(bool),
};

//
// Sends the datagrams of an announcer to the discovery port, by broadcast and to this machine as a receiver does,
// every 50ms until it is stopped.
//
fn announceUntilStopped(announcer: *IAnnouncer) void {
    const udpSocket = lan_share.socket.createUdp(true, true) catch @panic("could not make a UDP socket");
    defer lan_share.socket.close(udpSocket);
    while (!announcer.stop.load(.acquire)) {
        for (announcer.datagrams) |datagram| {
            lan_share.socket.sendTo(udpSocket, datagram, .{ .address = .{ 255, 255, 255, 255 }, .port = lan_share.lan_share_sender.DISCOVERY_PORT }) catch {};
            lan_share.socket.sendTo(udpSocket, datagram, .{ .address = .{ 127, 0, 0, 1 }, .port = lan_share.lan_share_sender.DISCOVERY_PORT }) catch {};
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    }
}

test "discovery skips announcements it cannot read, and reads a fingerprint that holds colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    const codeHash = lan_share.lan_share_sender.sha256Hex(code);
    var announcer: IAnnouncer = .{
        .datagrams = &.{
            "not an announcement",
            "PSIE_RECV:4321",
            try std.fmt.allocPrint(allocator, "PSIE_RECV:4321:{s}", .{&codeHash}),
            try std.fmt.allocPrint(allocator, "PSIE_RECV:port:{s}:aa:bb", .{&codeHash}),
            try std.fmt.allocPrint(allocator, "PSIE_RECV:4321:{s}:", .{&codeHash}),
            try std.fmt.allocPrint(allocator, "PSIE_RECV:4321:{s}:aa:bb", .{&codeHash}),
        },
        .stop = .init(false),
    };
    const thread = try std.Thread.spawn(.{}, announceUntilStopped, .{&announcer});
    defer thread.join();
    defer announcer.stop.store(true, .release);

    var sender = try LanShareSender.init(allocator, std.testing.io, .null, code);
    const endpoint = (try sender.waitForReceiver(std.testing.io, 10000)).?;
    try std.testing.expectEqual(@as(u16, 4321), endpoint.port);
    try std.testing.expectEqualStrings("aa:bb", endpoint.certFingerprint);
}

//
// Starts a receiver and finds it with a sender holding its code, without sending any request to it.
//
fn discoverReceiver(allocator: std.mem.Allocator, receiver: *LanShareReceiver, code: []const u8) !IReceiverEndpoint {
    var finder = try LanShareSender.init(allocator, std.testing.io, .null, code);
    return startAndDiscover(receiver, &finder, code);
}

//
// Spends requests of a receiver's budget with payloads it refuses.
//
fn spendRequests(allocator: std.mem.Allocator, endpoint: IReceiverEndpoint, count: usize) !void {
    for (0..count) |_| {
        const connection = try lan_share.https.Connection.connect(allocator, .{ .address = .{ 127, 0, 0, 1 }, .port = endpoint.port });
        defer connection.close();
        _ = try lan_share.https.request(allocator, connection, "127.0.0.1", "POST", "/share-payload", "{}");
    }
}

test "send refuses a receiver whose certificate is not the one announced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    const endpoint = try discoverReceiver(allocator, &receiver, code);

    var sender = try LanShareSender.init(allocator, std.testing.io, .{ .string = "x" }, code);
    var forged = endpoint;
    forged.certFingerprint = "00";
    try std.testing.expectError(error.Thrown, sender.send(forged));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Certificate fingerprint mismatch - possible MITM attack. Expected 00, got "));

    receiver.cancel();
    _ = try receiver.receive();
}

test "send gives up when the receiver refuses its first request, and fails on a status it does not expect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The whole budget spent: the check of the code is refused with 429.
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    const endpoint = try discoverReceiver(allocator, &receiver, code);
    try spendRequests(allocator, endpoint, 5);
    var sender = try LanShareSender.init(allocator, std.testing.io, .{ .string = "x" }, code);
    try std.testing.expect(!try sender.send(endpoint));
    try std.testing.expect((try receiver.receive()) == null);

    // All but one request spent: the check passes and the payload is refused with 429.
    const otherCode = try pairing_code.otherPairingCode(code);
    var otherReceiver = LanShareReceiver.init(std.testing.io, 15000);
    defer otherReceiver.deinit();
    const otherEndpoint = try discoverReceiver(allocator, &otherReceiver, otherCode);
    try spendRequests(allocator, otherEndpoint, 4);
    var otherSender = try LanShareSender.init(allocator, std.testing.io, .{ .string = "x" }, otherCode);
    try std.testing.expectError(error.Thrown, otherSender.send(otherEndpoint));
    try std.testing.expectEqualStrings("Unexpected status code: 429", utils.errors.lastErrorMessage());
    try std.testing.expect((try otherReceiver.receive()) == null);
}

test "pairingCodeHashMatches fails for a response that is not JSON, as JSON.parse does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, lan_share.lan_share_sender.pairingCodeHashMatches(arena.allocator(), "not json", "hash"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "JSON Parse error: "));
}

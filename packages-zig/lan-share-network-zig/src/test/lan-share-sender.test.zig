const std = @import("std");
const lan_share = @import("lan-share-network-zig");
const helpers = @import("test-helpers.zig");
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
    var sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), try helpers.pairingCode());

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
    const result = try sender.waitForReceiver(std.testing.io, 500);
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
    const code = try helpers.pairingCode();

    // Start receiver with the known code
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    try receiver.start(code);

    // Start sender with the same code
    var sender = try LanShareSender.init(allocator, std.testing.io, payload, code);
    try std.testing.expectEqualStrings(code, sender.pairingCode);

    const endpoint = try sender.waitForReceiver(std.testing.io, 10000);
    try std.testing.expect(endpoint != null);
    try std.testing.expect(endpoint.?.port > 0);
    try std.testing.expectEqual(@as(usize, 64), endpoint.?.certFingerprint.len);
    for (endpoint.?.certFingerprint) |character| {
        try std.testing.expect(std.ascii.isDigit(character) or (character >= 'a' and character <= 'f'));
    }

    const success = try sender.send(endpoint.?);
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
    const foreignCode = try helpers.pairingCode();

    // Stands in for an unrelated share happening at the same time: another worktree's smoke tests,
    // another machine on the LAN, or the app itself. It announces on the same machine-wide
    // discovery port, so this sender hears it.
    var foreignReceiver = LanShareReceiver.init(std.testing.io, 15000);
    defer foreignReceiver.deinit();
    try foreignReceiver.start(foreignCode);

    var sender = try LanShareSender.init(allocator, std.testing.io, try objectPayload(allocator, "message", .{ .string = "test" }), try helpers.otherPairingCode(foreignCode));
    const endpoint = try sender.waitForReceiver(std.testing.io, 3000);

    // The sender used to accept this stranger, fail the pairing-code check, and end the share for
    // good, because a mismatch is fatal and the discovery socket is closed by then. It must now
    // hold out for its own receiver instead.
    try std.testing.expect(endpoint == null);

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
    const code = try helpers.pairingCode();

    // The endpoint is obtained by a sender that does hold the matching code, because discovery now
    // refuses to hand a mismatched receiver to anybody. The pairing-code check inside send() is a
    // second line of defence and is still worth covering on its own.
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    try receiver.start(code);

    var matchingSender = try LanShareSender.init(allocator, std.testing.io, payload, code);
    const endpoint = try matchingSender.waitForReceiver(std.testing.io, 10000);
    try std.testing.expect(endpoint != null);

    var mismatchedSender = try LanShareSender.init(allocator, std.testing.io, payload, try helpers.otherPairingCode(code));
    const success = try mismatchedSender.send(endpoint.?);
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
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    try receiver.start(code);
    var sender = try LanShareSender.init(allocator, std.testing.io, payload, code);
    const endpoint = try sender.waitForReceiver(std.testing.io, 10000);
    try std.testing.expect(try sender.send(endpoint.?));
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

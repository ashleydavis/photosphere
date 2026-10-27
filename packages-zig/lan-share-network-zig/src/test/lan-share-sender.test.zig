const std = @import("std");
const lan_share = @import("lan-share-network-zig");
const pairing_code = @import("pairing-code.zig");
const utils = @import("utils-zig");
const ziggy = @import("ziggy");
const MessageQueue = ziggy.message_queue.MessageQueue;

const LanShareSender = lan_share.lan_share_sender.LanShareSender;
const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;
const IReceiverEndpoint = lan_share.lan_share_types.IReceiverEndpoint;
const ReceiveThread = @import("receive-thread.zig").ReceiveThread;

//
// Makes the `{ data: "test" }` payload (or another one-field object).
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
// Runs waitForReceiver on a thread of its own so that the test can cancel it.
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
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), null);
    // Should not throw
    sender.cancel();
}

test "cancel ends a wait in progress instead of leaving it to time out" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), try pairing_code.pairingCode());

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
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), null);
    try std.testing.expectEqual(@as(usize, 4), sender.pairingCode.len);
    const code = try std.fmt.parseInt(u32, sender.pairingCode, 10);
    try std.testing.expect(code >= 1000);
    try std.testing.expect(code <= 9999);
}

test "pairingCode uses the supplied value when provided" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), "4321");
    try std.testing.expectEqualStrings("4321", sender.pairingCode);
}

test "waitForReceiver returns endpoint or null within timeout" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, try objectPayload(allocator, "data", .{ .string = "test" }), null);
    // The wait is on the socket, which no virtual clock reaches, so the timeout is kept short.
    const result = try sender.waitForReceiver(std.testing.io, 50);
    if (result) |endpoint| {
        try std.testing.expect(endpoint.port > 0);
        try std.testing.expect(endpoint.address.len > 0);
        try std.testing.expect(endpoint.certFingerprint.len > 0);
    }
}

test "full send-receive round trip" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var payloadObject: std.json.ObjectMap = .empty;
    try payloadObject.put(allocator, "message", .{ .string = "hello from sender" });
    try payloadObject.put(allocator, "count", .{ .integer = 42 });
    const payload: std.json.Value = .{ .object = payloadObject };
    const code = try pairing_code.pairingCode();

    // Start receiver with the known code
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer receiver.deinit();

    // Start sender with the same code
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, payload, code);
    try std.testing.expectEqualStrings(code, sender.pairingCode);

    const endpoint = try startAndDiscover(&receiver, &sender, code);
    var receiving: ReceiveThread = .{ .receiver = &receiver };
    try receiving.start();
    defer receiving.stop();
    try std.testing.expect(endpoint.port > 0);
    try std.testing.expectEqual(@as(usize, 64), endpoint.certFingerprint.len);
    for (endpoint.certFingerprint) |character| {
        try std.testing.expect(std.ascii.isDigit(character) or (character >= 'a' and character <= 'f'));
    }

    const success = try sender.send(endpoint);
    try std.testing.expect(success);

    const received = (try receiving.finish()).?;
    try std.testing.expectEqual(@as(usize, 2), received.object.count());
    try std.testing.expectEqualStrings("hello from sender", received.object.get("message").?.string);
    try std.testing.expectEqual(@as(i64, 42), received.object.get("count").?.integer);
}

// Covers the fix for the intermittent LAN-share failure where the receiver never reached its review step: a sender
// used to take the first receiver it heard on the subnet, and a pairing-code mismatch then ended
// the share for good, so any unrelated share announcing during the test's discovery window failed
// it.
test "discovery ignores a receiver whose pairing code is not the one being looked for" {
    const log = utils.mute_log.MuteLog.init();
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const foreignCode = try pairing_code.pairingCode();

    // Stands in for an unrelated share happening at the same time: another worktree's smoke tests,
    // another machine on the LAN, or the app itself. It announces on the same machine-wide
    // discovery port, so this sender hears it.
    var foreignReceiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer foreignReceiver.deinit();

    // The sender is listening before the stranger announces, so it hears the announcement the stranger makes as it starts, and
    // the test does not wait for the next one a second later. The wait has no timeout the test could run out of: it goes on
    // until the sender is cancelled, which is what shows that it held out.
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, try objectPayload(allocator, "message", .{ .string = "test" }), try pairing_code.otherPairingCode(foreignCode));
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
    _ = try foreignReceiver.receive(log);
}

test "send returns false when the receiver it is given has a different pairing code" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try objectPayload(allocator, "message", .{ .string = "test" });
    const code = try pairing_code.pairingCode();

    // The endpoint is obtained by a sender that does hold the matching code, because discovery now
    // refuses to hand a mismatched receiver to anybody. The pairing-code check inside send() is a
    // second line of defence and is still worth covering on its own.
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer receiver.deinit();

    var matchingSender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, payload, code);
    const endpoint = try startAndDiscover(&receiver, &matchingSender, code);
    var receiving: ReceiveThread = .{ .receiver = &receiver };
    try receiving.start();
    defer receiving.stop();

    var mismatchedSender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, payload, try pairing_code.otherPairingCode(code));
    const success = try mismatchedSender.send(endpoint);
    try std.testing.expect(!success);

    _ = try receiving.cancelAndFinish();
}

test "the pairing code hash response is read as JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const matches = lan_share.lan_share_sender.pairingCodeHashMatches;

    try std.testing.expect(try matches(allocator, "{\"codeHash\":\"abc\"}", "abc"));

    // The last value of a repeated key wins.
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

    // A number outside the port range is not a port either.
    try std.testing.expectEqual(@as(?u16, null), parsePort("65536"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("-1"));
    try std.testing.expectEqual(@as(?u16, 65535), parsePort("65535"));
}

//
// Sends a payload from a sender to a receiver with the same pairing code and returns what the receiver received.
//
fn sendAndReceive(discoveryPort: u16, allocator: std.mem.Allocator, payload: std.json.Value) !?std.json.Value {
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer receiver.deinit();
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, payload, code);
    const endpoint = try startAndDiscover(&receiver, &sender, code);
    var receiving: ReceiveThread = .{ .receiver = &receiver };
    try receiving.start();
    defer receiving.stop();
    try std.testing.expect(try sender.send(endpoint));
    // The payload belongs to the receiver, which is freed on the way out, so the caller is given a copy in its allocator.
    const received = (try receiving.finish()) orelse return null;
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, received, .{}), .{});
}

test "a falsy payload is received as no payload, as the callers' `if (!rawPayload)` reads it" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try sendAndReceive(discoveryPort, allocator, .{ .bool = false })) == null);
    try std.testing.expect((try sendAndReceive(discoveryPort, allocator, .{ .integer = 0 })) == null);
    try std.testing.expect((try sendAndReceive(discoveryPort, allocator, .{ .string = "" })) == null);
    try std.testing.expectEqualStrings("x", (try sendAndReceive(discoveryPort, allocator, .{ .string = "x" })).?.string);
}

//
// What announceUntilStopped sends, and when to stop.
//
const IAnnouncer = struct {
    // The datagrams to send, in order, every round.
    datagrams: []const []const u8,

    // The discovery port to send them to.
    port: u16,

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
            lan_share.socket.sendTo(udpSocket, datagram, .{ .address = .{ 255, 255, 255, 255 }, .port = announcer.port }) catch {};
            lan_share.socket.sendTo(udpSocket, datagram, .{ .address = .{ 127, 0, 0, 1 }, .port = announcer.port }) catch {};
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    }
}

test "discovery skips announcements it cannot read, and reads a fingerprint that holds colons" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    const codeHash = lan_share.lan_share_sender.sha256Hex(code);
    var announcer: IAnnouncer = .{
        .port = discoveryPort,
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

    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .null, code);
    const endpoint = (try sender.waitForReceiver(std.testing.io, 10000)).?;
    try std.testing.expectEqual(@as(u16, 4321), endpoint.port);
    try std.testing.expectEqualStrings("aa:bb", endpoint.certFingerprint);
}

//
// A sender that has been cancelled does not act on what it hears, as the message handler of the TypeScript sender
// returns at once when `this.isCancelled` is set. A cancel before the wait starts does not end the wait (a mirrored
// bug, see cancel), so the wait runs to its timeout and finds nobody.
//
test "a sender that was cancelled before it started waiting ignores the receiver it hears" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    const codeHash = lan_share.lan_share_sender.sha256Hex(code);
    var announcer: IAnnouncer = .{
        .port = discoveryPort,
        .datagrams = &.{
            try std.fmt.allocPrint(allocator, "PSIE_RECV:4321:{s}:aa", .{&codeHash}),
        },
        .stop = .init(false),
    };
    const thread = try std.Thread.spawn(.{}, announceUntilStopped, .{&announcer});
    defer thread.join();
    defer announcer.stop.store(true, .release);

    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .null, code);
    sender.cancel();
    try std.testing.expect((try sender.waitForReceiver(std.testing.io, 700)) == null);
    try std.testing.expect(!sender.sawMismatchedReceiver);
}

//
// Starts a receiver and finds it with a sender holding its code, without sending any request to it.
//
fn discoverReceiver(discoveryPort: u16, allocator: std.mem.Allocator, receiver: *LanShareReceiver, code: []const u8) !IReceiverEndpoint {
    var finder = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .null, code);
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
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer receiver.deinit();
    const endpoint = try discoverReceiver(discoveryPort, allocator, &receiver, code);
    var receiving: ReceiveThread = .{ .receiver = &receiver };
    try receiving.start();
    defer receiving.stop();

    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .{ .string = "x" }, code);
    var forged = endpoint;
    forged.certFingerprint = "00";
    try std.testing.expectError(error.Thrown, sender.send(forged));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Certificate fingerprint mismatch - possible MITM attack. Expected 00, got "));

    _ = try receiving.cancelAndFinish();
}

test "send gives up when the receiver refuses its first request, and fails on a status it does not expect" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The whole budget spent: the check of the code is refused with 429.
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer receiver.deinit();
    const endpoint = try discoverReceiver(discoveryPort, allocator, &receiver, code);
    var receiving: ReceiveThread = .{ .receiver = &receiver };
    try receiving.start();
    defer receiving.stop();
    try spendRequests(allocator, endpoint, 5);
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .{ .string = "x" }, code);
    try std.testing.expect(!try sender.send(endpoint));
    try std.testing.expect((try receiving.finish()) == null);

    // All but one request spent: the check passes and the payload is refused with 429.
    const otherCode = try pairing_code.otherPairingCode(code);
    var otherReceiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer otherReceiver.deinit();
    const otherEndpoint = try discoverReceiver(discoveryPort, allocator, &otherReceiver, otherCode);
    var otherReceiving: ReceiveThread = .{ .receiver = &otherReceiver };
    try otherReceiving.start();
    defer otherReceiving.stop();
    try spendRequests(allocator, otherEndpoint, 4);
    var otherSender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .{ .string = "x" }, otherCode);
    try std.testing.expectError(error.Thrown, otherSender.send(otherEndpoint));
    try std.testing.expectEqualStrings("Unexpected status code: 429", utils.errors.lastErrorMessage());
    try std.testing.expect((try otherReceiving.finish()) == null);
}

//
// What a receiver is started with that answers the check of the pairing code with the hash the sender expects and then refuses the payload
// with 403, as the real receiver does for a payload whose code hash is not its own. The real receiver cannot be made to
// do this to a sender that passed its check, because both requests carry the sender's own code hash, so this is a
// server of the same protocol made from the package's own TLS server and std.http.
//
const IRefusingReceiverStart = struct {
    // The PEM-encoded certificate of the server.
    cert: []const u8,

    // The PEM-encoded private key of the server.
    key: []const u8,

    // The hash of the pairing code that GET /pairing-code-hash answers with.
    codeHash: []const u8,
};

//
// What the server thread reports when it has finished, as the JSON text it posts back.
//
const IRefusingReceiverOutcome = struct {
    // The name of the error that stopped the server, or null.
    failure: ?[]const u8,
};

//
// The thread of an IRefusingReceiver: makes its own allocator and Io, reads its certificate, key and code hash from the message the
// test posted to `starts`, makes its own TLS settings, serves the two requests of a send on the listening socket and posts the outcome
// to `outcomes`.
//
fn serveRefusing(listener: lan_share.socket.Handle, starts: *MessageQueue, outcomes: *MessageQueue) void {
    var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    const message = starts.take(io, allocator, .none).?;
    const start = std.json.parseFromSliceLeaky(IRefusingReceiverStart, allocator, message.text, .{}) catch @panic("The server could not read its start message.");
    var outcome: IRefusingReceiverOutcome = .{
        .failure = null,
    };
    serveRefusingOrFail(allocator, start, listener) catch |err| {
        outcome.failure = @errorName(err);
    };
    const text = std.json.Stringify.valueAlloc(allocator, outcome, .{}) catch @panic("out of memory reporting the outcome");
    outcomes.post(io, 0, text) catch @panic("out of memory reporting the outcome");
}

//
// The body of serveRefusing: one connection for the check of the code and one for the payload, as the sender makes one
// connection for each request.
//
fn serveRefusingOrFail(allocator: std.mem.Allocator, start: IRefusingReceiverStart, listener: lan_share.socket.Handle) !void {
    var context = try lan_share.https.ServerContext.init(start.cert, start.key);
    defer context.deinit();
    for (0..2) |_| {
        if (!try lan_share.socket.waitReadable(listener, 10_000)) {
            return error.TimedOutWaitingForTheSender;
        }
        const accepted = try lan_share.socket.accept(listener);
        const connection = try lan_share.https.Connection.accept(allocator, &context, accepted);
        defer connection.close();
        var httpServer = std.http.Server.init(&connection.reader, &connection.writer);
        var request = try httpServer.receiveHead();
        if (request.head.method == .GET) {
            const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\"}}", .{start.codeHash});
            try request.respond(body, .{ .status = .ok });
            continue;
        }
        var readBuffer: [4096]u8 = undefined;
        const bodyReader = try request.readerExpectContinue(&readBuffer);
        _ = try bodyReader.allocRemaining(allocator, .unlimited);
        try request.respond("{\"error\":\"Invalid pairing code\"}", .{ .status = .forbidden });
    }
}

test "send returns false when the receiver refuses the payload with 403" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    const selfSigned = try lan_share.lan_share_receiver.generateSelfSignedCert(allocator, std.testing.io);
    const listener = try lan_share.socket.createTcp();
    defer lan_share.socket.close(listener);
    try lan_share.socket.bind(listener, try lan_share.socket.parseAddress("127.0.0.1", 0));
    try lan_share.socket.listen(listener);
    const codeHash = lan_share.lan_share_sender.sha256Hex(code);
    var starts = MessageQueue.init();
    defer starts.deinit();
    var outcomes = MessageQueue.init();
    defer outcomes.deinit();
    try starts.post(std.testing.io, 0, try std.json.Stringify.valueAlloc(allocator, IRefusingReceiverStart{
        .cert = selfSigned.cert,
        .key = selfSigned.key,
        .codeHash = &codeHash,
    }, .{}));
    const thread = try std.Thread.spawn(.{}, serveRefusing, .{ listener, &starts, &outcomes });

    var sender = try LanShareSender.init(try lan_share.socket.freeUdpPort(), allocator, std.testing.io, .{ .string = "x" }, code);
    const success = try sender.send(.{
        .address = "127.0.0.1",
        .port = try lan_share.socket.localPort(listener),
        .certFingerprint = selfSigned.fingerprint,
    });
    thread.join();
    const outcome = try std.json.parseFromSliceLeaky(IRefusingReceiverOutcome, allocator, outcomes.tryTake(std.testing.io, allocator).?.text, .{});
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(!success);
}

test "pairingCodeHashMatches fails for a response that is not JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, lan_share.lan_share_sender.pairingCodeHashMatches(arena.allocator(), "not json", "hash"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "JSON Parse error: "));
}

test "a sender finds the receiver while the receiver serves a connection" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 15000);
    defer receiver.deinit();
    try receiver.start(code);
    var receiving: ReceiveThread = .{ .receiver = &receiver };
    try receiving.start();
    defer receiving.stop();

    // A connection that sends nothing: the receiver serves it, waiting for its first request, until it has sat idle for five
    // seconds. The connection is made once the receiver has taken it, so the receiver is serving it from here on.
    const connection = try lan_share.https.Connection.connect(allocator, .{ .address = .{ 127, 0, 0, 1 }, .port = receiver.httpsPort });
    defer connection.close();

    // The announcement the receiver made as it started has gone, so the sender can hear only one the receiver makes while it serves
    // the connection. It listens for less than the five seconds the receiver would hold the connection.
    var sender = try LanShareSender.init(discoveryPort, allocator, std.testing.io, .null, code);
    const endpoint = (try sender.waitForReceiver(std.testing.io, 3000)) orelse return error.ReceiverNotFound;
    try std.testing.expectEqual(receiver.httpsPort, endpoint.port);
}

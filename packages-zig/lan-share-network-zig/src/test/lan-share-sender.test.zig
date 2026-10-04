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
    const code = try helpers.pairingCode();
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
// A sender that has been cancelled does not act on what it hears, as the message handler of the TypeScript sender
// returns at once when `this.isCancelled` is set. A cancel before the wait starts does not end the wait (a mirrored
// bug, see cancel), so the wait runs to its timeout and finds nobody.
//
test "a sender that was cancelled before it started waiting ignores the receiver it hears" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    const codeHash = lan_share.lan_share_sender.sha256Hex(code);
    var announcer: IAnnouncer = .{
        .datagrams = &.{
            try std.fmt.allocPrint(allocator, "PSIE_RECV:4321:{s}:aa", .{&codeHash}),
        },
        .stop = .init(false),
    };
    const thread = try std.Thread.spawn(.{}, announceUntilStopped, .{&announcer});
    defer thread.join();
    defer announcer.stop.store(true, .release);

    var sender = try LanShareSender.init(allocator, std.testing.io, .null, code);
    sender.cancel();
    try std.testing.expect((try sender.waitForReceiver(std.testing.io, 700)) == null);
    try std.testing.expect(!sender.sawMismatchedReceiver);
}

//
// Starts a receiver and finds it with a sender holding its code, without sending any request to it.
//
fn discoverReceiver(allocator: std.mem.Allocator, receiver: *LanShareReceiver, code: []const u8) !IReceiverEndpoint {
    try receiver.start(code);
    var finder = try LanShareSender.init(allocator, std.testing.io, .null, code);
    return (try finder.waitForReceiver(std.testing.io, 10000)).?;
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
    const code = try helpers.pairingCode();
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
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 15000);
    defer receiver.deinit();
    const endpoint = try discoverReceiver(allocator, &receiver, code);
    try spendRequests(allocator, endpoint, 5);
    var sender = try LanShareSender.init(allocator, std.testing.io, .{ .string = "x" }, code);
    try std.testing.expect(!try sender.send(endpoint));
    try std.testing.expect((try receiver.receive()) == null);

    // All but one request spent: the check passes and the payload is refused with 429.
    const otherCode = try helpers.otherPairingCode(code);
    var otherReceiver = LanShareReceiver.init(std.testing.io, 15000);
    defer otherReceiver.deinit();
    const otherEndpoint = try discoverReceiver(allocator, &otherReceiver, otherCode);
    try spendRequests(allocator, otherEndpoint, 4);
    var otherSender = try LanShareSender.init(allocator, std.testing.io, .{ .string = "x" }, otherCode);
    try std.testing.expectError(error.Thrown, otherSender.send(otherEndpoint));
    try std.testing.expectEqualStrings("Unexpected status code: 429", utils.errors.lastErrorMessage());
    try std.testing.expect((try otherReceiver.receive()) == null);
}

//
// A receiver that answers the check of the pairing code with the hash the sender expects and then refuses the payload
// with 403, as the real receiver does for a payload whose code hash is not its own. The real receiver cannot be made to
// do this to a sender that passed its check, because both requests carry the sender's own code hash, so this is a
// server of the same protocol made from the package's own TLS server and std.http.
//
const IRefusingReceiver = struct {
    // The TLS settings of the server.
    context: *const lan_share.https.ServerContext,

    // The listening socket.
    listener: lan_share.socket.Handle,

    // The hash of the pairing code that GET /pairing-code-hash answers with.
    codeHash: []const u8,

    // The error that stopped the server, if any.
    failure: ?anyerror,
};

//
// Serves the two requests of a send with an IRefusingReceiver and records the error that stopped it.
//
fn serveRefusing(server: *IRefusingReceiver) void {
    serveRefusingOrFail(server) catch |err| {
        server.failure = err;
    };
}

//
// The body of serveRefusing: one connection for the check of the code and one for the payload, as the sender makes one
// connection for each request.
//
fn serveRefusingOrFail(server: *IRefusingReceiver) !void {
    for (0..2) |_| {
        if (!try lan_share.socket.waitReadable(server.listener, 10_000)) {
            return error.TimedOutWaitingForTheSender;
        }
        const accepted = try lan_share.socket.accept(server.listener);
        const connection = try lan_share.https.Connection.accept(std.heap.smp_allocator, server.context, accepted);
        defer connection.close();
        var httpServer = std.http.Server.init(&connection.reader, &connection.writer);
        var request = try httpServer.receiveHead();
        if (request.head.method == .GET) {
            const body = try std.fmt.allocPrint(std.heap.smp_allocator, "{{\"codeHash\":\"{s}\"}}", .{server.codeHash});
            defer std.heap.smp_allocator.free(body);
            try request.respond(body, .{ .status = .ok });
            continue;
        }
        var readBuffer: [4096]u8 = undefined;
        const bodyReader = try request.readerExpectContinue(&readBuffer);
        const rawBody = try bodyReader.allocRemaining(std.heap.smp_allocator, .unlimited);
        defer std.heap.smp_allocator.free(rawBody);
        try request.respond("{\"error\":\"Invalid pairing code\"}", .{ .status = .forbidden });
    }
}

test "send returns false when the receiver refuses the payload with 403" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    const selfSigned = try lan_share.lan_share_receiver.generateSelfSignedCert(allocator, std.testing.io);
    var context = try lan_share.https.ServerContext.init(selfSigned.cert, selfSigned.key);
    defer context.deinit();
    const listener = try lan_share.socket.createTcp();
    defer lan_share.socket.close(listener);
    try lan_share.socket.bind(listener, try lan_share.socket.parseAddress("127.0.0.1", 0));
    try lan_share.socket.listen(listener);
    const codeHash = lan_share.lan_share_sender.sha256Hex(code);
    var server: IRefusingReceiver = .{
        .context = &context,
        .listener = listener,
        .codeHash = &codeHash,
        .failure = null,
    };
    const thread = try std.Thread.spawn(.{}, serveRefusing, .{&server});

    var sender = try LanShareSender.init(allocator, std.testing.io, .{ .string = "x" }, code);
    const success = try sender.send(.{
        .address = "127.0.0.1",
        .port = try lan_share.socket.localPort(listener),
        .certFingerprint = selfSigned.fingerprint,
    });
    thread.join();
    try std.testing.expect(server.failure == null);
    try std.testing.expect(!success);
}

test "pairingCodeHashMatches fails for a response that is not JSON, as JSON.parse does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, lan_share.lan_share_sender.pairingCodeHashMatches(arena.allocator(), "not json", "hash"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "JSON Parse error: "));
}

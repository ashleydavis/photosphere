const std = @import("std");
const lan_share = @import("lan-share-network-zig");
const helpers = @import("test-helpers.zig");

const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;
const https = lan_share.https;
const socket = lan_share.socket;
const sha256Hex = lan_share.lan_share_sender.sha256Hex;
const receiver_module = lan_share.lan_share_receiver;

//
// Makes one HTTPS request to the receiver on this machine (the `https.request` calls of the TypeScript tests, with
// `rejectUnauthorized: false`).
//
fn requestReceiver(allocator: std.mem.Allocator, receiver: *const LanShareReceiver, method: []const u8, path: []const u8, body: ?[]const u8) !https.IResponse {
    const connection = try https.Connection.connect(allocator, .{ .address = .{ 127, 0, 0, 1 }, .port = receiver.httpsPort });
    defer connection.close();
    return https.request(allocator, connection, "127.0.0.1", method, path, body);
}

test "cancel resolves receive with null" {
    var receiver = LanShareReceiver.init(std.testing.io, 60000);
    defer receiver.deinit();
    try receiver.start(try helpers.pairingCode());

    const startedAt = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    receiver.cancel();

    const result = try receiver.receive();
    try std.testing.expect(result == null);

    // Jest's default 5 second test timeout, which is what failed the TypeScript test when cancel did not end
    // the receive and it waited out its 60 second timeout instead.
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - startedAt < 5000);
}

test "receive times out and returns null" {
    var receiver = LanShareReceiver.init(std.testing.io, 500); // 500ms timeout
    defer receiver.deinit();
    try receiver.start(try helpers.pairingCode());

    const startedAt = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const result = try receiver.receive();
    try std.testing.expect(result == null);

    // The TypeScript test's 10 second timeout.
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - startedAt < 10000);
}

test "GET /pairing-code-hash returns hash of the provided code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const response = try requestReceiver(allocator, &receiver, "GET", "/pairing-code-hash", null);

    const expected = sha256Hex(code);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{});
    try std.testing.expectEqualStrings(&expected, parsed.object.get("codeHash").?.string);

    receiver.cancel();
}

test "accepts payload with correct code hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const codeHash = sha256Hex(code);
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\",\"payload\":{{\"message\":\"hello\"}}}}", .{&codeHash});

    const response = try requestReceiver(allocator, &receiver, "POST", "/share-payload", body);
    try std.testing.expectEqual(@as(u16, 200), response.statusCode);

    const result = try receiver.receive();
    try std.testing.expectEqualStrings("hello", result.?.object.get("message").?.string);
    try std.testing.expectEqual(@as(usize, 1), result.?.object.count());
}

test "rejects payload with wrong code hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(try helpers.pairingCode());

    const wrongCodeHash = sha256Hex("0000");
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\",\"payload\":{{\"message\":\"bad\"}}}}", .{&wrongCodeHash});

    const response = try requestReceiver(allocator, &receiver, "POST", "/share-payload", body);
    try std.testing.expectEqual(@as(u16, 403), response.statusCode);

    receiver.cancel();
    const result = try receiver.receive();
    try std.testing.expect(result == null);
}

test "aborts and returns 429 after exceeding the request budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(try helpers.pairingCode());

    const wrongCodeHash = sha256Hex("0000");
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\",\"payload\":{{}}}}", .{&wrongCodeHash});

    // Send MAX_REQUESTS+1 (6) requests: the 6th triggers the abort (count > 5).
    var lastStatus: u16 = 0;
    for (0..6) |_| {
        lastStatus = (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode;
    }

    // The 6th request should have triggered a 429 and abort.
    try std.testing.expectEqual(@as(u16, 429), lastStatus);

    const result = try receiver.receive();
    try std.testing.expect(result == null);
}

test "does not abort when request count stays within budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    // GET /pairing-code-hash (request 1)
    const hashStatus = (try requestReceiver(allocator, &receiver, "GET", "/pairing-code-hash", null)).statusCode;
    try std.testing.expectEqual(@as(u16, 200), hashStatus);

    // POST /share-payload with correct hash (request 2)
    const codeHash = sha256Hex(code);
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\",\"payload\":{{\"message\":\"ok\"}}}}", .{&codeHash});
    const payloadStatus = (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode;
    try std.testing.expectEqual(@as(u16, 200), payloadStatus);

    const result = try receiver.receive();
    try std.testing.expectEqualStrings("ok", result.?.object.get("message").?.string);
}

//
// The certificate tests below have no TypeScript counterpart: the TypeScript receiver's certificate is only ever
// checked by Node's TLS stack in the round trip. They cover the ported ASN.1 builder directly.
//

test "encodeAsn1Oid encodes sha256WithRSAEncryption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try receiver_module.encodeAsn1Oid(arena.allocator(), &.{ 1, 2, 840, 113549, 1, 1, 11 });
    try std.testing.expectEqualSlices(u8, &.{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b }, encoded);
}

test "encodeAsn1Length uses the long form from 128 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualSlices(u8, &.{0x7f}, try receiver_module.encodeAsn1Length(allocator, 127));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x80 }, try receiver_module.encodeAsn1Length(allocator, 128));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x01, 0x2c }, try receiver_module.encodeAsn1Length(allocator, 300));
}

test "encodeAsn1Integer adds a leading zero when the high bit is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x02 }, try receiver_module.encodeAsn1Integer(allocator, &.{2}));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x02, 0x00, 0x80 }, try receiver_module.encodeAsn1Integer(allocator, &.{0x80}));
}

test "encodeAsn1UtcTime writes YYMMDDHHMMSSZ in UTC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 2026-09-28T04:05:06Z
    const encoded = try receiver_module.encodeAsn1UtcTime(arena.allocator(), 1790568306);
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 0x0d }, encoded[0..2]);
    try std.testing.expectEqualStrings("260928040506Z", encoded[2..]);
}

test "generateSelfSignedCert makes a certificate the HTTPS server loads, with the SHA-256 of its DER as fingerprint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver_module.generateSelfSignedCert(allocator, std.testing.io);

    try std.testing.expect(std.mem.startsWith(u8, selfSigned.cert, "-----BEGIN CERTIFICATE-----\n"));
    try std.testing.expect(std.mem.endsWith(u8, selfSigned.cert, "\n-----END CERTIFICATE-----\n"));
    const fingerprint = sha256Hex(try receiver_module.extractDerFromPem(allocator, selfSigned.cert));
    try std.testing.expectEqualStrings(&fingerprint, selfSigned.fingerprint);

    var context = try https.ServerContext.init(selfSigned.cert, selfSigned.key);
    context.deinit();
}

test "a payload with a repeated key is read with its last value, as JSON.parse reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const codeHash = sha256Hex(code);
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"wrong\",\"codeHash\":\"{s}\",\"payload\":{{\"message\":\"first\",\"message\":\"second\"}}}}", .{&codeHash});

    const response = try requestReceiver(allocator, &receiver, "POST", "/share-payload", body);
    try std.testing.expectEqual(@as(u16, 200), response.statusCode);

    const result = try receiver.receive();
    try std.testing.expectEqualStrings("second", result.?.object.get("message").?.string);
}

test "answers a body that is not JSON with 400 and a path it does not serve with 404, and keeps waiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const invalid = try requestReceiver(allocator, &receiver, "POST", "/share-payload", "{not json");
    try std.testing.expectEqual(@as(u16, 400), invalid.statusCode);
    try std.testing.expectEqualStrings("{\"error\":\"Invalid JSON\"}", invalid.body);
    const missing = try requestReceiver(allocator, &receiver, "GET", "/elsewhere", null);
    try std.testing.expectEqual(@as(u16, 404), missing.statusCode);
    try std.testing.expectEqualStrings("{\"error\":\"Not found\"}", missing.body);

    // The receiver still takes the payload that follows.
    const codeHash = sha256Hex(code);
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\",\"payload\":\"after\"}}", .{&codeHash});
    try std.testing.expectEqual(@as(u16, 200), (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode);
    try std.testing.expectEqualStrings("after", (try receiver.receive()).?.string);
}

//
// Posts a payload written as JSON text with the right code hash, and returns what the receiver received.
//
fn receivePayloadText(allocator: std.mem.Allocator, payloadText: []const u8) !?std.json.Value {
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);
    const codeHash = sha256Hex(code);
    const body = try std.fmt.allocPrint(allocator, "{{\"codeHash\":\"{s}\",\"payload\":{s}}}", .{ &codeHash, payloadText });
    try std.testing.expectEqual(@as(u16, 200), (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode);
    return receiver.receive();
}

test "a payload that is zero written as a fraction is falsy, and a number too long for an integer is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try receivePayloadText(allocator, "0.0")) == null);
    try std.testing.expectEqual(@as(f64, 1.5), (try receivePayloadText(allocator, "1.5")).?.float);
    try std.testing.expectEqualStrings("123456789012345678901234567890", (try receivePayloadText(allocator, "123456789012345678901234567890")).?.number_string);
}

test "a connection kept alive is served request after request, those sent together too, until it sits idle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try helpers.pairingCode();
    var receiver = LanShareReceiver.init(std.testing.io, 30000);
    defer receiver.deinit();
    try receiver.start(code);

    const connection = try https.Connection.connect(allocator, .{ .address = .{ 127, 0, 0, 1 }, .port = receiver.httpsPort });
    defer connection.close();

    // Two requests in one write: the second is already read when the first has been answered.
    try connection.writer.writeAll("GET /pairing-code-hash HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nGET /pairing-code-hash HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try connection.writer.flush();
    const expected = sha256Hex(code);
    var received: std.ArrayList(u8) = .empty;
    while (std.mem.count(u8, received.items, &expected) < 2) {
        try connection.reader.fillMore();
        try received.appendSlice(allocator, connection.reader.buffered());
        connection.reader.tossBuffered();
    }
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, received.items, "HTTP/1.1 200 OK"));

    // Left idle, the connection is closed by the receiver after five seconds.
    const idleSince = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    try std.testing.expectError(error.EndOfStream, connection.reader.fillMore());
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - idleSince >= 4000);

    receiver.cancel();
    _ = try receiver.receive();
}

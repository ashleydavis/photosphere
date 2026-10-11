const std = @import("std");
const utils = @import("utils-zig");
const lan_share = @import("lan-share-network-zig");
const pairing_code = @import("pairing-code.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");

const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;
const https = lan_share.https;
const socket = lan_share.socket;
const sha256Hex = lan_share.lan_share_sender.sha256Hex;
const receiver_module = lan_share.lan_share_receiver;

//
// Makes one HTTPS request to the receiver on this machine, without verifying its certificate.
//
fn requestReceiver(allocator: std.mem.Allocator, receiver: *const LanShareReceiver, method: []const u8, path: []const u8, body: ?[]const u8) !https.IResponse {
    const connection = try https.Connection.connect(allocator, .{ .address = .{ 127, 0, 0, 1 }, .port = receiver.httpsPort });
    defer connection.close();
    return https.request(allocator, connection, "127.0.0.1", method, path, body);
}

test "cancel resolves receive with null" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 60000);
    defer receiver.deinit();
    try receiver.start(try pairing_code.pairingCode());

    const startedAt = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    receiver.cancel();

    const result = try receiver.receive();
    try std.testing.expect(result == null);

    // A cancel ends the receive at once. Failing here means cancel did not end the receive and it waited out its
    // 60 second timeout instead.
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - startedAt < 5000);
}

test "receive times out and returns null" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    // The receiver's wait for its timeout is a wait on the Io it is given, so a virtual clock ends it at once.
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var receiver = LanShareReceiver.init(discoveryPort, io, 500); // 500ms timeout
    defer receiver.deinit();
    try receiver.start(try pairing_code.pairingCode());

    const startedAt = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = try receiver.receive();
    try std.testing.expect(result == null);

    // The 10 second limit for the receive to end.
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - startedAt < 10000);

    // The receiver waited out its timeout: the virtual clock moved at least that far.
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - startedAt >= 500);
}

test "GET /pairing-code-hash returns hash of the provided code" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const response = try requestReceiver(allocator, &receiver, "GET", "/pairing-code-hash", null);

    const expected = sha256Hex(code);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{});
    try std.testing.expectEqualStrings(&expected, parsed.object.get("codeHash").?.string);

    receiver.cancel();
}

test "accepts payload with correct code hash" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const codeHash = sha256Hex(code);
    const body = try utils.json.stringify(allocator, .{
        .codeHash = &codeHash,
        .payload = .{
            .message = "hello",
        },
    });

    const response = try requestReceiver(allocator, &receiver, "POST", "/share-payload", body);
    try std.testing.expectEqual(@as(u16, 200), response.statusCode);

    const result = try receiver.receive();
    try std.testing.expectEqualStrings("hello", result.?.object.get("message").?.string);
    try std.testing.expectEqual(@as(usize, 1), result.?.object.count());
}

test "rejects payload with wrong code hash" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(try pairing_code.pairingCode());

    const wrongCodeHash = sha256Hex("0000");
    const body = try utils.json.stringify(allocator, .{
        .codeHash = &wrongCodeHash,
        .payload = .{
            .message = "bad",
        },
    });

    const response = try requestReceiver(allocator, &receiver, "POST", "/share-payload", body);
    try std.testing.expectEqual(@as(u16, 403), response.statusCode);

    receiver.cancel();
    const result = try receiver.receive();
    try std.testing.expect(result == null);
}

test "aborts and returns 429 after exceeding the request budget" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(try pairing_code.pairingCode());

    const wrongCodeHash = sha256Hex("0000");
    // An empty struct literal would serialise as an array, so the empty payload object is given as text.
    const body = try utils.json.stringify(allocator, .{
        .codeHash = &wrongCodeHash,
        .payload = utils.json.Raw{ .text = "{}" },
    });

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
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    // GET /pairing-code-hash (request 1)
    const hashStatus = (try requestReceiver(allocator, &receiver, "GET", "/pairing-code-hash", null)).statusCode;
    try std.testing.expectEqual(@as(u16, 200), hashStatus);

    // POST /share-payload with correct hash (request 2)
    const codeHash = sha256Hex(code);
    const body = try utils.json.stringify(allocator, .{
        .codeHash = &codeHash,
        .payload = .{
            .message = "ok",
        },
    });
    const payloadStatus = (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode;
    try std.testing.expectEqual(@as(u16, 200), payloadStatus);

    const result = try receiver.receive();
    try std.testing.expectEqualStrings("ok", result.?.object.get("message").?.string);
}

//
// The certificate tests below cover the ASN.1 builder directly, where the round trip only has the certificate
// checked by the TLS stack.
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

test "a payload with a repeated key is read with its last value" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);

    const codeHash = sha256Hex(code);
    // Hand-written because the point of the test is the duplicate keys, which a serialiser cannot produce.
    const body = try std.mem.concat(allocator, u8, &.{ "{\"codeHash\":\"wrong\",\"codeHash\":\"", &codeHash, "\",\"payload\":{\"message\":\"first\",\"message\":\"second\"}}" });

    const response = try requestReceiver(allocator, &receiver, "POST", "/share-payload", body);
    try std.testing.expectEqual(@as(u16, 200), response.statusCode);

    const result = try receiver.receive();
    try std.testing.expectEqualStrings("second", result.?.object.get("message").?.string);
}

test "answers a body that is not JSON with 400 and a path it does not serve with 404, and keeps waiting" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
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
    const body = try utils.json.stringify(allocator, .{
        .codeHash = &codeHash,
        .payload = "after",
    });
    try std.testing.expectEqual(@as(u16, 200), (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode);
    try std.testing.expectEqualStrings("after", (try receiver.receive()).?.string);
}

//
// Posts a payload written as JSON text with the right code hash, and returns what the receiver received.
//
fn receivePayloadText(discoveryPort: u16, allocator: std.mem.Allocator, payloadText: []const u8) !?std.json.Value {
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 10000);
    defer receiver.deinit();
    try receiver.start(code);
    const codeHash = sha256Hex(code);
    // The payload text goes in verbatim (numbers written as fractions or too long for an integer must not be re-serialised).
    const body = try utils.json.stringify(allocator, .{
        .codeHash = &codeHash,
        .payload = utils.json.Raw{ .text = payloadText },
    });
    try std.testing.expectEqual(@as(u16, 200), (try requestReceiver(allocator, &receiver, "POST", "/share-payload", body)).statusCode);
    return receiver.receive();
}

test "a payload that is zero written as a fraction is falsy, and a number too long for an integer is not" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try receivePayloadText(discoveryPort, allocator, "0.0")) == null);
    try std.testing.expectEqual(@as(f64, 1.5), (try receivePayloadText(discoveryPort, allocator, "1.5")).?.float);
    try std.testing.expectEqualStrings("123456789012345678901234567890", (try receivePayloadText(discoveryPort, allocator, "123456789012345678901234567890")).?.number_string);
}

test "a connection kept alive is served request after request, those sent together too, until it sits idle" {
    const discoveryPort = try lan_share.socket.freeUdpPort();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try pairing_code.pairingCode();
    var receiver = LanShareReceiver.init(discoveryPort, std.testing.io, 30000);
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

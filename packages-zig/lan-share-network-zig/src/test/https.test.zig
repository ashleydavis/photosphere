const std = @import("std");
const utils = @import("utils-zig");
const lan_share = @import("lan-share-network-zig");

const https = lan_share.https;
const socket = lan_share.socket;
const receiver_module = lan_share.lan_share_receiver;

//
// A TCP socket listening on a port the system chose on this machine.
//
const IListener = struct {
    // The listening socket.
    handle: socket.Handle,

    // The address to connect to.
    address: socket.IAddress,
};

//
// Listens on a free port of 127.0.0.1.
//
fn listenLocally() !IListener {
    const handle = try socket.createTcp();
    errdefer socket.close(handle);
    try socket.bind(handle, try socket.parseAddress("127.0.0.1", 0));
    try socket.listen(handle);
    return .{ .handle = handle, .address = try socket.parseAddress("127.0.0.1", try socket.localPort(handle)) };
}

//
// Accepts one connection and closes it without a word: a server that does not speak TLS.
//
fn serveNothing(listener: socket.Handle) void {
    const accepted = socket.accept(listener) catch {
        return;
    };
    defer socket.close(accepted);
}

//
// Connects to the address and closes the socket without a word: a client that does not speak TLS.
//
fn sendNothing(address: socket.IAddress) void {
    const handle = socket.createTcp() catch {
        return;
    };
    defer socket.close(handle);
    socket.connect(handle, address) catch {
        return;
    };
}

test "ServerContext.init reports what libssl could not load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver_module.generateSelfSignedCert(allocator, std.testing.io);
    const otherSelfSigned = try receiver_module.generateSelfSignedCert(allocator, std.testing.io);

    try std.testing.expectError(error.Thrown, https.ServerContext.init("not a certificate", selfSigned.key));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "PEM_read_bio_X509 failed"));

    try std.testing.expectError(error.Thrown, https.ServerContext.init(selfSigned.cert, "not a key"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "PEM_read_bio_PrivateKey failed"));

    // The key of another certificate does not match this one.
    try std.testing.expectError(error.Thrown, https.ServerContext.init(selfSigned.cert, otherSelfSigned.key));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "SSL_CTX_use_PrivateKey failed: "));
}

test "connect fails the handshake with a server that does not speak TLS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const listener = try listenLocally();
    defer socket.close(listener.handle);
    const server = try std.Thread.spawn(.{}, serveNothing, .{listener.handle});
    defer server.join();

    try std.testing.expectError(error.Thrown, https.Connection.connect(arena.allocator(), listener.address));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "SSL_connect failed"));
}

test "accept fails the handshake with a client that does not speak TLS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver_module.generateSelfSignedCert(allocator, std.testing.io);
    var context = try https.ServerContext.init(selfSigned.cert, selfSigned.key);
    defer context.deinit();
    const listener = try listenLocally();
    defer socket.close(listener.handle);
    const client = try std.Thread.spawn(.{}, sendNothing, .{listener.address});
    defer client.join();

    // accept closes the socket when the handshake fails.
    const accepted = try socket.accept(listener.handle);
    try std.testing.expectError(error.Thrown, https.Connection.accept(allocator, &context, accepted));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "SSL_accept failed"));
}

//
// What the server side of the round trip test received.
//
const IServerSide = struct {
    // The server's TLS settings.
    context: *const https.ServerContext,

    // The listening socket.
    listener: socket.Handle,

    // The bytes the server read before the client closed the connection.
    received: std.ArrayList(u8),

    // The error that stopped the server, if any.
    failure: ?anyerror,
};

//
// Accepts one TLS connection and reads what the client writes until it closes the connection.
//
fn serveTls(side: *IServerSide) void {
    serveTlsOrFail(side) catch |err| {
        side.failure = err;
    };
}

//
// The body of serveTls.
//
fn serveTlsOrFail(side: *IServerSide) !void {
    const accepted = try socket.accept(side.listener);
    const connection = try https.Connection.accept(std.testing.allocator, side.context, accepted);
    defer connection.close();
    try connection.reader.appendRemainingUnlimited(std.testing.allocator, &side.received);
}

test "a connection writes every slice of a splat and reads to the end of what the peer sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver_module.generateSelfSignedCert(allocator, std.testing.io);
    var context = try https.ServerContext.init(selfSigned.cert, selfSigned.key);
    defer context.deinit();
    const listener = try listenLocally();
    defer socket.close(listener.handle);
    var side: IServerSide = .{ .context = &context, .listener = listener.handle, .received = .empty, .failure = null };
    defer side.received.deinit(std.testing.allocator);
    const server = try std.Thread.spawn(.{}, serveTls, .{&side});

    const connection = try https.Connection.connect(allocator, listener.address);
    try std.testing.expect(!connection.hasBufferedInput());
    try std.testing.expectEqualSlices(u8, try receiver_module.extractDerFromPem(allocator, selfSigned.cert), try connection.peerCertificateDer(allocator));
    try connection.writer.writeAll("head-");

    // Slices larger than the writer's buffer, so they and the splat reach the connection rather than the buffer.
    const large = try allocator.alloc(u8, 20_000);
    @memset(large, 'b');
    var slices = [_][]const u8{ large, "a", large };
    try connection.writer.writeSplatAll(&slices, 3);
    try connection.writer.flush();
    connection.close();
    server.join();

    try std.testing.expect(side.failure == null);
    try std.testing.expectEqual(@as(usize, "head-".len + 1 + 4 * large.len), side.received.items.len);
    try std.testing.expectEqualStrings("head-", side.received.items[0.."head-".len]);
    try std.testing.expectEqual(@as(u8, 'a'), side.received.items["head-".len + large.len]);
    try std.testing.expectEqual(@as(usize, 4 * large.len), std.mem.count(u8, side.received.items, "b"));
}

test "socket calls report the system error of what failed" {
    // Nothing listens on the port of a listener that has been closed.
    const listener = try listenLocally();
    socket.close(listener.handle);
    const handle = try socket.createTcp();
    defer socket.close(handle);
    try std.testing.expectError(error.Thrown, socket.connect(handle, listener.address));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "connect failed"));

    // A port a listening socket holds cannot be bound again.
    const holder = try listenLocally();
    defer socket.close(holder.handle);
    const second = try socket.createTcp();
    defer socket.close(second);
    try std.testing.expectError(error.Thrown, socket.bind(second, holder.address));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "bind failed"));

    try std.testing.expectError(error.Thrown, socket.parseAddress("not an address", 1));
    try std.testing.expectEqualStrings("Invalid IPv4 address: not an address", utils.errors.lastErrorMessage());
}

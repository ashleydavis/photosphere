//
// Tests for https.zig.
//
// A test shares nothing with the thread it starts for the other end of a connection: the thread makes its own allocator and Io,
// and its own listening socket and TLS settings where it needs them, from copies of what it needs given as JSON on its queue of
// orders, and posts what it found (its port, what it received, the error that stopped it) to the test's queue of events.
//

const std = @import("std");
const utils = @import("utils-zig");
const lan_share = @import("lan-share-network-zig");
const thread_messages = @import("../../../utils-zig/src/test/thread-messages.zig");

const https = lan_share.https;
const socket = lan_share.socket;
const receiver = lan_share.lan_share_receiver;
const MessageQueue = thread_messages.MessageQueue;
const ThreadAllocator = thread_messages.ThreadAllocator;

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
// The queues a test and the thread it starts talk through. They must stay where they are while the thread runs.
//
const IQueues = struct {
    // What the test gives the thread, which the thread takes.
    orders: MessageQueue,

    // What the thread tells the test, which the test takes.
    events: MessageQueue,

    fn init(self: *IQueues) void {
        self.* = .{
            .orders = MessageQueue.init(),
            .events = MessageQueue.init(),
        };
    }

    fn deinit(self: *IQueues) void {
        self.orders.deinit();
        self.events.deinit();
    }
};

//
// What a thread that listens tells the test once it does: its port on 127.0.0.1.
//
const IListening = struct {
    port: u16,
};

//
// What a client thread is given: the port on 127.0.0.1 to connect to.
//
const IConnectOrder = struct {
    port: u16,
};

//
// What a TLS server thread is given: the certificate and key of its TLS settings.
//
const IServeOrder = struct {
    cert: []const u8,
    key: []const u8,
};

//
// What a TLS server thread tells the test once its connection is over: the bytes it read before the client closed the connection,
// and the name of the error that stopped it, if any.
//
const IServerSide = struct {
    received: []const u8,
    failure: ?[]const u8,
};

//
// Takes what a thread that listens told the test and gives the address to connect to.
//
fn takeListeningAddress(queues: *IQueues, allocator: std.mem.Allocator) !socket.IAddress {
    const listening = try thread_messages.take(IListening, &queues.events, std.testing.io, allocator);
    return socket.parseAddress("127.0.0.1", listening.port);
}

//
// Listens on its own socket, tells the test its port, accepts one connection and closes it without a word: a server that does not
// speak TLS.
//
fn serveNothing(queues: *IQueues) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    const listener = listenLocally() catch |err| {
        std.debug.panic("The server could not listen: {s}", .{@errorName(err)});
    };
    defer socket.close(listener.handle);
    thread_messages.post(&queues.events, threaded.io(), thread_allocator.allocator(), IListening{
        .port = listener.address.port,
    }) catch @panic("out of memory telling the test the port");
    const accepted = socket.accept(listener.handle) catch {
        return;
    };
    defer socket.close(accepted);
}

//
// Takes the port it is given, connects to it and closes the socket without a word: a client that does not speak TLS.
//
fn sendNothing(queues: *IQueues) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena_state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    const order = thread_messages.take(IConnectOrder, &queues.orders, threaded.io(), arena_state.allocator()) catch |err| {
        std.debug.panic("The client got no order: {s}", .{@errorName(err)});
    };
    const address = socket.parseAddress("127.0.0.1", order.port) catch {
        return;
    };
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
    const selfSigned = try receiver.generateSelfSignedCert(allocator, std.testing.io);
    const otherSelfSigned = try receiver.generateSelfSignedCert(allocator, std.testing.io);

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
    var queues: IQueues = undefined;
    queues.init();
    defer queues.deinit();
    const server = try std.Thread.spawn(.{}, serveNothing, .{&queues});
    defer server.join();
    const address = try takeListeningAddress(&queues, arena.allocator());

    try std.testing.expectError(error.Thrown, https.Connection.connect(arena.allocator(), address));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "SSL_connect failed"));
}

test "accept fails the handshake with a client that does not speak TLS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver.generateSelfSignedCert(allocator, std.testing.io);
    var context = try https.ServerContext.init(selfSigned.cert, selfSigned.key);
    defer context.deinit();
    const listener = try listenLocally();
    defer socket.close(listener.handle);
    var queues: IQueues = undefined;
    queues.init();
    defer queues.deinit();
    try thread_messages.post(&queues.orders, std.testing.io, allocator, IConnectOrder{
        .port = listener.address.port,
    });
    const client = try std.Thread.spawn(.{}, sendNothing, .{&queues});
    defer client.join();

    // accept closes the socket when the handshake fails.
    const accepted = try socket.accept(listener.handle);
    try std.testing.expectError(error.Thrown, https.Connection.accept(allocator, &context, accepted));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "SSL_accept failed"));
}

//
// What a TLS server thread does once its connection has been accepted with the TLS handshake done.
//
const IServeAction = enum {
    // Reads what the client writes until it closes the connection.
    read_to_end,

    // Hangs up at once.
    hang_up,
};

//
// A TLS server thread: takes its certificate and key, makes its TLS settings, listens on its own socket, tells the test its port,
// accepts one TLS connection, does the action with it, and tells the test what it received and the error that stopped it.
//
fn serveTls(queues: *IQueues, action: IServeAction) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    const order = thread_messages.take(IServeOrder, &queues.orders, io, arena) catch |err| {
        std.debug.panic("The server got no order: {s}", .{@errorName(err)});
    };
    var context = https.ServerContext.init(order.cert, order.key) catch |err| {
        std.debug.panic("The server could not make its TLS settings: {s}", .{@errorName(err)});
    };
    defer context.deinit();
    const listener = listenLocally() catch |err| {
        std.debug.panic("The server could not listen: {s}", .{@errorName(err)});
    };
    defer socket.close(listener.handle);
    thread_messages.post(&queues.events, io, arena, IListening{
        .port = listener.address.port,
    }) catch @panic("out of memory telling the test the port");
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(allocator);
    var side: IServerSide = .{ .received = "", .failure = null };
    serveTlsOrFail(allocator, &context, listener.handle, action, &received) catch |err| {
        side.failure = @errorName(err);
    };
    side.received = received.items;
    thread_messages.post(&queues.events, io, arena, side) catch @panic("out of memory telling the test what the server received");
}

//
// The body of serveTls.
//
fn serveTlsOrFail(allocator: std.mem.Allocator, context: *const https.ServerContext, listener: socket.Handle, action: IServeAction, received: *std.ArrayList(u8)) !void {
    const accepted = try socket.accept(listener);
    const connection = try https.Connection.accept(allocator, context, accepted);
    switch (action) {
        .read_to_end => {
            defer connection.close();
            try connection.reader.appendRemainingUnlimited(allocator, received);
        },
        .hang_up => {
            connection.close();
        },
    }
}

//
// Starts a TLS server thread with the certificate and key, and gives the address to connect to.
//
fn startTlsServer(queues: *IQueues, allocator: std.mem.Allocator, selfSigned: anytype, action: IServeAction) !struct { std.Thread, socket.IAddress } {
    try thread_messages.post(&queues.orders, std.testing.io, allocator, IServeOrder{
        .cert = selfSigned.cert,
        .key = selfSigned.key,
    });
    const server = try std.Thread.spawn(.{}, serveTls, .{ queues, action });
    return .{ server, try takeListeningAddress(queues, allocator) };
}

test "a connection writes every slice of a splat and reads to the end of what the peer sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver.generateSelfSignedCert(allocator, std.testing.io);
    var queues: IQueues = undefined;
    queues.init();
    defer queues.deinit();
    const server, const address = try startTlsServer(&queues, allocator, selfSigned, .read_to_end);

    const connection = try https.Connection.connect(allocator, address);
    try std.testing.expect(!connection.hasBufferedInput());
    try std.testing.expectEqualSlices(u8, try receiver.extractDerFromPem(allocator, selfSigned.cert), try connection.peerCertificateDer(allocator));
    try connection.writer.writeAll("head-");

    // Slices larger than the writer's buffer, so they and the splat reach the connection rather than the buffer.
    const large = try allocator.alloc(u8, 20_000);
    @memset(large, 'b');
    var slices = [_][]const u8{ large, "a", large };
    try connection.writer.writeSplatAll(&slices, 3);
    try connection.writer.flush();
    connection.close();
    server.join();
    const side = try thread_messages.take(IServerSide, &queues.events, std.testing.io, allocator);

    try std.testing.expect(side.failure == null);
    try std.testing.expectEqual(@as(usize, "head-".len + 1 + 4 * large.len), side.received.len);
    try std.testing.expectEqualStrings("head-", side.received[0.."head-".len]);
    try std.testing.expectEqual(@as(u8, 'a'), side.received["head-".len + large.len]);
    try std.testing.expectEqual(@as(usize, 4 * large.len), std.mem.count(u8, side.received, "b"));
}

test "a connection fails to write to a peer that has hung up" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selfSigned = try receiver.generateSelfSignedCert(allocator, std.testing.io);
    var queues: IQueues = undefined;
    queues.init();
    defer queues.deinit();
    const server, const address = try startTlsServer(&queues, allocator, selfSigned, .hang_up);

    const connection = try https.Connection.connect(allocator, address);
    defer connection.close();
    server.join();
    const side = try thread_messages.take(IServerSide, &queues.events, std.testing.io, allocator);
    try std.testing.expect(side.failure == null);

    // The first writes after the hang-up can still be accepted by the system, until the peer's reset reaches it.
    const chunk = try allocator.alloc(u8, 64 * 1024);
    @memset(chunk, 'x');
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        connection.writer.writeAll(chunk) catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
            return;
        };
        connection.writer.flush() catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
            return;
        };
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.WriteToAHungUpPeerNeverFailed;
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

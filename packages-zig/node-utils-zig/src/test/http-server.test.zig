//
// Tests for http-server.zig. It has no TypeScript counterpart (it stands for Node's http.createServer(app).listen(port, host)), so
// there is no TypeScript test to port.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

const HttpServer = node_utils.http_server.HttpServer;
const RequestHandler = node_utils.http_server.RequestHandler;

const io = std.testing.io;

//
// Sends the text on a new connection to the port and returns everything the server sends back until it closes the connection.
//
fn exchange(allocator: std.mem.Allocator, port: u16, text: []const u8) ![]u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return allocator.dupe(u8, ""),
        else => return err,
    };
}

//
// A request for a path, as a browser would send it.
//
fn getRequest(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", .{path});
}

//
// What the handlers of these tests count.
//
const Counters = struct {
    // The requests answered to the end.
    answered: std.atomic.Value(u32) = .init(0),

    // The requests that have begun.
    begun: std.atomic.Value(u32) = .init(0),
};

//
// Answers every request with its path.
//
fn echoPath(context: ?*anyopaque, allocator: std.mem.Allocator, handlerIo: std.Io, request: *std.http.Server.Request) anyerror!void {
    _ = context;
    _ = handlerIo;
    try request.respond(request.head.target, .{
        .keep_alive = false,
    });
    _ = allocator;
}

//
// Answers after a pause, counting the request before and after.
//
fn answerSlowly(context: ?*anyopaque, allocator: std.mem.Allocator, handlerIo: std.Io, request: *std.http.Server.Request) anyerror!void {
    _ = allocator;
    const counters: *Counters = @ptrCast(@alignCast(context.?));
    _ = counters.begun.fetchAdd(1, .seq_cst);
    try handlerIo.sleep(.fromMilliseconds(200), .awake);
    try request.respond("slow", .{
        .keep_alive = false,
    });
    _ = counters.answered.fetchAdd(1, .seq_cst);
}

//
// Fails for one path and answers the others.
//
fn failForBoom(context: ?*anyopaque, allocator: std.mem.Allocator, handlerIo: std.Io, request: *std.http.Server.Request) anyerror!void {
    _ = context;
    _ = allocator;
    _ = handlerIo;
    if (std.mem.eql(u8, request.head.target, "/boom")) {
        return error.Boom;
    }
    try request.respond("fine", .{
        .keep_alive = false,
    });
}

test "listens on the loopback address on a port the operating system chooses, and answers a request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try HttpServer.listen(std.heap.smp_allocator, io, "127.0.0.1", 0, .{
        .context = null,
        .handle = echoPath,
    });
    defer server.close();
    try std.testing.expect(server.port != 0);

    const reply = try exchange(allocator, server.port, try getRequest(allocator, "/hello"));

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n/hello"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "connection: close") != null);
}

test "close stops the server from accepting connections" {
    const server = try HttpServer.listen(std.heap.smp_allocator, io, "127.0.0.1", 0, .{
        .context = null,
        .handle = echoPath,
    });
    const port = server.port;

    server.close();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    try std.testing.expect(std.meta.isError(address.connect(io, .{ .mode = .stream })));
}

test "close waits for a request that is being answered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var counters: Counters = .{};
    const server = try HttpServer.listen(std.heap.smp_allocator, io, "127.0.0.1", 0, .{
        .context = &counters,
        .handle = answerSlowly,
    });
    const port = server.port;
    const client = try std.Thread.spawn(.{}, struct {
        fn run(clientPort: u16, clientAllocator: std.mem.Allocator) void {
            const request = getRequest(clientAllocator, "/") catch return;
            _ = exchange(clientAllocator, clientPort, request) catch {};
        }
    }.run, .{ port, allocator });
    while (counters.begun.load(.seq_cst) == 0) {
        try io.sleep(.fromMilliseconds(2), .awake);
    }

    server.close();

    try std.testing.expectEqual(@as(u32, 1), counters.answered.load(.seq_cst));
    client.join();
}

test "close does not wait for a connection that never sent a request, and that connection is answered nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try HttpServer.listen(std.heap.smp_allocator, io, "127.0.0.1", 0, .{
        .context = null,
        .handle = echoPath,
    });
    const port = server.port;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);

    server.close();

    // The server is closed, so a request sent on the idle connection now is not answered.
    var write_buffer: [1024]u8 = undefined;
    var writer = idle.writer(io, &write_buffer);
    const request = try getRequest(allocator, "/late");
    writer.interface.writeAll(request) catch {};
    writer.interface.flush() catch {};
    var read_buffer: [4096]u8 = undefined;
    var reader = idle.reader(io, &read_buffer);
    const reply = reader.interface.allocRemaining(allocator, .unlimited) catch try allocator.dupe(u8, "");
    try std.testing.expectEqual(@as(usize, 0), reply.len);
}

test "a handler that fails closes its connection and the server answers the next request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stderr_capture = std.Io.Writer.Allocating.init(std.heap.smp_allocator);
    defer stderr_capture.deinit();
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    const server = try HttpServer.listen(std.heap.smp_allocator, io, "127.0.0.1", 0, .{
        .context = null,
        .handle = failForBoom,
    });
    defer server.close();

    const failed = try exchange(allocator, server.port, try getRequest(allocator, "/boom"));
    const fine = try exchange(allocator, server.port, try getRequest(allocator, "/ok"));

    try std.testing.expectEqual(@as(usize, 0), failed.len);
    try std.testing.expect(std.mem.endsWith(u8, fine, "\r\n\r\nfine"));
    // The failure was logged, once.
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "could not answer a request") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "Boom") != null);
}

//
// Tests for http-server.zig.
//
// The tests share nothing with the server's threads, or with the client threads they start: a handler or a connection thread's state
// tells the test what it did by posting to a queue of the test's (see Events), the test lets a handler that waits go by the server's own
// messages (HttpServer.post), and a client thread makes its own Io and allocator and sends the test the reply it got by message.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const ziggy = @import("ziggy");

const http_server = node_utils.http_server;
const HttpServer = http_server.HttpServer;
const Request = http_server.Request;
const Route = http_server.Route;
const Router = http_server.Router;

const MessageQueue = ziggy.message_queue.MessageQueue;
const ThreadAllocator = ziggy.thread_allocator.ThreadAllocator;

const expectServerStopped = @import("../../../utils-zig/src/test/expect-server-stopped.zig").expectServerStopped;

const io = std.testing.io;

//
// Sends the text on a new connection to the port and returns everything the server sends back until it closes the connection.
//
fn exchange(exchange_io: std.Io, allocator: std.mem.Allocator, port: u16, text: []const u8) ![]u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(exchange_io, .{ .mode = .stream });
    defer stream.close(exchange_io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(exchange_io, &write_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(exchange_io, &read_buffer);
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
// Posts an event to the test's queue from a thread of the server: {"event": name}. The queue is named by its address, which only a
// test does. The thread makes an Io of its own, in memory of its own, for the post.
//
fn postEvent(queue_address: usize, name: []const u8) void {
    const queue: *MessageQueue = @ptrFromInt(queue_address);
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = fixed.allocator();
    defer threaded.deinit();
    const text = ziggy.json.stringify(fixed.allocator(), .{
        .event = name,
    }) catch @panic("out of memory posting a test event");
    queue.post(threaded.io(), 0, text) catch @panic("out of memory posting a test event");
}

//
// What the server's threads told the test they did, counted on the test's thread as it reads them from its queue.
//
const Events = struct {
    // The queue the server's threads post to. The test owns it.
    queue: MessageQueue,
    // The requests answered to the end.
    answered: u32 = 0,
    // The requests that have begun.
    begun: u32 = 0,
    // The connection threads that have made their state.
    states_made: u32 = 0,
    // The connection threads that have freed their state.
    states_freed: u32 = 0,

    fn init(self: *Events) void {
        self.* = .{
            .queue = MessageQueue.init(),
        };
    }

    fn deinit(self: *Events) void {
        self.queue.deinit();
    }

    //
    // The queue's address, which the server's threads are given to post to.
    //
    fn address(self: *Events) usize {
        return @intFromPtr(&self.queue);
    }

    //
    // Counts one event read from the queue.
    //
    fn count(self: *Events, text: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(struct { event: []const u8 }, arena_state.allocator(), text, .{});
        if (std.mem.eql(u8, parsed.event, "begun")) {
            self.begun += 1;
        }
        else if (std.mem.eql(u8, parsed.event, "answered")) {
            self.answered += 1;
        }
        else if (std.mem.eql(u8, parsed.event, "state-made")) {
            self.states_made += 1;
        }
        else if (std.mem.eql(u8, parsed.event, "state-freed")) {
            self.states_freed += 1;
        }
    }

    //
    // Counts the events already posted, without waiting for more.
    //
    fn read(self: *Events) !void {
        while (self.queue.tryTake(io, std.testing.allocator)) |message| {
            defer std.testing.allocator.free(message.text);
            try self.count(message.text);
        }
    }

    //
    // Reads events for up to five seconds until the counter has reached the value.
    //
    fn waitFor(self: *Events, counter: *const u32, value: u32) !void {
        const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(5), .clock = .awake });
        while (counter.* < value) {
            const message = self.queue.take(io, std.testing.allocator, .{
                .deadline = deadline,
            }) orelse {
                return error.CountNotReached;
            };
            defer std.testing.allocator.free(message.text);
            try self.count(message.text);
        }
    }
};

//
// Answers a request with its path.
//
fn echoPath(_: ?*anyopaque, request: *Request, _: std.Io, _: ILog, _: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    try request.http.respond(request.path, .{
        .keep_alive = false,
    });
}

//
// Answers with the method and the path.
//
fn echoMethod(_: ?*anyopaque, request: *Request, _: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    try request.http.respond(try std.fmt.allocPrint(allocator, "{s} {s}", .{ @tagName(request.method), request.path }), .{
        .keep_alive = false,
    });
}

//
// Answers 404 with the method and the path.
//
fn notFound(_: ?*anyopaque, request: *Request, _: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    try request.http.respond(try std.fmt.allocPrint(allocator, "no route for {s} {s}", .{ @tagName(request.method), request.path }), .{
        .status = .not_found,
        .keep_alive = false,
    });
}

//
// Holds the key its query parameter "key" names, tells the test it has begun, answers once the owner's message for the key comes, and
// tells the test it has answered. The context is the address of the test's queue.
//
fn answerWhenReleased(context: ?*anyopaque, request: *Request, request_io: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    const events = @intFromPtr(context.?);
    const key = (try request.queryParameter(allocator, "key")) orelse {
        return error.NoKey;
    };
    try request.hold(request_io, allocator, key);
    postEvent(events, "begun");
    const message = request.waitForMessage(request_io, allocator, 5000) orelse {
        return error.NotReleased;
    };
    allocator.free(message.text);
    try request.http.respond("slow", .{
        .keep_alive = false,
    });
    postEvent(events, "answered");
}

//
// Fails for one path and answers the others.
//
fn failForBoom(_: ?*anyopaque, request: *Request, _: std.Io, _: ILog, _: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    if (std.mem.eql(u8, request.path, "/boom")) {
        return error.Boom;
    }
    try request.http.respond("fine", .{
        .keep_alive = false,
    });
}

//
// Answers with the query parameter "name", the header "x-thing" and the body.
//
fn echoParts(_: ?*anyopaque, request: *Request, _: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    const name = (try request.queryParameter(allocator, "name")) orelse "none";
    const thing = try allocator.dupe(u8, request.header("x-thing") orelse "none");
    const body = try request.readBody(allocator, 1024);
    try request.http.respond(try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ name, thing, body }), .{
        .keep_alive = false,
    });
}

//
// Holds the key "call-1", tells the test it has begun, waits for the owner's message for it and answers with it. The context is the
// address of the test's queue.
//
fn holdAndAnswer(context: ?*anyopaque, request: *Request, request_io: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    try request.hold(request_io, allocator, "call-1");
    postEvent(@intFromPtr(context.?), "begun");
    const message = request.waitForMessage(request_io, allocator, 5000) orelse {
        return error.NoMessageForTheKey;
    };
    try request.http.respond(message.text, .{
        .keep_alive = false,
    });
}

//
// A connection thread's state, which only tells the test it was made and freed: the address of the test's queue, read from the
// configuration.
//
const CountedState = struct {
    // The address of the test's queue.
    events: usize,
};

//
// Makes a connection thread's state and tells the test.
//
fn makeState(config: []const u8, _: ?*const ziggy.core.NativeCallbacks, allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    const state = try allocator.create(CountedState);
    state.* = .{
        .events = try std.fmt.parseInt(usize, config, 10),
    };
    postEvent(state.events, "state-made");
    return state;
}

//
// Frees a connection thread's state and tells the test.
//
fn freeState(state: *anyopaque, allocator: std.mem.Allocator) void {
    const counted: *CountedState = @ptrCast(@alignCast(state));
    postEvent(counted.events, "state-freed");
    allocator.destroy(counted);
}

//
// The configuration of makeState: the address of the test's queue, as text.
//
fn eventsConfig(allocator: std.mem.Allocator, events: *Events) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{events.address()});
}

//
// A router with one route for every path the tests use with GET, and the 404.
//
fn routerFor(context: ?*anyopaque, routes: []const Route) Router {
    return .{
        .context = context,
        .routes = routes,
        .notFound = notFound,
    };
}

//
// Opens a socket on a port the operating system chooses and starts a server on it.
//
fn startServer(router: Router, max_threads: usize, state: ?http_server.ConnectionState) !*HttpServer {
    const listener = try http_server.open(io, "127.0.0.1", 0);
    return HttpServer.start(io, std.testing.allocator, listener, .{
        .router = router,
        .maxConnectionThreads = max_threads,
        .connectionState = state,
    });
}

//
// Stops a server the test started.
//
fn stopServer(server: *HttpServer) void {
    server.stop(io, std.testing.allocator);
}

//
// Lets the request holding the key go, with the server's own message for it.
//
fn release(server: *HttpServer, comptime key: []const u8) !void {
    try server.post(io, "{\"type\":\"release\",\"key\":\"" ++ key ++ "\"}");
}

//
// What a client thread is given: the port to connect to and the path to GET.
//
const ClientOrder = struct {
    port: u16,
    path: []const u8,
};

//
// A client on a thread of its own, which makes its own Io and allocator: it takes its order, sends a GET for the path and posts the
// reply it got, or "" when it got none, to the test's queue of replies.
//
fn clientThread(orders: *MessageQueue, replies: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const client_io = threaded.io();
    const message = orders.take(client_io, arena_state.allocator(), .none) orelse @panic("the client got no order");
    const order = std.json.parseFromSliceLeaky(ClientOrder, arena_state.allocator(), message.text, .{}) catch @panic("the client could not read its order");
    const request = getRequest(allocator, order.path) catch @panic("out of memory making a request");
    defer allocator.free(request);
    const reply = exchange(client_io, allocator, order.port, request) catch allocator.dupe(u8, "") catch @panic("out of memory");
    defer allocator.free(reply);
    replies.post(client_io, 0, reply) catch @panic("out of memory posting a reply");
}

//
// A client thread and the queue of its order, which must stay where it is until the thread has been joined.
//
const Client = struct {
    // The client's thread.
    thread: std.Thread,

    // The client's order, which the test posts and the client's thread takes.
    orders: MessageQueue,

    //
    // Starts a client thread for the path.
    //
    fn start(self: *Client, port: u16, path: []const u8, replies: *MessageQueue) !void {
        self.orders = MessageQueue.init();
        const text = try ziggy.json.stringify(std.testing.allocator, ClientOrder{
            .port = port,
            .path = path,
        });
        defer std.testing.allocator.free(text);
        try self.orders.post(io, 0, text);
        self.thread = try std.Thread.spawn(.{}, clientThread, .{ &self.orders, replies });
    }

    //
    // Waits for the client thread to end.
    //
    fn join(self: *Client) void {
        self.thread.join();
        self.orders.deinit();
    }
};

//
// Takes the next reply a client thread posted, waiting up to five seconds, allocated with the allocator.
//
fn takeReply(replies: *MessageQueue, allocator: std.mem.Allocator) ![]const u8 {
    const message = replies.take(io, allocator, .{
        .duration = .{
            .raw = .fromSeconds(5),
            .clock = .awake,
        },
    }) orelse {
        return error.NoReply;
    };
    return message.text;
}

test "open listens on the loopback address on a port the operating system chooses, and the server answers a route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try startServer(routerFor(null, &.{
        .{ .method = .GET, .path = "/hello", .handle = echoPath },
    }), 2, null);
    defer stopServer(server);
    try std.testing.expect(server.port != 0);

    const reply = try exchange(io, allocator, server.port, try getRequest(allocator, "/hello"));

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n/hello"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "connection: close") != null);
}

//
// Answers with the value of the environment variable TEST_HTTP_SERVER_VALUE on the connection thread, or "unset".
//
fn echoEnvironment(_: ?*anyopaque, request: *Request, _: std.Io, _: ILog, _: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
    try request.http.respond(node_utils.process_env.getEnv("TEST_HTTP_SERVER_VALUE") orelse "unset", .{
        .keep_alive = false,
    });
}

test "a connection thread reads the environment the server was started with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TEST_HTTP_SERVER_VALUE", "from-the-server");
    const listener = try http_server.open(io, "127.0.0.1", 0);
    const server = try HttpServer.start(io, std.testing.allocator, listener, .{
        .router = routerFor(null, &.{
            .{ .method = .GET, .path = "/environment", .handle = echoEnvironment },
        }),
        .maxConnectionThreads = 1,
        .environment = &environment,
    });
    defer stopServer(server);

    const reply = try exchange(io, allocator, server.port, try getRequest(allocator, "/environment"));

    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nfrom-the-server"));
}

test "routes are matched by method and by path, without regard to case or a trailing slash, and anything else is not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try startServer(routerFor(null, &.{
        .{ .method = .GET, .path = "/thing", .handle = echoMethod },
        .{ .method = .POST, .path = "/thing", .handle = echoMethod },
    }), 2, null);
    defer stopServer(server);

    const get = try exchange(io, allocator, server.port, try getRequest(allocator, "/Thing/"));
    const post = try exchange(io, allocator, server.port, "POST /thing HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n");
    const put = try exchange(io, allocator, server.port, "PUT /thing HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n");
    const other = try exchange(io, allocator, server.port, try getRequest(allocator, "/other"));

    try std.testing.expect(std.mem.endsWith(u8, get, "\r\n\r\nGET /Thing/"));
    try std.testing.expect(std.mem.endsWith(u8, post, "\r\n\r\nPOST /thing"));
    try std.testing.expect(std.mem.startsWith(u8, put, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, put, "no route for PUT /thing"));
    try std.testing.expect(std.mem.endsWith(u8, other, "no route for GET /other"));
}

test "a request gives its query parameters, its headers and its body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try startServer(routerFor(null, &.{
        .{ .method = .POST, .path = "/parts", .handle = echoParts },
    }), 2, null);
    defer stopServer(server);

    const reply = try exchange(io, allocator, server.port, "POST /parts?name=a%20b+c HTTP/1.1\r\nhost: 127.0.0.1\r\nx-thing: here\r\ncontent-length: 4\r\n\r\nbody");

    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\na b c|here|body"));
}

test "stop stops the server from accepting connections" {
    const server = try startServer(routerFor(null, &.{}), 2, null);
    const port = server.port;

    stopServer(server);

    try expectServerStopped(io, port);
}

test "stop waits for a request that is being answered" {
    var events: Events = undefined;
    events.init();
    defer events.deinit();
    var replies = MessageQueue.init();
    defer replies.deinit();
    const server = try startServer(routerFor(@ptrFromInt(events.address()), &.{
        .{ .method = .GET, .path = "/", .handle = answerWhenReleased },
    }), 2, null);
    var client: Client = undefined;
    try client.start(server.port, "/?key=first", &replies);
    try events.waitFor(&events.begun, 1);
    try release(server, "first");

    stopServer(server);

    try events.read();
    try std.testing.expectEqual(@as(u32, 1), events.answered);
    client.join();
    const reply = try takeReply(&replies, std.testing.allocator);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nslow"));
}

test "stop does not wait for a connection that never sent a request, and that connection is answered nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try startServer(routerFor(null, &.{
        .{ .method = .GET, .path = "/late", .handle = echoPath },
    }), 2, null);
    const port = server.port;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    // The connection is handed to a connection thread once the server thread has accepted it.
    try io.sleep(.fromMilliseconds(100), .awake);

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    stopServer(server);
    // Stopping ends the connection thread's read of the idle connection, well before the idle limit.
    try std.testing.expect(started.untilNow(io).raw.toMilliseconds() < http_server.IDLE_LIMIT_MS);

    // The server is stopped, so a request sent on the idle connection now is not answered.
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
    const listener = try http_server.open(io, "127.0.0.1", 0);
    const server = try HttpServer.start(io, std.testing.allocator, listener, .{
        .router = routerFor(null, &.{
            .{ .method = .GET, .path = "/boom", .handle = failForBoom },
            .{ .method = .GET, .path = "/ok", .handle = failForBoom },
        }),
        .maxConnectionThreads = 1,
    });

    const failed = try exchange(io, allocator, server.port, try getRequest(allocator, "/boom"));
    const fine = try exchange(io, allocator, server.port, try getRequest(allocator, "/ok"));
    stopServer(server);

    try std.testing.expectEqual(@as(usize, 0), failed.len);
    try std.testing.expect(std.mem.endsWith(u8, fine, "\r\n\r\nfine"));
}

test "a request that is not HTTP is answered 400 Bad Request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try startServer(routerFor(null, &.{}), 2, null);
    defer stopServer(server);

    const invalid = try exchange(io, allocator, server.port, "this is not a request\r\n\r\n");

    try std.testing.expect(std.mem.startsWith(u8, invalid, "HTTP/1.1 400 Bad Request\r\n"));
}

test "a request head that is too big is answered 431" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const server = try startServer(routerFor(null, &.{}), 2, null);
    defer stopServer(server);
    const huge = try allocator.alloc(u8, 20 * 1024);
    @memset(huge, 'a');

    const oversize = try exchange(io, allocator, server.port, try std.fmt.allocPrint(allocator, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\nx-big: {s}\r\n\r\n", .{huge}));

    try std.testing.expect(std.mem.startsWith(u8, oversize, "HTTP/1.1 431 Request Header Fields Too Large\r\n"));
}

test "one connection thread starts up front, more start as connections arrive up to the limit, and they are used again after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var events: Events = undefined;
    events.init();
    defer events.deinit();
    var replies = MessageQueue.init();
    defer replies.deinit();
    const server = try startServer(routerFor(@ptrFromInt(events.address()), &.{
        .{ .method = .GET, .path = "/slow", .handle = answerWhenReleased },
        .{ .method = .GET, .path = "/fast", .handle = echoPath },
    }), 2, .{
        .config = try eventsConfig(allocator, &events),
        .create = makeState,
        .destroy = freeState,
    });
    try events.waitFor(&events.states_made, 1);
    try io.sleep(.fromMilliseconds(100), .awake);
    try events.read();
    try std.testing.expectEqual(@as(u32, 1), events.states_made);

    // Two connections at once take two threads, the limit.
    var first: Client = undefined;
    try first.start(server.port, "/slow?key=first", &replies);
    var second: Client = undefined;
    try second.start(server.port, "/slow?key=second", &replies);
    try events.waitFor(&events.begun, 2);
    try std.testing.expectEqual(@as(u32, 2), events.states_made);
    try release(server, "first");
    try release(server, "second");
    first.join();
    second.join();
    for (0..2) |_| {
        const reply = try takeReply(&replies, allocator);
        try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nslow"));
    }

    // Later connections are served by the threads already there.
    for (0..4) |_| {
        _ = try exchange(io, allocator, server.port, try getRequest(allocator, "/fast"));
    }
    try events.read();
    try std.testing.expectEqual(@as(u32, 2), events.states_made);

    stopServer(server);
    try events.read();
    try std.testing.expectEqual(@as(u32, 2), events.states_freed);
}

test "a connection waits while every connection thread is busy, and is served once one is free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var events: Events = undefined;
    events.init();
    defer events.deinit();
    var slow_replies = MessageQueue.init();
    defer slow_replies.deinit();
    var fast_replies = MessageQueue.init();
    defer fast_replies.deinit();
    const server = try startServer(routerFor(@ptrFromInt(events.address()), &.{
        .{ .method = .GET, .path = "/slow", .handle = answerWhenReleased },
        .{ .method = .GET, .path = "/fast", .handle = echoPath },
    }), 1, null);
    defer stopServer(server);
    var slow: Client = undefined;
    try slow.start(server.port, "/slow?key=slow", &slow_replies);
    try events.waitFor(&events.begun, 1);

    var fast: Client = undefined;
    try fast.start(server.port, "/fast", &fast_replies);
    // The only thread is busy, so the second connection is not answered yet.
    try io.sleep(.fromMilliseconds(300), .awake);
    try std.testing.expect(fast_replies.tryTake(io, allocator) == null);

    try release(server, "slow");
    slow.join();
    fast.join();
    const fast_reply = try takeReply(&fast_replies, allocator);
    try std.testing.expect(std.mem.endsWith(u8, fast_reply, "\r\n\r\n/fast"));
    _ = try takeReply(&slow_replies, allocator);
}

test "the owner's message for a key reaches the connection thread that holds the key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var events: Events = undefined;
    events.init();
    defer events.deinit();
    var replies = MessageQueue.init();
    defer replies.deinit();
    const server = try startServer(routerFor(@ptrFromInt(events.address()), &.{
        .{ .method = .GET, .path = "/call", .handle = holdAndAnswer },
    }), 2, null);
    defer stopServer(server);
    var client: Client = undefined;
    try client.start(server.port, "/call", &replies);
    try events.waitFor(&events.begun, 1);

    try server.post(io, "{\"type\":\"answer\",\"key\":\"other\",\"text\":\"not this\"}");
    try server.post(io, "{\"type\":\"answer\",\"key\":\"call-1\",\"text\":\"this\"}");

    client.join();
    const reply = try takeReply(&replies, allocator);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n{\"type\":\"answer\",\"key\":\"call-1\",\"text\":\"this\"}"));
}

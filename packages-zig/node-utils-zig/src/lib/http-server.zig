//
// A small Express-like HTTP framework for Photosphere's asset server and MCP server. The HTTP itself is the standard library's
// (std.http), and this is the part around it: routes by method and path, a request with the helpers those two servers need, and the
// threads that serve the connections.
//
// The owner opens the listening socket first (`open`), so it knows the port without waiting to be told, and then starts the server
// with it (`start`). The server thread accepts connections and hands each to a connection thread from a pool: one is started up
// front, more are started as connections arrive up to the limit the owner passes, and they are used again after that. When every
// connection thread is busy, a new connection waits until one is free. The threads share nothing: each makes its own allocator and
// Io, is sent what it reads (the owner's configuration for it and the environment) as the first two messages on its queue, which
// it reads into memory of its own, makes its own state (the owner's `ConnectionState`), and they talk only by message. Each writes its log lines to the
// console itself.
//
// An accepting thread blocks in accept and posts each connection to the server thread, which blocks on its queue and hands the
// connection to a connection thread. On stop the server thread wakes the accepting thread with a connection of its own, and ends each
// connection thread's read of its connection. Each connection thread has a queue of its own that the server thread posts to. A
// handler that holds its connection open (an event stream) reads that queue too (`Request.waitForMessage`), so it sees `stop` and
// ends.
//
// A connection serves one request and is closed (every response says `connection: close`). Node keeps a connection alive for
// further requests; the page never depends on that.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const process_env = ziggy.task_queue.utils.process_env;

const MessageQueue = ziggy.message_queue.MessageQueue;
const Message = ziggy.message_queue.Message;
const ThreadAllocator = ziggy.thread_allocator.ThreadAllocator;
const json = ziggy.json;
const log = &utils.log.log;

//
// How long a connection may wait without sending a request before the server thread gives it up, in milliseconds.
//
pub const IDLE_LIMIT_MS = 10_000;

//
// The number the server thread's messages from the owner are posted under. A connection thread posts under its own number, counting
// from 1.
//
const from_owner = 0;

//
// One request, with the helpers the routes use. Its strings stay valid until the handler returns. The handler is given the
// connection thread's Io and an allocator freed when it returns, which the helpers that need them are given.
//
pub const Request = struct {
    // The standard library's request, which the handler responds through (respond and respondStreaming).
    http: *std.http.Server.Request,
    // The method.
    method: std.http.Method,
    // The path, without the query.
    path: []const u8,
    // The query, without the question mark, or empty.
    query: []const u8,
    // The Content-Type header, or null.
    contentType: ?[]const u8,
    // The Content-Length header, or null.
    contentLength: ?u64,
    // The connection thread's own state for the server (see ConnectionState), or null for a server that keeps none.
    state: ?*anyopaque,
    // The connection thread's queue, which the server thread posts to.
    messages: *MessageQueue,
    // The server thread's queue.
    serverQueue: *MessageQueue,
    // The connection thread's number, which its messages to the server thread are posted under.
    number: u32,
    // Set once the connection thread has been told to stop.
    stopped: bool,

    //
    // Tells the server thread this connection thread holds what the key names (a call waiting for its result, say), so the server
    // thread passes it the owner's messages for that key (see HttpServer.post). The hold ends when the request does.
    //
    pub fn hold(self: *Request, io: std.Io, allocator: std.mem.Allocator, key: []const u8) !void {
        const text = try json.stringify(allocator, .{
            .type = "hold",
            .key = key,
        });
        defer allocator.free(text);
        try self.serverQueue.post(io, self.number, text);
    }

    //
    // Reads one parameter of the query: the first value of the name, with percent-encoding and `+` decoded, allocated with the
    // allocator. Null when it is not there.
    //
    pub fn queryParameter(self: *Request, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
        return queryParameterOf(allocator, self.query, name);
    }

    //
    // The value of a header, or null. The headers are read from the request's head, which reading the body invalidates, so this is
    // called before the body is read.
    //
    pub fn header(self: *Request, name: []const u8) ?[]const u8 {
        var iterator = self.http.iterateHeaders();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                return entry.value;
            }
        }
        return null;
    }

    //
    // The reader of the body, which responds to a client's `Expect: 100-continue` first. Its buffer is allocated with the allocator.
    //
    pub fn bodyReader(self: *Request, allocator: std.mem.Allocator) !*std.Io.Reader {
        const buffer = try allocator.alloc(u8, 16 * 1024);
        return try self.http.readerExpectContinue(buffer);
    }

    //
    // Reads the whole body, of at most the limit, in bytes, allocated with the allocator. error.StreamTooLong when it is longer.
    //
    pub fn readBody(self: *Request, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        const reader = try self.bodyReader(allocator);
        return try reader.allocRemaining(allocator, .limited(limit));
    }

    //
    // Whether the request has a body to read.
    //
    pub fn hasBody(self: *Request) bool {
        return self.method.requestHasBody() and (self.http.head.content_length != null or self.http.head.transfer_encoding != .none);
    }

    //
    // Waits up to the timeout for a message to the connection thread, for a handler that holds its connection open, and returns it
    // with its text allocated with the allocator. Returns null when the timeout passed with none, or once the thread has been told to
    // stop, which `stopped` then says.
    //
    pub fn waitForMessage(self: *Request, io: std.Io, allocator: std.mem.Allocator, timeout_ms: u64) ?Message {
        if (self.stopped) {
            return null;
        }
        const message = self.messages.take(io, allocator, .{
            .duration = .{
                .raw = .fromMilliseconds(@intCast(timeout_ms)),
                .clock = .awake,
            },
        }) orelse {
            return null;
        };
        if (isType(message.text, "stop")) {
            allocator.free(message.text);
            self.stopped = true;
            return null;
        }
        return message;
    }
};

//
// The request the calling connection thread is serving, or null when it is serving none.
//
threadlocal var current_request: ?*Request = null;

//
// The request the calling connection thread is serving, for code a handler calls that is not given it (an MCP tool, say), or null
// on a thread that is serving none.
//
pub fn currentRequest() ?*Request {
    return current_request;
}

//
// A route's handler. It responds to the request through `request.http`, with the connection thread's Io, an allocator freed when it
// returns and `thread_arena`, an arena freed when the connection thread ends, for what outlives the request (a cache of the thread's
// state). An error it returns closes the connection.
//
pub const Handler = *const fn (context: ?*anyopaque, request: *Request, io: std.Io, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator) anyerror!void;

//
// One route: the method and path it serves, and its handler.
//
pub const Route = struct {
    // The method.
    method: std.http.Method,
    // The path, matched without regard to case and with or without a trailing slash, as Express matches it.
    path: []const u8,
    // The handler.
    handle: Handler,
};

//
// The routes of a server and what it does around them.
//
pub const Router = struct {
    // Passed to every handler: constant data of the program's (a value it never changes, declared as a constant), or null. Never the
    // owner's state: a handler reaches the connection thread's own state through `Request.state`.
    context: ?*anyopaque,
    // The routes, tried in order.
    routes: []const Route,
    // Runs before the routes, as Express middleware does, and returns true when it responded to the request itself. Null for none.
    before: ?*const fn (context: ?*anyopaque, request: *Request, io: std.Io, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator) anyerror!bool = null,
    // Responds to a request no route matches.
    notFound: Handler,

    //
    // Serves one request: `before`, then the first route of the request's method and path, then `notFound`.
    //
    pub fn handle(self: Router, request: *Request, io: std.Io, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator) !void {
        if (self.before) |before| {
            if (try before(self.context, request, io, allocator, thread_arena)) {
                return;
            }
        }
        for (self.routes) |route| {
            if (route.method == request.method and pathIs(request.path, route.path)) {
                return route.handle(self.context, request, io, allocator, thread_arena);
            }
        }
        return self.notFound(self.context, request, io, allocator, thread_arena);
    }

    //
    // The methods the routes serve for a path, joined with ", ", or null when no route has the path.
    //
    pub fn methodsOf(self: Router, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
        var methods: std.ArrayList(u8) = .empty;
        for (self.routes) |route| {
            if (!pathIs(path, route.path)) {
                continue;
            }
            if (methods.items.len > 0) {
                try methods.appendSlice(allocator, ", ");
            }
            try methods.appendSlice(allocator, @tagName(route.method));
        }
        if (methods.items.len == 0) {
            return null;
        }
        return methods.items;
    }
};

//
// The state each connection thread keeps for a server, which the thread makes when it starts and frees when it ends. A server that
// keeps none passes null. Its functions are constants of the program's.
//
pub const ConnectionState = struct {
    // What the owner tells each connection thread, as JSON text (the session id, say). Each thread is sent a copy of its own.
    config: []const u8 = "{}",
    // Makes a connection thread's state, on the thread, from its copy of the configuration, which stays valid while the thread runs,
    // with the thread's copy of the native app's callbacks (see ServerOptions.nativeCallbacks), which stays valid while it runs, and
    // with the thread's own allocator and Io.
    create: *const fn (config: []const u8, native_callbacks: ?*const ziggy.core.NativeCallbacks, allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque,
    // Frees it, on the same thread, with the thread's allocator.
    destroy: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,
};

//
// What a server is started with.
//
pub const ServerOptions = struct {
    // The routes.
    router: Router,
    // The most connection threads the server starts.
    maxConnectionThreads: usize,
    // The state each connection thread keeps, or null.
    connectionState: ?ConnectionState = null,
    // The native app's callbacks the connection threads call themselves (see ziggy.core.NativeCallbacks), each thread given a copy of
    // its own, or null for none.
    nativeCallbacks: ?ziggy.core.NativeCallbacks = null,
    // The environment the server thread and the connection threads read, or null for none. Each thread has an environment of its
    // own, which it is sent.
    environment: ?*const std.process.Environ.Map = null,
};

//
// What every thread of a server is given when it starts: values and constants it may copy. The configuration of the connection
// threads' state and the environment are not here: they are the first two messages on the thread's queue (see
// postConfigAndEnvironment), which the thread reads with its own allocator.
//
const ThreadStart = struct {
    // The routes, a constant.
    router: Router,
    // The most connection threads the server starts.
    maxConnectionThreads: usize,
    // The functions of the connection threads' state, constants, or null for a server that keeps none.
    connectionState: ?ConnectionState,
    // The thread's copy of the native app's callbacks, or null.
    nativeCallbacks: ?ziggy.core.NativeCallbacks,
};

//
// Posts the two messages every thread of a server is sent first: the configuration of the connection threads' state, as JSON text,
// then the environment, as JSON text of an object of names and values, or "null" for none.
//
fn postConfigAndEnvironment(io: std.Io, queue: *MessageQueue, config: []const u8, environment: []const u8) !void {
    try queue.post(io, from_owner, config);
    try queue.post(io, from_owner, environment);
}

//
// Takes the next of the two first messages from the calling thread's queue, with its own Io, and returns its text in the arena,
// which the thread keeps for as long as it runs.
//
fn takeFirstMessage(io: std.Io, arena: std.mem.Allocator, queue: *MessageQueue) []const u8 {
    const message = queue.take(io, arena, .none) orelse {
        @panic("an HTTP server thread's queue closed before it was sent its configuration and environment");
    };
    return message.text;
}

//
// Reads the environment message into a map in the arena, which the thread sets as its own, or returns null for none.
//
fn readEnvironment(arena: std.mem.Allocator, text: []const u8) ?std.process.Environ.Map {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| {
        std.debug.panic("an HTTP server thread could not read its environment ({s}): {s}", .{ @errorName(err), text });
    };
    if (value == .null) {
        return null;
    }
    return ziggy.worker.environmentFromJson(arena, value) catch |err| {
        std.debug.panic("an HTTP server thread could not read its environment: {s}", .{@errorName(err)});
    };
}


//
// A socket the owner opened, and the port it is listening on (the one the operating system chose, when 0 was asked for).
//
pub const Listener = struct {
    // The listening socket.
    server: std.Io.net.Server,
    // The port.
    port: u16,
};

//
// Opens a listening socket on the address and port, so the owner knows the port before the server starts.
//
pub fn open(io: std.Io, host: []const u8, port: u16) !Listener {
    const address = try std.Io.net.IpAddress.parseIp4(host, port);
    const server = try address.listen(io, .{});
    return .{
        .server = server,
        .port = server.socket.address.getPort(),
    };
}

//
// A running server, as its owner holds it. It is allocated with the owner's allocator, and every function is given the owner's Io and,
// where it allocates or frees, that allocator.
//
pub const HttpServer = struct {
    // The port the server is listening on.
    port: u16,
    // The address the server is listening on.
    address: std.Io.net.IpAddress,
    // The server thread's queue, which the owner and the connection threads post to.
    queue: MessageQueue,
    // The server thread.
    thread: std.Thread,

    //
    // Starts the server thread on a socket from `open`, which the server owns from now on. The server thread is sent the options'
    // configuration and environment as messages, so nothing the options point at is used once this returns.
    //
    pub fn start(io: std.Io, allocator: std.mem.Allocator, listener: Listener, options: ServerOptions) !*HttpServer {
        const self = try allocator.create(HttpServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .port = listener.port,
            .address = listener.server.socket.address,
            .queue = MessageQueue.init(),
            .thread = undefined,
        };
        errdefer self.queue.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const environment = if (options.environment) |map| try json.stringify(arena_state.allocator(), try ziggy.worker.environmentJson(arena_state.allocator(), map)) else "null";
        try postConfigAndEnvironment(io, &self.queue, if (options.connectionState) |state| state.config else "{}", environment);
        self.thread = try std.Thread.spawn(.{}, serverMain, .{ ThreadStart{
            .router = options.router,
            .maxConnectionThreads = options.maxConnectionThreads,
            .connectionState = options.connectionState,
            .nativeCallbacks = options.nativeCallbacks,
        }, listener.server, &self.queue });
        return self;
    }

    //
    // Tells the server thread to stop and waits for it, which waits for every connection thread, and frees the server with the owner's
    // allocator.
    //
    pub fn stop(self: *HttpServer, io: std.Io, allocator: std.mem.Allocator) void {
        self.queue.post(io, from_owner, "{\"type\":\"stop\"}") catch @panic("out of memory stopping an HTTP server");
        self.thread.join();
        self.queue.deinit();
        allocator.destroy(self);
    }

    //
    // Posts a message to the server thread, as JSON text, for a server whose owner tells it things while it runs. The message names a
    // key in "key", and the server thread passes it to the connection thread that holds the key (see Request.hold), or drops it when
    // none does.
    //
    pub fn post(self: *HttpServer, io: std.Io, text: []const u8) !void {
        try self.queue.post(io, from_owner, text);
    }
};

//
// What the server thread knows of one connection thread.
//
const ConnectionThread = struct {
    // The thread.
    thread: std.Thread,
    // Its queue, which the server thread posts to.
    queue: *MessageQueue,
    // The connection it is serving, or null when it is serving none. The server thread closes it once the connection thread reports it
    // free; the connection thread reads and writes it and never closes it.
    stream: ?std.Io.net.Stream,
    // Whether the connection was closed already, to end the connection thread's read on Windows (wakeConnection).
    closed: bool,
    // Whether the connection thread has read a request on the connection.
    requested: bool,
    // When the connection was handed over, in milliseconds on the awake clock, for the idle limit.
    handedAtMs: i64,
    // The keys it holds for the request it is serving (see Request.hold), owned.
    holds: std.ArrayList([]u8),
};

//
// The number the accepting thread's messages reach the server thread's queue under.
//
const from_accepting = std.math.maxInt(u32);

//
// The server thread: hands each connection the accepting thread accepts to a free connection thread, and passes messages between the
// owner and the connection threads, until it is told to stop. It blocks on its queue, waiting no longer than until a connection that
// has sent no request reaches the idle limit. It owns what it was given: its configuration and environment and its own allocator and
// Io. The listening socket goes to the accepting thread (acceptMain), which blocks in accept, and which the server thread wakes to stop
// with a connection of its own.
//
fn serverMain(start: ThreadStart, listener_given: std.Io.net.Server, queue: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    // The configuration and the environment, which the thread keeps for as long as it runs and sends on to each connection thread.
    var first_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer first_arena_state.deinit();
    const config = takeFirstMessage(io, first_arena_state.allocator(), queue);
    const environment_text = takeFirstMessage(io, first_arena_state.allocator(), queue);
    var environment = readEnvironment(first_arena_state.allocator(), environment_text);
    process_env.setEnvironMap(if (environment) |*map| map else null);
    defer process_env.setEnvironMap(null);
    const listening_port = listener_given.socket.address.getPort();
    var accept_queue = MessageQueue.init();
    defer accept_queue.deinit();
    const accepting = std.Thread.spawn(.{}, acceptMain, .{ listener_given, &accept_queue, queue }) catch |err| {
        log.exception("The HTTP server could not start accepting connections", err);
        var unused = listener_given;
        unused.deinit(io);
        return;
    };
    // Connections accepted while every connection thread was busy, oldest first.
    var waiting: std.ArrayList(std.Io.net.Stream) = .empty;
    var connections: std.ArrayList(ConnectionThread) = .empty;
    defer {
        stopAccepting(io, &accept_queue, accepting, listening_port);
        for (waiting.items) |stream| {
            stream.close(io);
        }
        waiting.deinit(allocator);
        for (connections.items) |*connection| {
            connection.queue.post(io, 0, "{\"type\":\"stop\"}") catch @panic("out of memory stopping an HTTP server");
            if (connection.stream != null) {
                wakeConnection(io, connection);
            }
        }
        for (connections.items) |*connection| {
            connection.thread.join();
            closeConnection(io, connection);
            connection.queue.deinit();
            allocator.destroy(connection.queue);
            for (connection.holds.items) |key| {
                allocator.free(key);
            }
            connection.holds.deinit(allocator);
        }
        connections.deinit(allocator);
        // What the accepting thread and the connection threads sent after the last message read: connections nobody will serve.
        while (queue.tryTake(io, allocator)) |message| {
            if (message.from == from_accepting) {
                streamOf(message.text).close(io);
            }
            allocator.free(message.text);
        }
    }
    // One connection thread is started up front.
    startConnectionThread(io, allocator, &start, config, environment_text, &connections, queue) catch |err| {
        log.exception("The HTTP server could not start a connection thread", err);
    };
    while (true) {
        const message = queue.take(io, allocator, idleTimeout(io, connections.items)) orelse {
            wakeIdleConnections(io, connections.items);
            continue;
        };
        if (message.from == from_accepting) {
            const stream = streamOf(message.text);
            allocator.free(message.text);
            const index = freeConnection(connections.items) orelse blk: {
                if (connections.items.len >= start.maxConnectionThreads) {
                    // Every connection thread is busy and there may be no more: the connection waits until one is free.
                    waiting.append(allocator, stream) catch @panic("out of memory keeping a connection");
                    continue;
                }
                startConnectionThread(io, allocator, &start, config, environment_text, &connections, queue) catch |err| {
                    log.exception("The HTTP server could not start a connection thread", err);
                    stream.close(io);
                    continue;
                };
                break :blk connections.items.len - 1;
            };
            handOver(io, allocator, &connections.items[index], stream);
            continue;
        }
        if (message.from != from_owner and isType(message.text, "free")) {
            allocator.free(message.text);
            const connection = &connections.items[message.from - 1];
            closeConnection(io, connection);
            for (connection.holds.items) |key| {
                allocator.free(key);
            }
            connection.holds.clearRetainingCapacity();
            if (waiting.items.len > 0) {
                handOver(io, allocator, connection, waiting.orderedRemove(0));
            }
            continue;
        }
        if (message.from != from_owner and isType(message.text, "request")) {
            allocator.free(message.text);
            connections.items[message.from - 1].requested = true;
            continue;
        }
        if (!handleServerMessage(io, allocator, connections.items, message)) {
            return;
        }
    }
}

//
// The accepting thread: accepts connections on the listening socket, which it owns and closes, and posts each to the server thread,
// until it is sent "stop" on its own queue. It blocks in accept and reads its queue after each connection it accepts, so the server
// thread wakes it with a connection of its own after sending "stop" (stopAccepting).
//
fn acceptMain(listener_given: std.Io.net.Server, queue: *MessageQueue, server_queue: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    var listener = listener_given;
    defer listener.deinit(io);
    while (true) {
        const stream = listener.accept(io) catch |err| {
            log.exception("The HTTP server could not accept a connection", err);
            continue;
        };
        if (queue.tryTake(io, allocator)) |message| {
            allocator.free(message.text);
            stream.close(io);
            return;
        }
        const text = connectionMessage(allocator, stream) catch @panic("out of memory passing on a connection");
        defer allocator.free(text);
        server_queue.post(io, from_accepting, text) catch @panic("out of memory passing on a connection");
    }
}

//
// Sends the accepting thread "stop", wakes it from accept with a connection to the server's own port and waits for it to end.
//
fn stopAccepting(io: std.Io, accept_queue: *MessageQueue, accepting: std.Thread, port: u16) void {
    accept_queue.post(io, 0, "{\"type\":\"stop\"}") catch @panic("out of memory stopping an HTTP server");
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    if (address.connect(io, .{ .mode = .stream })) |stream| {
        stream.close(io);
    }
    else |_| {}
    accepting.join();
}

//
// How long the server thread may wait for its next message: until the first connection that has sent no request reaches the idle
// limit, or for as long as it takes when there is none.
//
fn idleTimeout(io: std.Io, connections: []const ConnectionThread) std.Io.Timeout {
    const now = std.Io.Clock.awake.now(io).toMilliseconds();
    var soonest: ?i64 = null;
    for (connections) |connection| {
        if (connection.stream == null or connection.requested or connection.closed) {
            continue;
        }
        const left = @max(0, connection.handedAtMs + IDLE_LIMIT_MS - now);
        if (soonest == null or left < soonest.?) {
            soonest = left;
        }
    }
    const milliseconds = soonest orelse {
        return .none;
    };
    return .{
        .duration = .{
            .raw = .fromMilliseconds(milliseconds),
            .clock = .awake,
        },
    };
}

//
// Gives up each connection that has sent no request within the idle limit, by ending its connection thread's read. A browser opens
// connections it never sends a request on, and each would otherwise hold a connection thread for as long as the browser keeps it.
//
fn wakeIdleConnections(io: std.Io, connections: []ConnectionThread) void {
    const now = std.Io.Clock.awake.now(io).toMilliseconds();
    for (connections) |*connection| {
        if (connection.stream == null or connection.requested or connection.closed) {
            continue;
        }
        if (connection.handedAtMs + IDLE_LIMIT_MS <= now) {
            wakeConnection(io, connection);
        }
    }
}

//
// Ends a connection thread's read of its connection, so it reads its messages, stop among them. Shutting the receiving side down
// wakes the read on Linux, macOS and Android. On Windows it does not, and closing the socket does, so there the socket is closed here
// and not again when the thread reports it free.
//
fn wakeConnection(io: std.Io, connection: *ConnectionThread) void {
    const stream = connection.stream orelse {
        return;
    };
    if (connection.closed) {
        return;
    }
    if (builtin.os.tag == .windows) {
        stream.close(io);
        connection.closed = true;
        return;
    }
    stream.shutdown(io, .recv) catch |err| switch (err) {
        error.ConnectionAborted, error.ConnectionResetByPeer, error.SocketUnconnected => {},
        else => @panic("the HTTP server could not shut a connection down"),
    };
    // Counted as answered, so the idle limit does not shut it down again.
    connection.requested = true;
}

//
// Closes the connection a connection thread was serving, unless it was closed already, and marks the thread free.
//
fn closeConnection(io: std.Io, connection: *ConnectionThread) void {
    if (connection.stream) |stream| {
        if (!connection.closed) {
            stream.close(io);
        }
    }
    connection.stream = null;
    connection.closed = false;
    connection.requested = false;
}

//
// Handles one message to the server thread: "stop" from the owner, "hold" from a connection thread, or a message from the owner for the
// connection thread that holds its key, which it passes on. Frees the message's text. Returns false when the server is to stop.
//
fn handleServerMessage(io: std.Io, allocator: std.mem.Allocator, connections: []ConnectionThread, message: Message) bool {
    defer allocator.free(message.text);
    if (message.from == from_owner and isType(message.text, "stop")) {
        return false;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), message.text, .{}) catch {
        log.@"error"("The HTTP server was sent a message that is not JSON");
        return true;
    };
    const key = json.getString(parsed, "key") orelse {
        log.@"error"("The HTTP server was sent a message with no key");
        return true;
    };
    if (message.from != from_owner) {
        // "hold": the connection thread holds the key.
        const connection = &connections[message.from - 1];
        const owned = allocator.dupe(u8, key) catch @panic("out of memory recording a hold");
        connection.holds.append(allocator, owned) catch @panic("out of memory recording a hold");
        return true;
    }
    for (connections) |connection| {
        for (connection.holds.items) |held| {
            if (std.mem.eql(u8, held, key)) {
                connection.queue.post(io, 0, message.text) catch @panic("out of memory passing a message on");
                return true;
            }
        }
    }
    return true;
}

//
// The index of a connection thread that is not serving a connection, or null.
//
fn freeConnection(connections: []const ConnectionThread) ?usize {
    for (connections, 0..) |connection, index| {
        if (connection.stream == null) {
            return index;
        }
    }
    return null;
}

//
// Starts a connection thread, numbered by its place in the list from 1, and sends it the server thread's configuration
// and the environment.
//
fn startConnectionThread(io: std.Io, allocator: std.mem.Allocator, start: *const ThreadStart, config: []const u8, environment: []const u8, connections: *std.ArrayList(ConnectionThread), server_queue: *MessageQueue) !void {
    const queue = try allocator.create(MessageQueue);
    errdefer allocator.destroy(queue);
    queue.* = MessageQueue.init();
    errdefer queue.deinit();
    const number: u32 = @intCast(connections.items.len + 1);
    try connections.ensureUnusedCapacity(allocator, 1);
    try postConfigAndEnvironment(io, queue, config, environment);
    const thread = try std.Thread.spawn(.{}, connectionMain, .{ start.*, number, queue, server_queue });
    connections.appendAssumeCapacity(.{
        .thread = thread,
        .queue = queue,
        .stream = null,
        .closed = false,
        .requested = false,
        .handedAtMs = 0,
        .holds = .empty,
    });
}

//
// The message that hands a connection over by its socket: from the accepting thread to the server thread, and from the server thread
// to a connection thread. Allocated with the allocator.
//
fn connectionMessage(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"connection\",\"socket\":{d}}}", .{handleNumber(stream.socket.handle)});
}

//
// Hands a connection to a free connection thread by its socket. The connection thread reads and writes it, and the server thread
// closes it once the connection thread reports it free.
//
fn handOver(io: std.Io, allocator: std.mem.Allocator, connection: *ConnectionThread, stream: std.Io.net.Stream) void {
    const text = connectionMessage(allocator, stream) catch @panic("out of memory handing a connection over");
    defer allocator.free(text);
    connection.queue.post(io, 0, text) catch @panic("out of memory handing a connection over");
    connection.stream = stream;
    connection.closed = false;
    connection.requested = false;
    connection.handedAtMs = std.Io.Clock.awake.now(io).toMilliseconds();
}

//
// A connection thread: serves the connections it is handed, one at a time, until it is told to stop. It makes its own allocator, Io
// and state, and reads its configuration and environment into memory of its own.
//
fn connectionMain(start: ThreadStart, number: u32, queue: *MessageQueue, server_queue: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    // What outlives a request and lives as long as the thread, which each handler is given (see Handler), and holds the
    // configuration and the environment.
    var thread_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer thread_arena_state.deinit();
    const thread_arena = thread_arena_state.allocator();
    const config = takeFirstMessage(io, thread_arena, queue);
    var environment = readEnvironment(thread_arena, takeFirstMessage(io, thread_arena, queue));
    process_env.setEnvironMap(if (environment) |*map| map else null);
    defer process_env.setEnvironMap(null);
    var native_callbacks = start.nativeCallbacks;
    const state: ?*anyopaque = if (start.connectionState) |maker| maker.create(config,if (native_callbacks) |*callbacks| callbacks else null, allocator, io) catch |err| {
        log.exception("An HTTP connection thread could not make its state", err);
        return;
    } else null;
    defer if (start.connectionState) |maker| maker.destroy(state.?, allocator);
    while (true) {
        const message = queue.take(io, allocator, .none) orelse {
            @panic("an HTTP connection thread's queue closed");
        };
        if (isType(message.text, "stop")) {
            allocator.free(message.text);
            return;
        }
        if (!isType(message.text, "connection")) {
            // A message for a request that has ended: there is nobody to give it to.
            allocator.free(message.text);
            continue;
        }
        const socket = socketOf(message.text);
        allocator.free(message.text);
        const stopped = serveConnection(io, allocator, thread_arena, socket, state, queue, server_queue, number, start.router);
        server_queue.post(io, number, "{\"type\":\"free\"}") catch @panic("out of memory freeing a connection thread");
        if (stopped) {
            return;
        }
    }
}

//
// Reads one request on the connection and has the router serve it. The server thread closes the connection once this thread reports
// it free. Returns true when the thread was told to stop while it served it.
//
fn serveConnection(io: std.Io, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator, socket: std.Io.net.Socket.Handle, state: ?*anyopaque, queue: *MessageQueue, server_queue: *MessageQueue, number: u32, router: Router) bool {
    const stream: std.Io.net.Stream = .{
        .socket = .{
            .handle = socket,
            .address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable,
        },
    };
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    // Blocks until the request comes. The server thread ends the read when the connection has been idle for IDLE_LIMIT_MS, or on stop.
    var http_request = server.receiveHead() catch |err| {
        // The client closed a connection it never sent a request on, or sent something that is not a request, which Node responds to
        // with a 400 (or a 431 when the head is too big).
        switch (err) {
            error.HttpConnectionClosing, error.ReadFailed, error.HttpRequestTruncated => {},
            error.HttpHeadersInvalid => {
                refuse(&writer.interface, "400 Bad Request");
                letClientReadRefusal(stream, io, &reader.interface);
            },
            error.HttpHeadersOversize => {
                refuse(&writer.interface, "431 Request Header Fields Too Large");
                letClientReadRefusal(stream, io, &reader.interface);
            },
        }
        return stopRequested(io, allocator, queue);
    };
    server_queue.post(io, number, "{\"type\":\"request\"}") catch @panic("out of memory reporting a request");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The target and the content type point into the request's head, which reading the body invalidates.
    const target = arena.dupe(u8, http_request.head.target) catch @panic("out of memory reading a request");
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    var request: Request = .{
        .http = &http_request,
        .method = http_request.head.method,
        .path = target[0 .. query_start orelse target.len],
        .query = if (query_start) |start| target[start + 1 ..] else "",
        .contentType = if (http_request.head.content_type) |value| arena.dupe(u8, value) catch @panic("out of memory reading a request") else null,
        .contentLength = http_request.head.content_length,
        .state = state,
        .messages = queue,
        .serverQueue = server_queue,
        .number = number,
        .stopped = false,
    };
    current_request = &request;
    defer current_request = null;
    router.handle(&request, io, arena, thread_arena) catch |err| {
        log.exception("The HTTP server could not respond to a request", err);
    };
    return request.stopped or stopRequested(io, allocator, queue);
}

//
// Whether the connection thread has been sent "stop", read from the messages already on its queue. Other messages there are for a
// request that has ended and are dropped.
//
fn stopRequested(io: std.Io, allocator: std.mem.Allocator, queue: *MessageQueue) bool {
    var stop = false;
    while (queue.tryTake(io, allocator)) |message| {
        if (isType(message.text, "stop")) {
            stop = true;
        }
        allocator.free(message.text);
    }
    return stop;
}

//
// The connection of a "connection" message, as a stream to close or hand over.
//
fn streamOf(text: []const u8) std.Io.net.Stream {
    return .{
        .socket = .{
            .handle = socketOf(text),
            .address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable,
        },
    };
}

//
// Whether a message's JSON text is of the type, read without parsing it: the type is the first field of every message here.
//
fn isType(text: []const u8, comptime message_type: []const u8) bool {
    return std.mem.startsWith(u8, text, "{\"type\":\"" ++ message_type ++ "\"");
}

//
// The socket of a "connection" message.
//
fn socketOf(text: []const u8) std.Io.net.Socket.Handle {
    const marker = "\"socket\":";
    const start = (std.mem.indexOf(u8, text, marker) orelse @panic("a connection message has no socket")) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '}') orelse text.len;
    const number = std.fmt.parseInt(u64, text[start..end], 10) catch @panic("a connection message has a socket that is not a number");
    return if (builtin.os.tag == .windows) @ptrFromInt(number) else @intCast(number);
}

//
// A socket as a number, to send in a message.
//
fn handleNumber(handle: std.Io.net.Socket.Handle) u64 {
    return if (builtin.os.tag == .windows) @intFromPtr(handle) else @intCast(handle);
}

//
// Whether a request path is the route's path: case-insensitive, and with or without a trailing slash.
//
pub fn pathIs(path: []const u8, route: []const u8) bool {
    var trimmed = path;
    if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return std.ascii.eqlIgnoreCase(trimmed, route);
}

//
// Reads one parameter of a query string: the first value of the name, with percent-encoding and `+` decoded.
// Returns null when the name is not there.
//
pub fn queryParameterOf(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=');
        const key = try decodeQueryComponent(allocator, pair[0 .. equals orelse pair.len]);
        if (!std.mem.eql(u8, key, name)) {
            continue;
        }
        const value = if (equals) |position| pair[position + 1 ..] else "";
        return try decodeQueryComponent(allocator, value);
    }
    return null;
}

//
// Decodes a component of a query string: `+` is a space and `%XX` is a byte. A `%` that does not start two hexadecimal digits is left
// as it is.
//
fn decodeQueryComponent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const character = text[index];
        if (character == '+') {
            try decoded.append(allocator, ' ');
            index += 1;
        }
        else if (character == '%' and index + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[index + 1 .. index + 3], 16)) |byte| {
                try decoded.append(allocator, byte);
                index += 3;
            }
            else |_| {
                try decoded.append(allocator, character);
                index += 1;
            }
        }
        else {
            try decoded.append(allocator, character);
            index += 1;
        }
    }
    return decoded.items;
}

//
// Gives the client the time to read a refusal. A client that sent a request head too big to read is still sending when the response
// goes, and a connection closed with unread data resets, which can throw the response away before the client has read it. The server
// says it has finished writing, then takes in what is still arriving, up to a limit, until the client closes its end.
//
fn letClientReadRefusal(stream: std.Io.net.Stream, io: std.Io, reader: *std.Io.Reader) void {
    stream.shutdown(io, .send) catch {
        return;
    };
    _ = reader.discardShort(refusal_drain_limit) catch {};
}

//
// How much of what a refused client is still sending is taken in before the connection is closed, in bytes.
//
const refusal_drain_limit = 64 * 1024;

//
// Responds to a request that could not be read with its status, and closes the connection.
//
fn refuse(writer: *std.Io.Writer, status: []const u8) void {
    writer.print("HTTP/1.1 {s}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", .{status}) catch |err| {
        log.exception("The HTTP server could not refuse a request", err);
        return;
    };
    writer.flush() catch |err| {
        log.exception("The HTTP server could not refuse a request", err);
    };
}

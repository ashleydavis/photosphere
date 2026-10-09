//
// A small HTTP server: the Zig counterpart of Node's `createServer(app)` followed by `server.listen(port, host)`, which the asset
// server of the TypeScript uses. There is no TypeScript counterpart to port: the HTTP itself is Node's (std.http here), and this is
// the glue that Node's http module is: listening, accepting, and a thread for each connection.
//
// It listens on the address it is given, which is the loopback address for the asset server, on a port the operating system chooses
// when the port is 0. A connection is served on a thread of its own that owns everything it uses, because a browser opens connections
// it never sends a request on, and a thread waiting on one cannot be woken. Such a thread ends when the browser closes the
// connection, and `close` does not wait for it. It does wait for a request that is being answered.
//
// A connection serves one request and is closed (every response says `connection: close`), as the example's media server does.
// Node keeps a connection alive for further requests; the page never depends on that, and a thread that is kept waiting for a
// request that may never come is the thing that cannot be woken.
//

const std = @import("std");
const utils = @import("utils-zig");

const log = &utils.log.log;

//
// The function that answers requests (the express `app` of the TypeScript). It is called on the thread of the connection with an
// allocator that is freed when it returns, and answers the request through `request`, which reads the body and writes the
// response. An error it returns closes the connection.
//
pub const RequestHandler = struct {
    // The handler's own pointer, passed back on every call.
    context: ?*anyopaque,

    // Answers one request.
    handle: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) anyerror!void,
};

//
// What the server and the threads of its connections share. It lives until the server and every connection thread have let go of
// it, because a thread waiting on an idle connection outlives the server.
//
const Shared = struct {
    // Allocates this and everything a connection thread allocates. It must be safe to use from many threads.
    allocator: std.mem.Allocator,

    // Answers the requests.
    handler: RequestHandler,

    // Set once the server is closed: a connection that sends a request after that is closed unanswered.
    closed: std.atomic.Value(bool),

    // The number of requests being answered.
    busy: std.atomic.Value(u32),

    // The number of holders of this: the server, the accept thread and each connection thread.
    references: std.atomic.Value(u32),

    //
    // Lets go of this, and frees it if that was the last hold.
    //
    fn release(self: *Shared) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    }

    //
    // Says a request is about to be answered. Returns false when the server is closed, and then it must not be.
    //
    fn beginRequest(self: *Shared) bool {
        _ = self.busy.fetchAdd(1, .seq_cst);
        if (self.closed.load(.seq_cst)) {
            _ = self.busy.fetchSub(1, .seq_cst);
            return false;
        }
        return true;
    }

    //
    // Says a request has been answered.
    //
    fn endRequest(self: *Shared) void {
        _ = self.busy.fetchSub(1, .seq_cst);
    }
};

//
// A running server.
//
pub const HttpServer = struct {
    // What the server shares with its threads.
    shared: *Shared,

    // The listening socket. Owned by the accept thread while it runs.
    listener: std.Io.net.Server,

    // The port the server is listening on (the one the operating system chose, when 0 was asked for).
    port: u16,

    // The thread that accepts connections.
    accept_thread: std.Thread,

    // The Io the server was started with, used to wake the accept thread and to wait.
    io: std.Io,

    //
    // Starts listening on the address and port. The allocator must be safe to use from many threads. Returns once the server is
    // listening, so the port is known.
    //
    pub fn listen(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16, handler: RequestHandler) !*HttpServer {
        const address = try std.Io.net.IpAddress.parseIp4(host, port);
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{
            .allocator = allocator,
            .handler = handler,
            .closed = .init(false),
            .busy = .init(0),
            // The server's hold, and the accept thread's.
            .references = .init(2),
        };
        const server = try allocator.create(HttpServer);
        errdefer allocator.destroy(server);
        server.* = .{
            .shared = shared,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .accept_thread = undefined,
            .io = io,
        };
        server.accept_thread = try std.Thread.spawn(.{}, acceptMain, .{ shared, &server.listener, io, server.port });
        return server;
    }

    //
    // Stops listening and waits for the requests being answered to finish. A connection that is idle is left to end when its other
    // side closes it, and answers nothing more. Frees the server.
    //
    pub fn close(self: *HttpServer) void {
        const allocator = self.shared.allocator;
        self.shared.closed.store(true, .seq_cst);
        // Accepting blocks, so a connection made here makes the accept thread look at the flag.
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (address.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        }
        else |err| {
            log.exception("Could not wake the HTTP server's accept thread", err);
        }
        self.accept_thread.join();
        self.listener.deinit(self.io);
        while (self.shared.busy.load(.seq_cst) > 0) {
            self.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
        self.shared.release();
        allocator.destroy(self);
    }
};

//
// The body of the accept thread: accepts connections until the server is closed, and serves each on a thread of its own.
//
fn acceptMain(shared: *Shared, listener: *std.Io.net.Server, io: std.Io, port: u16) void {
    _ = port;
    defer shared.release();
    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (shared.closed.load(.seq_cst)) {
                return;
            }
            log.exception("The HTTP server could not accept a connection", err);
            continue;
        };
        if (shared.closed.load(.seq_cst)) {
            stream.close(io);
            return;
        }
        _ = shared.references.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, connectionMain, .{ shared, stream }) catch |err| {
            log.exception("The HTTP server could not start a thread for a connection", err);
            stream.close(io);
            shared.release();
            continue;
        };
        thread.detach();
    }
}

//
// The body of the thread of a connection: reads one request, has the handler answer it and closes the connection.
//
fn connectionMain(shared: *Shared, stream: std.Io.net.Stream) void {
    defer shared.release();
    // The thread owns its Io, so the connection can wait for its request after the server and the Io that started it are gone. It
    // may be asked to run work of its own (the retry of the ported code does).
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = shared.allocator;
    threaded.concurrent_limit = .unlimited;
    defer threaded.deinit();
    const io = threaded.io();
    defer stream.close(io);

    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch |err| {
        // The browser closed a connection it never sent a request on, or sent something that is not a request.
        switch (err) {
            error.HttpConnectionClosing, error.ReadFailed, error.HttpRequestTruncated => {},
            else => log.exception("The HTTP server could not read a request", err),
        }
        return;
    };
    if (!shared.beginRequest()) {
        return;
    }
    defer shared.endRequest();

    var arena_state = std.heap.ArenaAllocator.init(shared.allocator);
    defer arena_state.deinit();
    shared.handler.handle(shared.handler.context, arena_state.allocator(), io, &request) catch |err| {
        log.exception("The HTTP server could not answer a request", err);
    };
}

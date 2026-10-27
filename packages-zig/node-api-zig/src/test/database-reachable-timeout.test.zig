const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const thread_messages = @import("../../../utils-zig/src/test/thread-messages.zig");
const MessageQueue = thread_messages.MessageQueue;
const ThreadAllocator = thread_messages.ThreadAllocator;
const media_file_database = node_api.media_file_database;
const errors = utils.errors;

//
// The bound on finding out whether a database is reachable.
//
// What this protects is a user waiting on an answer. Nothing else bounds the read: the S3 client's own
// request ceiling is ten minutes, set for a phone pushing a large video through the engine bridge, and
// falling through to it leaves someone opening a database on a screen that never resolves. The server here
// accepts the connection and then answers nothing, which is what a phone reaching a stopped server through
// an `adb reverse` forward gets (the real S3 client talks to it over HTTP, as it does to MinIO).
//
// The server runs on a thread of its own, which makes its own Io and allocator, and shares nothing with the test: it is given what
// it needs as JSON on its queue of orders, tells the test its port on the test's queue of events, and, when it is silent, learns how
// far the client's clock has moved from the queue the client's VirtualTimeIo posts each move to.
//
const SilentServer = struct {
    // The thread the server runs on.
    thread: std.Thread,

    // The server's orders, which the test posts and the server's thread takes: first the Order, then the stop.
    orders: MessageQueue,

    // What the server's thread tells the test, which the test takes.
    events: MessageQueue,

    // The moves of the client's clock, which the client's VirtualTimeIo posts and a silent server's thread takes: a silent server
    // holds a connection until that clock has run for as long as the client waits, which is when the client has given up, and then
    // closes it (the S3 client's wait for an answer cannot be cancelled, so it ends only when the connection does).
    moves: MessageQueue,

    // The port the system chose, as the server's thread told the test.
    port: u16,

    //
    // What the server's thread is given when it starts.
    //
    const Order = struct {
        // Whether the server answers every request with an empty 200 instead of staying silent.
        answers: bool,
    };

    //
    // What the server's thread takes from its orders after each connection: whether to stop.
    //
    const Stop = struct {
        stop: bool,
    };

    //
    // What the server's thread tells the test once it listens.
    //
    const Listening = struct {
        port: u16,
    };

    //
    // One move of the client's clock, as VirtualTimeIo posts it.
    //
    const Move = struct {
        jumped_nanoseconds: i64,
    };

    //
    // Starts the server on its thread, listening on a free port of 127.0.0.1, and waits for its port. A silent server is given the
    // client's clock, whose moves are posted to the server from now on.
    //
    fn start(self: *SilentServer, io: std.Io, allocator: std.mem.Allocator, answers: bool, clientClock: ?*virtual_time_io.VirtualTimeIo) !void {
        self.orders = MessageQueue.init();
        self.events = MessageQueue.init();
        self.moves = MessageQueue.init();
        if (clientClock) |clock| {
            clock.postMovesTo(&self.moves);
        }
        try thread_messages.post(&self.orders, io, allocator, Order{
            .answers = answers,
        });
        self.thread = try std.Thread.spawn(.{}, serve, .{ &self.orders, &self.events, &self.moves });
        self.port = (try thread_messages.take(Listening, &self.events, io, allocator)).port;
    }

    //
    // Tells the server's thread to stop, makes a last connection to wake its accept, and waits for it to end. Closing the moves lets a
    // silent server that still holds a connection go.
    //
    fn stop(self: *SilentServer, io: std.Io, allocator: std.mem.Allocator) void {
        thread_messages.post(&self.orders, io, allocator, Stop{
            .stop = true,
        }) catch @panic("out of memory stopping the server");
        self.moves.close(io);
        const address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
        if (address.connect(io, .{
            .mode = .stream,
        })) |stream| {
            stream.close(io);
        }
        else |_| {}
        self.thread.join();
        self.orders.deinit();
        self.events.deinit();
        self.moves.deinit();
    }

    //
    // Answers the request of one connection with an empty 200, then closes the connection.
    //
    fn answerOnce(io: std.Io, stream: std.Io.net.Stream) void {
        var receiveBuffer: [16 * 1024]u8 = undefined;
        var sendBuffer: [4096]u8 = undefined;
        var connectionReader = stream.reader(io, &receiveBuffer);
        var connectionWriter = stream.writer(io, &sendBuffer);
        var httpServer = std.http.Server.init(&connectionReader.interface, &connectionWriter.interface);
        var request = httpServer.receiveHead() catch {
            return;
        };
        request.respond("", .{
            .status = .ok,
            .keep_alive = false,
        }) catch {};
    }

    //
    // Holds a connection until the client's clock has moved by 30 seconds, as its moves say, or until the moves are closed.
    //
    fn holdUntilClientGivesUp(io: std.Io, arena: std.mem.Allocator, moves: *MessageQueue) void {
        while (true) {
            const message = moves.take(io, arena, .none) orelse {
                return;
            };
            const parsed = std.json.parseFromSliceLeaky(Move, arena, message.text, .{}) catch |err| {
                std.debug.panic("The server could not read a move of the client's clock: {s}", .{@errorName(err)});
            };
            if (parsed.jumped_nanoseconds >= 30_000 * std.time.ns_per_ms) {
                return;
            }
        }
    }

    //
    // The server's thread: takes its order, listens, tells the test its port, and accepts connections until told to stop. A
    // silent server reads nothing and answers nothing until the client gives up. An answering one replies to each request with an
    // empty 200.
    //
    fn serve(orders: *MessageQueue, events: *MessageQueue, moves: *MessageQueue) void {
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = thread_allocator.allocator();
        defer threaded.deinit();
        const io = threaded.io();
        const order = thread_messages.take(Order, orders, io, arena) catch |err| {
            std.debug.panic("The server got no order: {s}", .{@errorName(err)});
        };
        const address = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
        var server = address.listen(io, .{
            .reuse_address = true,
        }) catch |err| {
            std.debug.panic("The server could not listen: {s}", .{@errorName(err)});
        };
        defer server.deinit(io);
        thread_messages.post(events, io, arena, Listening{
            .port = server.socket.address.getPort(),
        }) catch @panic("out of memory telling the test the port");
        while (true) {
            const stream = server.accept(io) catch {
                return;
            };
            if (order.answers) {
                answerOnce(io, stream);
            }
            else {
                holdUntilClientGivesUp(io, arena, moves);
            }
            stream.close(io);
            const stopped = thread_messages.tryTake(Stop, orders, io, arena) catch |err| {
                std.debug.panic("The server could not read its orders: {s}", .{@errorName(err)});
            };
            if (stopped != null) {
                return;
            }
        }
    }
};

test "checkDatabaseExists gives up when the storage never answers, rather than waiting on the client's ten minute ceiling" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var server: SilentServer = undefined;
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const clientIo = virtual_time.io();
    try server.start(io, allocator, false, &virtual_time);
    defer server.stop(io, allocator);
    const previous = try allocator.dupe(u8, test_environment.getEnvironment().get("PHOTOSPHERE_CONFIG_DIR").?);
    const configDir = try temp_dirs.makeTempDir(allocator, io, "database-reachable-timeout-config");
    defer temp_dirs.removeTempDir(io, configDir);
    defer test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", previous) catch |err| {
        std.debug.panic("PHOTOSPHERE_CONFIG_DIR could not be put back: {s}", .{@errorName(err)});
    };
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ configDir, "databases.toml" }), "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:bucket/unreachable\"\ns3_key = \"database-reachable-timeout-s3\"\n");
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "database-reachable-timeout-s3",
        .type = "s3-credentials",
        .value = try std.fmt.allocPrint(allocator, "{{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\",\"endpoint\":\"http://127.0.0.1:{d}\"}}", .{server.port}),
    });

    const started = std.Io.Clock.awake.now(clientIo);
    try std.testing.expectError(error.Thrown, media_file_database.checkDatabaseExists(allocator, clientIo, log, "s3:bucket/unreachable", null));
    const elapsedMilliseconds = started.durationTo(std.Io.Clock.awake.now(clientIo)).toMilliseconds();

    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "Operation timed out after 30000ms: "));
    try std.testing.expect(elapsedMilliseconds >= 30_000);
    try std.testing.expect(elapsedMilliseconds < 60_000);
}

test "checkDatabaseExists answers normally when the storage does answer" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var server: SilentServer = undefined;
    try server.start(io, allocator, true, null);
    defer server.stop(io, allocator);
    const previous = try allocator.dupe(u8, test_environment.getEnvironment().get("PHOTOSPHERE_CONFIG_DIR").?);
    const configDir = try temp_dirs.makeTempDir(allocator, io, "database-reachable-answers-config");
    defer temp_dirs.removeTempDir(io, configDir);
    defer test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", previous) catch |err| {
        std.debug.panic("PHOTOSPHERE_CONFIG_DIR could not be put back: {s}", .{@errorName(err)});
    };
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ configDir, "databases.toml" }), "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:bucket/reachable\"\ns3_key = \"database-reachable-answers-s3\"\n");
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "database-reachable-answers-s3",
        .type = "s3-credentials",
        .value = try std.fmt.allocPrint(allocator, "{{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\",\"endpoint\":\"http://127.0.0.1:{d}\"}}", .{server.port}),
    });

    const exists = try media_file_database.checkDatabaseExists(allocator, io, log, "s3:bucket/reachable", null);

    try std.testing.expect(exists);
}

const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
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
const SilentServer = struct {
    // The io the server runs on.
    io: std.Io,

    // The listening socket.
    server: std.Io.net.Server,

    // The port the system chose.
    port: u16,

    // Runs the loop that accepts connections.
    group: std.Io.Group,

    // Set to stop the loop: it is checked after each connection, and stop makes a last connection to wake it.
    stopping: std.atomic.Value(bool),

    // Whether the server answers every request with an empty 200 instead of staying silent.
    answers: bool,

    // The clock of the client, when the test moves it: a silent server holds a connection until that clock has run for as long as
    // the client waits, which is when the client has given up, and then closes it (the S3 client's wait for an answer cannot be
    // cancelled, so it ends only when the connection does). Null when the server answers.
    clientClock: ?*virtual_time_io.VirtualTimeIo,

    //
    // Listens on a free port of 127.0.0.1 and starts accepting connections.
    //
    fn start(self: *SilentServer, io: std.Io, answers: bool, clientClock: ?*virtual_time_io.VirtualTimeIo) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{
            .io = io,
            .server = try address.listen(io, .{
                .reuse_address = true,
            }),
            .port = 0,
            .group = .init,
            .stopping = .init(false),
            .answers = answers,
            .clientClock = clientClock,
        };
        self.port = self.server.socket.address.getPort();
        try self.group.concurrent(io, serve, .{self});
    }

    //
    // Stops the loop and closes the socket.
    //
    fn stop(self: *SilentServer) void {
        self.stopping.store(true, .release);
        const address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
        if (address.connect(self.io, .{
            .mode = .stream,
        })) |stream| {
            stream.close(self.io);
        }
        else |_| {}
        self.group.await(self.io) catch {};
        self.server.deinit(self.io);
    }

    //
    // Answers the request of one connection with an empty 200, then closes the connection.
    //
    fn answerOnce(self: *SilentServer, stream: std.Io.net.Stream) void {
        var receiveBuffer: [16 * 1024]u8 = undefined;
        var sendBuffer: [4096]u8 = undefined;
        var connectionReader = stream.reader(self.io, &receiveBuffer);
        var connectionWriter = stream.writer(self.io, &sendBuffer);
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
    // Accepts connections until stopped. A silent server reads nothing and answers nothing until the client gives up and
    // closes. An answering one replies to each request with an empty 200.
    //
    fn serve(self: *SilentServer) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.accept(self.io) catch {
                return;
            };
            defer stream.close(self.io);
            if (self.answers) {
                self.answerOnce(stream);
                continue;
            }
            while (self.clientClock.?.jumped_nanoseconds.load(.monotonic) < 30_000 * std.time.ns_per_ms) {
                self.io.sleep(.fromMilliseconds(2), .awake) catch {
                    return;
                };
            }
        }
    }
};

test "checkDatabaseExists gives up when the storage never answers, rather than waiting on the client's ten minute ceiling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var server: SilentServer = undefined;
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const clientIo = virtual_time.io();
    try server.start(io, false, &virtual_time);
    defer server.stop();
    const previous = try allocator.dupe(u8, test_environment.getEnvironment().get("PHOTOSPHERE_CONFIG_DIR").?);
    const configDir = try temp_dirs.makeTempDir(allocator, io, "database-reachable-timeout-config");
    defer temp_dirs.removeTempDir(io, configDir);
    defer test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", previous) catch {};
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:bucket/unreachable\"\ns3_key = \"database-reachable-timeout-s3\"\n");
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "database-reachable-timeout-s3",
        .type = "s3-credentials",
        .value = try std.fmt.allocPrint(allocator, "{{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\",\"endpoint\":\"http://127.0.0.1:{d}\"}}", .{server.port}),
    });

    const started = std.Io.Clock.awake.now(clientIo);
    try std.testing.expectError(error.Thrown, media_file_database.checkDatabaseExists(allocator, clientIo, "s3:bucket/unreachable"));
    const elapsedMilliseconds = started.durationTo(std.Io.Clock.awake.now(clientIo)).toMilliseconds();

    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "Operation timed out after 30000ms: "));
    try std.testing.expect(elapsedMilliseconds >= 30_000);
    try std.testing.expect(elapsedMilliseconds < 60_000);
}

test "checkDatabaseExists answers normally when the storage does answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var server: SilentServer = undefined;
    try server.start(io, true, null);
    defer server.stop();
    const previous = try allocator.dupe(u8, test_environment.getEnvironment().get("PHOTOSPHERE_CONFIG_DIR").?);
    const configDir = try temp_dirs.makeTempDir(allocator, io, "database-reachable-answers-config");
    defer temp_dirs.removeTempDir(io, configDir);
    defer test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", previous) catch {};
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:bucket/reachable\"\ns3_key = \"database-reachable-answers-s3\"\n");
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "database-reachable-answers-s3",
        .type = "s3-credentials",
        .value = try std.fmt.allocPrint(allocator, "{{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\",\"endpoint\":\"http://127.0.0.1:{d}\"}}", .{server.port}),
    });

    const exists = try media_file_database.checkDatabaseExists(allocator, io, "s3:bucket/reachable");

    try std.testing.expect(exists);
}

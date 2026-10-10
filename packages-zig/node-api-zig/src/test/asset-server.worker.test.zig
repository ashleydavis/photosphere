//
// Tests for asset-server.worker.zig.
//
// These serve a real asset from a real database in a directory of its own.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const http_requests = @import("http-requests.zig");
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const asset_server_worker = node_api.asset_server_worker;
const media_file_database = node_api.media_file_database;
const TaskContext = task_queue_zig.task_context.TaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;

const io = std.testing.io;

//
// The bytes the database serves for every asset request.
//
const ASSET_BYTES = "hello-asset-bytes";

//
// A running asset-server task: captures the messages the handler sends and lets the test cancel it.
//
const RunningTask = struct {
    // Allocates the messages and the handler's result.
    arena: std.heap.ArenaAllocator,

    // Deterministic uuids.
    uuidGenerator: TestUuidGenerator,

    // Deterministic time.
    timestampProvider: TestTimestampProvider,

    // The task context passed to the handler.
    context: TaskContext,

    // Guards the messages.
    mutex: std.Io.Mutex,

    // Messages captured from context.sendMessage, as JSON text.
    messages: std.ArrayList([]const u8),

    // The thread running the handler.
    thread: std.Thread,

    // What the handler returned, once the thread has ended.
    result: ?anyerror!std.json.Value,

    // Captures what the handler wrote to standard output and standard error (the test program talks to the build over standard output).
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    //
    // Records a message the handler sends.
    //
    fn sendMessage(context: ?*anyopaque, message: std.json.Value) void {
        const self: *RunningTask = @ptrCast(@alignCast(context.?));
        const text = std.json.Stringify.valueAlloc(std.heap.smp_allocator, message, .{}) catch @panic("out of memory");
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.messages.append(std.heap.smp_allocator, text) catch @panic("out of memory");
    }

    //
    // The body of the thread: runs the handler to its end.
    //
    fn run(self: *RunningTask) void {
        const allocator = self.arena.allocator();
        var data: std.json.ObjectMap = .empty;
        data.put(allocator, "port", .{ .integer = 0 }) catch @panic("out of memory");
        self.result = asset_server_worker.assetServerHandler(allocator, io, .{ .object = data }, self.context.taskContext());
    }

    //
    // Starts the handler on a thread.
    //
    fn start(self: *RunningTask) !void {
        self.arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        self.uuidGenerator = try TestUuidGenerator.init(self.arena.allocator());
        self.timestampProvider = .{};
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "test-session", "asset-server-task", .{
            .context = self,
            .function = sendMessage,
        }, 10);
        self.mutex = .init;
        self.messages = .empty;
        self.result = null;
        self.stdout = std.Io.Writer.Allocating.init(std.heap.smp_allocator);
        self.stderr = std.Io.Writer.Allocating.init(std.heap.smp_allocator);
        utils.console.setCapture(&self.stdout.writer, &self.stderr.writer);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    //
    // Waits until the asset-server-ready message arrives and returns the bound port.
    //
    fn waitForReadyPort(self: *RunningTask) !u16 {
        var attempt: u32 = 0;
        while (attempt < 500) : (attempt += 1) {
            self.mutex.lockUncancelable(io);
            for (self.messages.items) |text| {
                if (std.mem.indexOf(u8, text, "\"type\":\"asset-server-ready\"") != null) {
                    self.mutex.unlock(io);
                    const parsed = try std.json.parseFromSliceLeaky(asset_server_worker.IAssetServerReadyMessage, self.arena.allocator(), text, .{});
                    return parsed.port;
                }
            }
            self.mutex.unlock(io);
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.AssetServerReadyNotReceived;
    }

    //
    // Cancels the task, waits for the handler to end and returns what it returned.
    //
    fn cancelAndFinish(self: *RunningTask) !asset_server_worker.IAssetServerTaskResult {
        self.context.cancel();
        self.thread.join();
        utils.console.setCapture(null, null);
        const value = try self.result.?;
        return std.json.parseFromValueLeaky(asset_server_worker.IAssetServerTaskResult, self.arena.allocator(), value, .{});
    }

    //
    // Frees what the task allocated.
    //
    fn deinit(self: *RunningTask) void {
        self.stdout.deinit();
        self.stderr.deinit();
        self.arena.deinit();
    }
};

//
// A database with one asset in it.
//
fn makeDatabase(fixture: *DatabaseFixture, allocator: std.mem.Allocator, name: []const u8) !void {
    try fixture.init(allocator, io, name);
    var stream = std.Io.Reader.fixed(ASSET_BYTES);
    try media_file_database.writeAssetStream(allocator, io, fixture.database.assetStorage, fixture.rawStorage, "putter", "asset-1", "thumb", "image/jpeg", &stream, ASSET_BYTES.len);
}

//
// The target of a GET /asset request for the asset, in the database at the path.
//
fn assetTarget(allocator: std.mem.Allocator, databasePath: []const u8, assetId: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/asset?id={s}&type=thumb&db={s}", .{ assetId, try encodeComponent(allocator, databasePath) });
}

//
// Percent-encodes a path for a query string.
//
fn encodeComponent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    for (text) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.') {
            try encoded.append(allocator, character);
        }
        else {
            try encoded.print(allocator, "%{X:0>2}", .{character});
        }
    }
    return encoded.items;
}

test "assetServerHandler binds a port, reports asset-server-ready, serves GET /asset, and stops on cancel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database: DatabaseFixture = undefined;
    try makeDatabase(&database, allocator, "worker-serve");
    defer database.deinit(io);
    var task: RunningTask = undefined;
    try task.start();
    defer task.deinit();

    const port = try task.waitForReadyPort();
    try std.testing.expect(port > 0);

    const reply = try http_requests.send(allocator, io, .GET, port, try assetTarget(allocator, database.dir, "asset-1"), .{
        .contentType = null,
        .payload = null,
    });
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings(ASSET_BYTES, reply.body);

    const result = try task.cancelAndFinish();
    try std.testing.expectEqual(port, result.port);
}

test "assetServerHandler returns 400 when the id parameter is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var task: RunningTask = undefined;
    try task.start();
    defer task.deinit();

    const port = try task.waitForReadyPort();
    const reply = try http_requests.send(allocator, io, .GET, port, "/asset?type=thumb&db=%2Fdb%2Fpath", .{
        .contentType = null,
        .payload = null,
    });
    try std.testing.expectEqual(@as(u16, 400), reply.status);

    _ = try task.cancelAndFinish();
}

test "assetServerHandler binds the loopback interface and reports it in asset-server-ready" {
    var task: RunningTask = undefined;
    try task.start();
    defer task.deinit();

    _ = try task.waitForReadyPort();
    task.mutex.lockUncancelable(io);
    var found = false;
    for (task.messages.items) |text| {
        if (std.mem.indexOf(u8, text, "\"type\":\"asset-server-ready\"") != null) {
            const ready = try std.json.parseFromSliceLeaky(asset_server_worker.IAssetServerReadyMessage, task.arena.allocator(), text, .{});
            try std.testing.expectEqualStrings("127.0.0.1", ready.host);
            found = true;
        }
    }
    task.mutex.unlock(io);
    try std.testing.expect(found);

    const result = try task.cancelAndFinish();
    try std.testing.expectEqualStrings("127.0.0.1", result.host);
}

test "assetServerHandler stops serving after the task is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var task: RunningTask = undefined;
    try task.start();
    defer task.deinit();

    const port = try task.waitForReadyPort();
    _ = try task.cancelAndFinish();

    // The server is closed, so a request to the (now released) port should fail to connect.
    try std.testing.expect(std.meta.isError(http_requests.send(allocator, io, .GET, port, "/asset?id=asset-1&type=thumb&db=%2Fdb", .{
        .contentType = null,
        .payload = null,
    })));
}

test "assetServerHandler logs when it is listening and when it has stopped" {
    var task: RunningTask = undefined;
    try task.start();
    defer task.deinit();

    const port = try task.waitForReadyPort();
    const result = try task.cancelAndFinish();

    const listening = try std.fmt.allocPrint(task.arena.allocator(), "Asset server task listening on http://127.0.0.1:{d}", .{port});
    const stopped = try std.fmt.allocPrint(task.arena.allocator(), "Asset server task on http://127.0.0.1:{d} stopped", .{port});
    const output = task.stdout.written();
    try std.testing.expectEqual(port, result.port);
    try std.testing.expect(std.mem.indexOf(u8, output, listening) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, stopped) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, listening).? < std.mem.indexOf(u8, output, stopped).?);
}

test "assetServerHandler binds the port it is asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // A free port: bind one, note it, release it.
    const probe = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try probe.listen(io, .{});
    const freePort = listener.socket.address.getPort();
    listener.deinit(io);
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    var timestampProvider: TestTimestampProvider = .{};
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    var context = TaskContext.init(uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider(), "test-session", "asset-server-task", .{
        .context = null,
        .function = ignoreMessage,
    }, 10);
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "port", .{ .integer = freePort });
    context.cancel();

    // Cancelled before it starts, the handler still binds, reports and stops.
    const value = try asset_server_worker.assetServerHandler(allocator, io, .{ .object = data }, context.taskContext());

    const result = try std.json.parseFromValueLeaky(asset_server_worker.IAssetServerTaskResult, allocator, value, .{});
    try std.testing.expectEqual(freePort, result.port);
}

//
// A task context whose messages go nowhere.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

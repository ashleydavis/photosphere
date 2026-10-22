const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const console_capture = @import("console-capture.zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const errors = utils.errors;
const prefetchDatabaseHandler = node_api.prefetch_database_worker.prefetchDatabaseHandler;
const replicateDatabaseHandler = node_api.replicate_database_worker.replicateDatabaseHandler;
const TaskContext = task_queue_zig.task_context.TaskContext;

//
// The id of the asset in test/dbs/v6.
//
const ASSET_ID = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// The thumbnail of the asset in test/dbs/v6.
//
const THUMB_PATH = "thumb/" ++ ASSET_ID;

//
// A metadata shard of test/dbs/v6.
//
const SHARD_PATH = ".db/bson/collections/metadata/shards/96.dat";

//
// The metadata collection file of test/dbs/v6.
//
const COLLECTION_PATH = ".db/bson/collections/metadata/collection.dat";

//
// A task context whose messages go nowhere.
//
const TestContext = struct {
    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // Deterministic time.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The task context.
    context: TaskContext,

    //
    // Drops a message.
    //
    fn sendMessage(context: ?*anyopaque, message: std.json.Value) void {
        _ = context;
        _ = message;
    }
};

//
// Builds a minimal ITaskContext for testing, cancelled from the start when isCancelled is true.
//
fn makeContext(allocator: std.mem.Allocator, io: std.Io, isCancelled: bool) !*TestContext {
    _ = try test_environment.setupEnvironment(io);
    const testContext = try allocator.create(TestContext);
    testContext.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
        .context = undefined,
    };
    testContext.context = TaskContext.init(testContext.uuidGenerator.uuidGenerator(), testContext.timestampProvider.timestampProvider(), "session-1", "prefetch-task-id", .{
        .context = null,
        .function = TestContext.sendMessage,
    }, 10);
    if (isCancelled) {
        testContext.context.cancel();
    }
    return testContext;
}

//
// The directories of a test: a copy of test/dbs/v6 as the origin and a partial replica of it.
//
const Directories = struct {
    // The directory holding everything.
    root: []const u8,

    // The origin database.
    origin: []const u8,

    // The partial replica of the origin.
    local: []const u8,
};

//
// Creates a copy of test/dbs/v6 and a partial replica of it holding all of its thumbnails and BSON files, naming the
// copy as the replica's origin when withOrigin is true.
//
fn makePartialReplica(allocator: std.mem.Allocator, io: std.Io, testContext: *TestContext, withOrigin: bool) !Directories {
    const origin = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    const root = std.fs.path.dirname(origin).?;
    const local = try std.fs.path.join(allocator, &.{ root, "local" });
    _ = try replicateDatabaseHandler(allocator, io, try node_api.replicate_database.replicateDatabaseDataToJson(allocator, .{
        .sourcePath = origin,
        .destPath = local,
        .partial = true,
        .force = false,
    }), testContext.context.taskContext());
    const localRawStorage = try test_files.directoryStorage(allocator, io, local);

    // The replica starts out holding every thumbnail and BSON file of the origin, so each test decides what it is
    // missing.
    try temp_dirs.copyDirectory(allocator, io, try pathIn(allocator, origin, "thumb"), try pathIn(allocator, local, "thumb"));
    try temp_dirs.copyDirectory(allocator, io, try pathIn(allocator, origin, ".db/bson"), try pathIn(allocator, local, ".db/bson"));

    if (withOrigin) {
        try api.database_config.updateDatabaseConfig(allocator, io, localRawStorage, .{
            .origin = origin,
        });
    }
    else {
        try deleteFileIn(allocator, io, local, ".db/config.json");
    }
    return .{
        .root = root,
        .origin = origin,
        .local = local,
    };
}

//
// The path of a file in a directory.
//
fn pathIn(allocator: std.mem.Allocator, dir: []const u8, fileName: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ dir, fileName });
}

//
// Deletes a file of a directory, so the replica is missing it.
//
fn deleteFileIn(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, fileName: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io, try pathIn(allocator, dir, fileName));
}

//
// Builds the prefetch-database task data for a database path.
//
fn makeData(allocator: std.mem.Allocator, databasePath: []const u8) !std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "databasePath", .{ .string = databasePath });
    return .{ .object = data };
}

//
// Checks a prefetch result against the expected counts.
//
fn expectResult(result: std.json.Value, filesFetched: i64, filesStillMissing: i64) !void {
    try std.testing.expectEqual(filesFetched, result.object.get("filesFetched").?.integer);
    try std.testing.expectEqual(filesStillMissing, result.object.get("filesStillMissing").?.integer);
}

test "throws when databasePath is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);

    try std.testing.expectError(error.Thrown, prefetchDatabaseHandler(allocator, io, try makeData(allocator, ""), testContext.context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "returns without copying for a full (non-partial) database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const local = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(local).?);
    const origin = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(origin).?);
    try api.database_config.updateDatabaseConfig(allocator, io, try test_files.directoryStorage(allocator, io, local), .{
        .origin = origin,
    });

    _ = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, local), testContext.context.taskContext());

    try std.testing.expect(!test_files.fileExists(io, try pathIn(allocator, local, "thumb/63e9c63a-9164-6376-13e9-ef4d00000000")));
}

test "returns without copying when the partial database has no origin configured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, false);
    defer temp_dirs.removeTempDir(io, dirs.root);
    try deleteFileIn(allocator, io, dirs.local, THUMB_PATH);

    _ = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext());

    try std.testing.expect(!test_files.fileExists(io, try pathIn(allocator, dirs.local, THUMB_PATH)));
}

test "copies files missing from the partial replica out of origin storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);

    // thumb/ has one file missing, .db/bson another.
    try deleteFileIn(allocator, io, dirs.local, THUMB_PATH);
    try deleteFileIn(allocator, io, dirs.local, SHARD_PATH);

    _ = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext());

    try std.testing.expectEqualStrings(try test_files.readFile(allocator, io, try pathIn(allocator, dirs.origin, THUMB_PATH)), try test_files.readFile(allocator, io, try pathIn(allocator, dirs.local, THUMB_PATH)));
    try std.testing.expectEqualStrings(try test_files.readFile(allocator, io, try pathIn(allocator, dirs.origin, SHARD_PATH)), try test_files.readFile(allocator, io, try pathIn(allocator, dirs.local, SHARD_PATH)));
}

test "skips files that already exist in the local replica" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);

    // The local copy differs from the origin's, so copying it again would show.
    try test_files.writeFile(io, try pathIn(allocator, dirs.local, THUMB_PATH), "local copy");

    _ = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext());

    try std.testing.expectEqualStrings("local copy", try test_files.readFile(allocator, io, try pathIn(allocator, dirs.local, THUMB_PATH)));
}

test "reports what it fetched, so the background loop knows whether to keep going" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);

    // The loop stops when a pass reports nothing fetched and nothing missing, and asks again
    // otherwise, so these two numbers are the whole of what it decides on.
    try deleteFileIn(allocator, io, dirs.local, THUMB_PATH);
    try deleteFileIn(allocator, io, dirs.local, SHARD_PATH);
    try deleteFileIn(allocator, io, dirs.local, COLLECTION_PATH);

    const result = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext());

    try expectResult(result, 3, 0);
}

test "reports nothing fetched and nothing missing for a replica that is already complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);

    // This is what tells the loop the replica is filled in and it can stop, rather than walking
    // every object at the origin again on every gap.
    const result = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext());

    try expectResult(result, 0, 0);
}

test "reports nothing fetched and nothing missing for a full database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const local = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(local).?);

    const result = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, local), testContext.context.taskContext());

    try expectResult(result, 0, 0);
}

test "stops copying when the task is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const setupContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, setupContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);
    try deleteFileIn(allocator, io, dirs.local, THUMB_PATH);

    // Cancelled before any batch runs, so nothing is copied.
    const cancelledContext = try makeContext(allocator, io, true);
    const result = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), cancelledContext.context.taskContext());

    try std.testing.expect(!test_files.fileExists(io, try pathIn(allocator, dirs.local, THUMB_PATH)));

    // And the file it had already found is reported as still missing. A cancelled pass that
    // reported nothing left behind would read to the loop exactly like a finished one, and the
    // loop would stop with the replica half filled in.
    try expectResult(result, 0, 1);
}

test "returns without copying when the config of the partial database is not an object or has no origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, false);
    defer temp_dirs.removeTempDir(io, dirs.root);
    try deleteFileIn(allocator, io, dirs.local, THUMB_PATH);

    const configs = [_][]const u8{ "[\"origin\"]", "{\"other\":1}" };
    for (configs) |config| {
        try test_files.writeFile(io, try pathIn(allocator, dirs.local, ".db/config.json"), config);

        const result = try prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext());

        try expectResult(result, 0, 0);
        try std.testing.expect(!test_files.fileExists(io, try pathIn(allocator, dirs.local, THUMB_PATH)));
    }
}

test "fails with the error of a file it could not fetch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);

    // A directory where the thumbnail should be: the replica does not hold the file, and cannot write it.
    try deleteFileIn(allocator, io, dirs.local, THUMB_PATH);
    try std.Io.Dir.cwd().createDirPath(io, try pathIn(allocator, dirs.local, THUMB_PATH ++ "/in-the-way"));
    // The retries log each failure; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    // The last failure is written to the console's stderr; captured here so nothing reaches the real one.
    var stderrCapture = std.Io.Writer.Allocating.init(allocator);
    console_capture.captureStderr(&stderrCapture.writer);
    defer console_capture.endConsoleCapture();

    try std.testing.expectError(error.Thrown, prefetchDatabaseHandler(allocator, io, try makeData(allocator, dirs.local), testContext.context.taskContext()));
    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "Failed to prefetch " ++ THUMB_PATH));
}

//
// How long the one file takes to come out of the origin, in milliseconds. Comfortably over retry's 30 second default and far
// under the long timeout a file copy is meant to get, so it separates the two: with the default the copy is abandoned, with the
// long one it finishes. The metadata hash index of a real database is nine files of about 13 MB each, and a phone cannot pull one
// of those down and write it inside thirty seconds.
//
const SLOW_READ_DELAY_MS: i64 = 45_000;

//
// Opens a file as the virtual time Io does, after waiting SLOW_READ_DELAY_MS on its clock first when the file is the origin's
// copy of SHARD_PATH. The local replica's copy (under the directory named "local") opens at once.
//
fn openOriginShardSlowly(userdata: ?*anyopaque, dir: std.Io.Dir, subPath: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata.?));
    const virtualTime: *virtual_time_io.VirtualTimeIo = @fieldParentPtr("threaded", threaded);
    const virtualIo = virtualTime.io();
    var isLocal = false;
    var components = std.mem.tokenizeAny(u8, subPath, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "local")) {
            isLocal = true;
        }
    }
    const isShard = std.mem.endsWith(u8, subPath, SHARD_PATH) or std.mem.endsWith(u8, subPath, "collections\\metadata\\shards\\96.dat");
    if (isShard and !isLocal) {
        virtualIo.sleep(.fromMilliseconds(SLOW_READ_DELAY_MS), .awake) catch {
            return error.Canceled;
        };
    }
    return virtualTime.vtable.dirOpenFile(userdata, dir, subPath, options);
}

test "copies a file that takes longer than the default retry timeout to read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const testContext = try makeContext(allocator, io, false);
    const dirs = try makePartialReplica(allocator, io, testContext, true);
    defer temp_dirs.removeTempDir(io, dirs.root);
    try deleteFileIn(allocator, io, dirs.local, SHARD_PATH);

    // The origin hands the file over slowly. The Io is wrapped rather than replaced so everything else about it is untouched.
    var slowVTable = virtual_time.vtable;
    slowVTable.dirOpenFile = openOriginShardSlowly;
    const slowIo: std.Io = .{
        .userdata = io.userdata,
        .vtable = &slowVTable,
    };

    const result = try prefetchDatabaseHandler(allocator, slowIo, try makeData(allocator, dirs.local), testContext.context.taskContext());

    try expectResult(result, 1, 0);
    try std.testing.expectEqualStrings(try test_files.readFile(allocator, io, try pathIn(allocator, dirs.origin, SHARD_PATH)), try test_files.readFile(allocator, io, try pathIn(allocator, dirs.local, SHARD_PATH)));
}

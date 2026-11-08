//
// Tests of how a task queue handler the app runs is given the app's data directory: the task adapter (fromNodeApiHandler, used by
// taskEntries) puts Ziggy's TaskContext.data_dir in the task's data, and the handler resolves a short database name against the `dbs`
// directory in it. The
// tasks run on a pool of real workers whose data directory the test sets, as the native app sets the core's, and the handler is the
// real check-database-exists, so the tests see what the app does with a name a user types.
//

const std = @import("std");
const ziggy = @import("ziggy");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const ILog = @import("utils-zig").log.ILog;
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const fixture_dirs = @import("fixture-dirs.zig");
const test_environment = @import("test-environment.zig");
const test_timers = @import("test-timers.zig");
const MockWorkerPool = ziggy.task_queue.mock_worker_pool.MockWorkerPool;
const TaskQueue = ziggy.task_queue.task_queue.TaskQueue;

//
// The task types of the pool: every task handler of node-api, wrapped by the adapter the app's core uses.
//
const task_entries = node_api.task_handlers.taskEntries(test_environment.registerMediaSources);

//
// Runs check-database-exists for a database path on a pool whose workers have the given data directory, and returns whether the
// task found a database there.
//
fn databaseExistsInTask(allocator: std.mem.Allocator, io: std.Io, log: ILog, data_dir: []const u8, databasePath: []const u8) !bool {
    const outputs = try runDatabaseTask(allocator, io, log, data_dir, "check-database-exists", databasePath);
    const parsed = try std.json.parseFromValueLeaky(node_api.check_database_exists_worker.ICheckDatabaseExistsResult, allocator, outputs.?, .{});
    return parsed.exists;
}

//
// Copies a test database fixture to `<data dir>/dbs/db` in a new temporary data directory, where the app keeps the databases it
// names by a short name, and returns the data directory.
//
fn copyTestDatabaseToDataDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const dataDir = try temp_dirs.makeTempDir(allocator, io, name);
    try temp_dirs.copyDirectory(allocator, io, try std.fs.path.join(allocator, &.{ fixture_dirs.TEST_DBS_DIR, name }), try std.fs.path.join(allocator, &.{ dataDir, "dbs", "db" }));
    return dataDir;
}

//
// Runs a task of the given type, given a database path, on a pool whose workers have the given data directory, and returns the
// task's outputs. The pool is the test thread's queue backend while the task runs.
//
fn runDatabaseTask(allocator: std.mem.Allocator, io: std.Io, log: ILog, data_dir: []const u8, taskType: []const u8, databasePath: []const u8) !?std.json.Value {
    const pool = try MockWorkerPool.init(allocator, 1, .{
        .sessionId = "test-session",
    }, &task_entries);
    // A worker takes its options when it starts, which is when the first task is added, so this is the data directory its tasks get.
    pool.pool.options.worker_options.dataDir = data_dir;
    ziggy.task_queue.queue_backend.setQueueBackend(pool.queueBackend());
    defer {
        test_environment.restoreQueueBackend();
        pool.deinit(io, allocator, test_timers.timers(), log);
    }
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    const queue = try TaskQueue.init(allocator, uuidGenerator.uuidGenerator(), "task-data-dir-test");
    defer queue.deinit(io, allocator, log);
    var taskData: std.json.ObjectMap = .empty;
    try taskData.put(allocator, "databasePath", .{
        .string = databasePath,
    });
    const taskId = try queue.addTask(io, allocator, log, taskType, .{
        .object = taskData,
    }, null, null);
    const result = (try queue.awaitTask(io, allocator, test_timers.timers(), log, taskId)) orelse {
        return error.TaskNotTracked;
    };
    if (result.errorMessage) |message| {
        std.debug.print("{s} failed: {s}\n", .{ taskType, message });
        return error.TaskFailed;
    }
    return result.outputs;
}

test "a task finds a database by its short name in the dbs directory of the app's data directory" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    try test_environment.setEnv("PHOTOSPHERE_DATA_DIR", null);
    const dataDir = try copyTestDatabaseToDataDir(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, dataDir);

    try std.testing.expect(try databaseExistsInTask(allocator, io, log, dataDir, "db"));
}

test "a task does not find a database by its short name directly in the app's data directory" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    try test_environment.setEnv("PHOTOSPHERE_DATA_DIR", null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    const dataDir = std.fs.path.dirname(databaseDir).?;
    defer temp_dirs.removeTempDir(io, dataDir);

    try std.testing.expect(!try databaseExistsInTask(allocator, io, log, dataDir, std.fs.path.basename(databaseDir)));
}

test "a task creates a database named by a short name in the dbs directory of the app's data directory, making that directory" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    try test_environment.setEnv("PHOTOSPHERE_DATA_DIR", null);
    const dataDir = try temp_dirs.makeTempDir(allocator, io, "task-data-dir-create");
    defer temp_dirs.removeTempDir(io, dataDir);

    _ = try runDatabaseTask(allocator, io, log, dataDir, "create-database", "my-photos");

    try std.testing.expect(try databaseExistsInTask(allocator, io, log, dataDir, "my-photos"));
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(allocator, &.{ dataDir, "dbs", "my-photos", ".db" }), .{});
}

test "a task with an empty data directory resolves a short name against the working directory" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    try test_environment.setEnv("PHOTOSPHERE_DATA_DIR", null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    // The database is not in the working directory, so its short name names nothing there; its path relative to the working directory
    // names it.
    try std.testing.expect(!try databaseExistsInTask(allocator, io, log, "", std.fs.path.basename(databaseDir)));
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    const relativePath = try std.fs.path.relative(allocator, currentPath, null, currentPath, databaseDir);
    try std.testing.expect(try databaseExistsInTask(allocator, io, log, "", relativePath));
}

test "PHOTOSPHERE_DATA_DIR overrides the data directory a task is given" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    const overrideDir = try copyTestDatabaseToDataDir(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, overrideDir);
    const elsewhere = try temp_dirs.makeTempDir(allocator, io, "task-data-dir-elsewhere");
    defer temp_dirs.removeTempDir(io, elsewhere);
    try test_environment.setEnv("PHOTOSPHERE_DATA_DIR", overrideDir);

    try std.testing.expect(try databaseExistsInTask(allocator, io, log, elsewhere, "db"));
}

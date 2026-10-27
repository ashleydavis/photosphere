const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const recording_task_context = @import("recording-task-context.zig");
const errors = utils.errors;
const getDatabaseSummaryHandler = node_api.get_database_summary_worker.getDatabaseSummaryHandler;
const getDatabaseSummary = node_api.media_file_database.getDatabaseSummary;
const openStorage = node_api.open_storage.openStorage;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;

//
// Runs the handler for a path.
//
fn run(allocator: std.mem.Allocator, io: std.Io, log: utils.log.ILog, context: *RecordingTaskContext, databasePath: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = databasePath });
    return getDatabaseSummaryHandler(allocator, io, test_timers.timers(), log, .{ .object = object }, context.taskContext());
}

test "opens storage at the requested database path and returns the summary computed against it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "50-assets");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    const result = try run(allocator, io, log, &context, databaseDir);

    // The summary the database itself gives when it is opened directly.
    const expected = try getDatabaseSummary(allocator, io, log, (try openStorage(allocator, io, log, databaseDir, null, null, null)).storage);
    const object = result.object;
    try std.testing.expectEqualStrings("full", object.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(expected.totalImports)), object.get("totalImports").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(expected.totalFiles)), object.get("totalFiles").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(expected.totalSize)), object.get("totalSize").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(expected.totalNodes)), object.get("totalNodes").?.integer);
    try std.testing.expectEqualStrings(expected.fullHash, object.get("fullHash").?.string);
    try std.testing.expectEqualStrings(expected.filesHash.?, object.get("filesHash").?.string);
    try std.testing.expectEqualStrings(expected.databaseHash.?, object.get("databaseHash").?.string);
    try std.testing.expectEqual(@as(i64, expected.databaseVersion), object.get("databaseVersion").?.integer);

    // The database holds assets, so the summary is not the summary of an empty database.
    try std.testing.expect(expected.totalFiles > 0);
    try std.testing.expect(expected.totalImports > 0);
}

test "opens storage at the requested database path" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "50-assets");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    // A summary of the database at that path can only be given by opening the storage at it.
    const result = try run(allocator, io, log, &context, databaseDir);

    try std.testing.expectEqualStrings("full", result.object.get("mode").?.string);
}

test "computes the summary against the opened storage" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "50-assets");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    const result = try run(allocator, io, log, &context, databaseDir);

    const expected = try getDatabaseSummary(allocator, io, log, (try openStorage(allocator, io, log, databaseDir, null, null, null)).storage);
    try std.testing.expectEqualStrings(expected.fullHash, result.object.get("fullHash").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(expected.totalFiles)), result.object.get("totalFiles").?.integer);
}

test "returns the summary produced by getDatabaseSummary" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "50-assets");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    const result = try run(allocator, io, log, &context, databaseDir);

    const expected = try getDatabaseSummary(allocator, io, log, (try openStorage(allocator, io, log, databaseDir, null, null, null)).storage);
    const text = try std.json.Stringify.valueAlloc(allocator, expected, .{
        .emit_null_optional_fields = false,
    });
    try std.testing.expectEqualStrings(text, try std.json.Stringify.valueAlloc(allocator, result, .{}));
}

test "leaves out the hashes a database that holds no files does not have" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "no-assets");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    const result = try run(allocator, io, log, &context, databaseDir);

    const expected = try getDatabaseSummary(allocator, io, log, (try openStorage(allocator, io, log, databaseDir, null, null, null)).storage);
    try std.testing.expectEqual(expected.filesHash == null, result.object.get("filesHash") == null);
    try std.testing.expectEqual(expected.databaseHash == null, result.object.get("databaseHash") == null);
    try std.testing.expectEqualStrings(expected.fullHash, result.object.get("fullHash").?.string);
}

test "throws when databasePath is empty" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, run(allocator, io, log, &context, ""));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws when the task data has no database path" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, getDatabaseSummaryHandler(allocator, io, test_timers.timers(), log, .{ .object = .empty }, context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws a descriptive error when the database path is not a string" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, getDatabaseSummaryHandler(allocator, io, test_timers.timers(), log, .{ .object = object }, context.taskContext()));
    try std.testing.expectEqualStrings("The get-database-summary task data is not valid: databasePath must be a string", errors.lastErrorMessage());
}

test "throws when no database lives at the path" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "get-database-summary-empty");
    defer temp_dirs.removeTempDir(io, emptyDir);

    try std.testing.expectError(error.Thrown, run(allocator, io, log, &context, emptyDir));
    try std.testing.expectEqualStrings("Failed to load merkle tree.", errors.lastErrorMessage());
}

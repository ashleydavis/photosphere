const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const recording_task_context = @import("recording-task-context.zig");
const errors = utils.errors;
const createDatabaseHandler = node_api.create_database_worker.createDatabaseHandler;
const checkDatabaseExists = node_api.media_file_database.checkDatabaseExists;
const getDatabaseSummary = node_api.media_file_database.getDatabaseSummary;
const openStorage = node_api.open_storage.openStorage;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;

//
// Runs the handler for a path.
//
fn run(allocator: std.mem.Allocator, io: std.Io, context: *RecordingTaskContext, databasePath: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = databasePath });
    return createDatabaseHandler(allocator, io, test_timers.timers(), .{ .object = object }, context.taskContext());
}

test "initializes a new empty database at a directory that does not exist yet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const rootDir = try temp_dirs.makeTempDir(allocator, io, "create-database-new");
    defer temp_dirs.removeTempDir(io, rootDir);
    const databaseDir = try std.fs.path.join(allocator, &.{ rootDir, "new-db" });
    try std.testing.expect(!try checkDatabaseExists(allocator, io, databaseDir, null));

    const output = try run(allocator, io, &context, databaseDir);

    try std.testing.expect(output == .null);
    try std.testing.expect(try checkDatabaseExists(allocator, io, databaseDir, null));
    const summary = try getDatabaseSummary(allocator, io, (try openStorage(allocator, io, databaseDir, null, null, null)).storage);
    try std.testing.expectEqual(@as(u64, 0), summary.totalImports);
    // The one file a new database holds is its README.
    try std.testing.expectEqual(@as(u64, 1), summary.totalFiles);
    try std.testing.expect(test_files.fileExists(io, try std.fs.path.join(allocator, &.{ databaseDir, ".db", "config.json" })));
}

test "initializes a new empty database in an empty directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "create-database-empty");
    defer temp_dirs.removeTempDir(io, emptyDir);

    _ = try run(allocator, io, &context, emptyDir);

    try std.testing.expect(try checkDatabaseExists(allocator, io, emptyDir, null));
}

test "refuses a directory that already holds a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    try std.testing.expectError(error.Thrown, run(allocator, io, &context, databaseDir));

    // The location is `pathJoin("fs:", path)` with forward slashes, so on Windows it reads "fs:/C:/...".
    const forwardSlashDir = try allocator.dupe(u8, databaseDir);
    std.mem.replaceScalar(u8, forwardSlashDir, '\\', '/');
    const location = try storage_zig.storage_factory.pathJoin(allocator, &.{ "fs:", forwardSlashDir });
    const expectedMessage = try std.fmt.allocPrint(allocator, "Cannot create new media file database in {s}. This storage location already contains files! Please create your database in a new empty directory.", .{location});
    try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
}

test "throws when no database path is supplied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, run(allocator, io, &context, ""));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws when the task data has no database path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, createDatabaseHandler(allocator, io, test_timers.timers(), .{ .object = .empty }, context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws a descriptive error when the database path is not a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, createDatabaseHandler(allocator, io, test_timers.timers(), .{ .object = object }, context.taskContext()));
    try std.testing.expectEqualStrings("The create-database task data is not valid: databasePath must be a string", errors.lastErrorMessage());
}

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const errors = utils.errors;
const checkDatabaseExistsHandler = node_api.check_database_exists_worker.checkDatabaseExistsHandler;
const ICheckDatabaseExistsResult = node_api.check_database_exists_worker.ICheckDatabaseExistsResult;
const TaskContext = task_queue_zig.task_context.TaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;

//
// A task context whose messages go nowhere (the handler ignores the context entirely).
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// The context and the generators it holds.
//
const TestContext = struct {
    // Deterministic uuids.
    uuidGenerator: TestUuidGenerator,

    // Deterministic time.
    timestampProvider: TestTimestampProvider,

    // The task context.
    context: TaskContext,

    //
    // Fills in the context.
    //
    fn init(self: *TestContext, allocator: std.mem.Allocator) !void {
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "test-session", "test-task", .{
            .context = null,
            .function = ignoreMessage,
        }, 10);
    }
};

//
// Runs the handler for a path and reads its result.
//
fn run(allocator: std.mem.Allocator, io: std.Io, testContext: *TestContext, databasePath: []const u8) !ICheckDatabaseExistsResult {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = databasePath });
    const output = try checkDatabaseExistsHandler(allocator, io, .{ .object = object }, testContext.context.taskContext());
    return std.json.parseFromValueLeaky(ICheckDatabaseExistsResult, allocator, output, .{});
}

test "reports exists=true when the database's merkle tree file is present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var testContext: TestContext = undefined;
    try testContext.init(allocator);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    const result = try run(allocator, io, &testContext, databaseDir);

    try std.testing.expect(result.exists);
}

test "reports exists=false when the directory exists but holds no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var testContext: TestContext = undefined;
    try testContext.init(allocator);
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "check-db-exists-empty");
    defer temp_dirs.removeTempDir(io, emptyDir);

    const result = try run(allocator, io, &testContext, emptyDir);

    try std.testing.expect(!result.exists);
}

test "reports exists=false when the path does not exist at all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var testContext: TestContext = undefined;
    try testContext.init(allocator);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "check-db-exists-missing");
    defer temp_dirs.removeTempDir(io, tempDir);

    const result = try run(allocator, io, &testContext, try std.fmt.allocPrint(allocator, "{s}/does-not-exist", .{tempDir}));

    try std.testing.expect(!result.exists);
}

test "throws when no database path is supplied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var testContext: TestContext = undefined;
    try testContext.init(allocator);

    try std.testing.expectError(error.Thrown, run(allocator, io, &testContext, ""));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws when the task data has no database path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var testContext: TestContext = undefined;
    try testContext.init(allocator);

    try std.testing.expectError(error.Thrown, checkDatabaseExistsHandler(allocator, io, .{ .object = .empty }, testContext.context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws a descriptive error when the database path is not a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var testContext: TestContext = undefined;
    try testContext.init(allocator);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, checkDatabaseExistsHandler(allocator, io, .{ .object = object }, testContext.context.taskContext()));
    try std.testing.expectEqualStrings("The check-database-exists task data is not valid: databasePath must be a string", errors.lastErrorMessage());
}

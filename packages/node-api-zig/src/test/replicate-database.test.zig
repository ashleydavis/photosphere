const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const errors = utils.errors;
const replicateDatabase = node_api.replicate_database.replicateDatabase;
const ReplicateProgressCallback = node_api.replicate_database.ReplicateProgressCallback;

//
// Records the progress strings of replicateDatabase.
//
fn recordProgress(context: ?*anyopaque, progress: []const u8) void {
    const recorder: *helpers.ProgressRecorder = @ptrCast(@alignCast(context.?));
    recorder.record(progress);
}

test "replicateDatabase runs the replicate-database task and returns its result and progress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    const sourceDir = try helpers.copyTestDatabase(allocator, io, "v6");
    const root = std.fs.path.dirname(sourceDir).?;
    defer helpers.removeTempDir(io, root);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);

    var recorder: helpers.ProgressRecorder = .{ .allocator = allocator };
    const onProgress: ReplicateProgressCallback = .{ .context = &recorder, .function = recordProgress };
    const result = try replicateDatabase(allocator, io, uuidGenerator.uuidGenerator(), .{
        .sourcePath = sourceDir,
        .destPath = try std.fmt.allocPrint(allocator, "{s}/dest", .{root}),
        .partial = false,
        .force = false,
    }, &onProgress);

    try std.testing.expectEqual(@as(u64, 1), result.filesImported);
    try std.testing.expectEqual(@as(u64, 3), result.copiedFiles);
    try std.testing.expectEqual(@as(u64, 1), result.copiedRecords);
    try std.testing.expectEqual(@as(usize, 0), result.prunedFiles.len);
    try std.testing.expectEqual(@as(usize, 4), recorder.messages.items.len);
    try std.testing.expectEqualStrings("Copied 1", recorder.messages.items[0]);
    try std.testing.expectEqualStrings("Copied 3 files, 1 records", recorder.messages.items[3]);
}

test "replicateDatabase throws the task error message when replication fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    const root = try helpers.makeTempDir(allocator, io, "replicate-database-missing");
    defer helpers.removeTempDir(io, root);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);

    try std.testing.expectError(error.Thrown, replicateDatabase(allocator, io, uuidGenerator.uuidGenerator(), .{
        .sourcePath = try std.fmt.allocPrint(allocator, "{s}/missing", .{root}),
        .destPath = try std.fmt.allocPrint(allocator, "{s}/dest", .{root}),
        .partial = false,
        .force = false,
    }, null));
    try std.testing.expectEqualStrings("Failed to load merkle tree", errors.lastErrorMessage());
}

test "replicateDatabase fails when the destination is an unrelated database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    const sourceDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(sourceDir).?);
    const destDir = try helpers.copyTestDatabase(allocator, io, "50-assets");
    defer helpers.removeTempDir(io, std.fs.path.dirname(destDir).?);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);

    try std.testing.expectError(error.Thrown, replicateDatabase(allocator, io, uuidGenerator.uuidGenerator(), .{
        .sourcePath = sourceDir,
        .destPath = destDir,
        .partial = false,
        .force = false,
    }, null));
    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "You are trying to replicate to a database that has a different ID than the source database.\nSource database ID: "));
}

test "replicateDatabaseDataToJson leaves out the optional keys that are not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try node_api.replicate_database.replicateDatabaseDataToJson(allocator, .{ .sourcePath = "/a", .destPath = "/b", .destEncryptionKey = "key", .partial = true, .force = false });
    try std.testing.expectEqualStrings("{\"sourcePath\":\"/a\",\"destPath\":\"/b\",\"destEncryptionKey\":\"key\",\"partial\":true,\"force\":false}", try std.json.Stringify.valueAlloc(allocator, value, .{}));
}

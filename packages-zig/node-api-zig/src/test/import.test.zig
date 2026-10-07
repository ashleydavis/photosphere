//
// Tests for addPaths (import.zig), which the TypeScript tests reach only through the CLI's add command.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const media_file_database = node_api.media_file_database;
const addPaths = node_api.import_module.addPaths;
const IAddSummary = media_file_database.IAddSummary;

//
// What the progress callback of an import saw.
//
const IProgressLog = struct {
    // The number of times the callback was called.
    calls: u32,

    // The number of files added in the last summary it was given.
    lastFilesAdded: f64,
};

//
// Records a progress report of addPaths.
//
fn recordProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, summary: *const IAddSummary) void {
    _ = currentlyScanning;
    const progressLog: *IProgressLog = @ptrCast(@alignCast(context.?));
    progressLog.calls += 1;
    progressLog.lastFilesAdded = summary.filesAdded;
}

test "addPaths imports a file into a new database, then finds it already there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    defer node_utils.termination.clearTerminationCallbacks();
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);

    // A new, empty database and a folder holding one photo.
    const root = try temp_dirs.makeTempDir(allocator, io, "add-paths");
    defer temp_dirs.removeTempDir(io, root);
    const databaseDir = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const created = try @import("storage-zig").storage_factory.createStorage(allocator, io, databaseDir, null, null);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, uuidGenerator.uuidGenerator(), database.metadataCollection, null);
    const photosDir = try std.fmt.allocPrint(allocator, "{s}/photos", .{root});
    try std.Io.Dir.cwd().createDirPath(io, photosDir);
    try std.Io.Dir.cwd().copyFile("../test/test.jpg", std.Io.Dir.cwd(), try std.fmt.allocPrint(allocator, "{s}/photo.jpg", .{photosDir}), io, .{});

    var progressLog: IProgressLog = .{ .calls = 0, .lastFilesAdded = 0 };
    const summary = try addPaths(allocator, io, uuidGenerator.uuidGenerator(), .{ .databasePath = databaseDir }, &.{photosDir}, null, "session-1", false, .{ .context = &progressLog, .function = recordProgress }, null);

    try std.testing.expectEqual(@as(f64, 1), summary.filesAdded);
    try std.testing.expectEqual(@as(f64, 1), summary.filesProcessed);
    try std.testing.expectEqual(summary.totalSize, summary.averageSize);
    try std.testing.expect(progressLog.calls > 0);
    try std.testing.expectEqual(@as(f64, 1), progressLog.lastFilesAdded);

    // The same folder again: the import record already holds the photo, so the scanner skips it before opening it
    // and no file message is sent for it (as in TypeScript).
    const again = try addPaths(allocator, io, uuidGenerator.uuidGenerator(), .{ .databasePath = databaseDir }, &.{photosDir}, null, "session-2", false, null, null);
    try std.testing.expectEqual(@as(f64, 0), again.filesAdded);
    try std.testing.expectEqual(@as(f64, 0), again.filesAlreadyAdded);
    try std.testing.expectEqual(@as(f64, 0), again.filesProcessed);
    try std.testing.expectEqual(@as(f64, 0), again.averageSize);
}

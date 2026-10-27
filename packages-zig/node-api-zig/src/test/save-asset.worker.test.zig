const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const database_fixture = @import("database-fixture.zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_task_context = @import("test-task-context.zig");
const saveAssetHandler = node_api.save_asset_worker.saveAssetHandler;
const DatabaseFixture = database_fixture.DatabaseFixture;
const TestTaskContext = test_task_context.TestTaskContext;
const errors = utils.errors;

//
// These tests give the handler a real database holding assets and a
// real destination file, and check what it wrote.
//

//
// Runs the handler for an asset.
//
fn run(allocator: std.mem.Allocator, io: std.Io, log: utils.log.ILog, testContext: *TestTaskContext, assetId: []const u8, assetType: []const u8, destPath: []const u8, databasePath: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "assetId", .{ .string = assetId });
    try object.put(allocator, "assetType", .{ .string = assetType });
    try object.put(allocator, "destPath", .{ .string = destPath });
    try object.put(allocator, "databasePath", .{ .string = databasePath });
    return saveAssetHandler(allocator, io, test_timers.timers(), log, .{ .object = object }, testContext.context.taskContext());
}

test "streams an asset from the database to the destination file" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-asset-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const outputDir = try temp_dirs.makeTempDir(allocator, io, "save-asset-worker-output");
    defer temp_dirs.removeTempDir(io, outputDir);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "the original bytes");
    const destPath = try std.fs.path.join(allocator, &.{ outputDir, "saved.jpg" });

    const output = try run(allocator, io, log, &testContext, "asset-1", "asset", destPath, fixture.dir);

    try std.testing.expect(output == .null);
    try std.testing.expectEqualStrings("the original bytes", try std.Io.Dir.cwd().readFileAlloc(io, destPath, allocator, .unlimited));
}

test "fetches the asset type that was asked for" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-asset-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const outputDir = try temp_dirs.makeTempDir(allocator, io, "save-asset-worker-output");
    defer temp_dirs.removeTempDir(io, outputDir);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "the original");
    try fixture.database.assetStorage.write(allocator, io, "display/asset-1", null, "the display copy");
    try fixture.database.assetStorage.write(allocator, io, "thumb/asset-1", null, "the thumbnail");
    const displayPath = try std.fs.path.join(allocator, &.{ outputDir, "display.jpg" });
    const thumbPath = try std.fs.path.join(allocator, &.{ outputDir, "thumb.jpg" });

    _ = try run(allocator, io, log, &testContext, "asset-1", "display", displayPath, fixture.dir);
    _ = try run(allocator, io, log, &testContext, "asset-1", "thumb", thumbPath, fixture.dir);

    try std.testing.expectEqualStrings("the display copy", try std.Io.Dir.cwd().readFileAlloc(io, displayPath, allocator, .unlimited));
    try std.testing.expectEqualStrings("the thumbnail", try std.Io.Dir.cwd().readFileAlloc(io, thumbPath, allocator, .unlimited));
}

test "replaces a file that is already at the destination" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-asset-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const outputDir = try temp_dirs.makeTempDir(allocator, io, "save-asset-worker-output");
    defer temp_dirs.removeTempDir(io, outputDir);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "new");
    const destPath = try std.fs.path.join(allocator, &.{ outputDir, "saved.jpg" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = destPath,
        .data = "a much longer file that was there before",
    });

    _ = try run(allocator, io, log, &testContext, "asset-1", "asset", destPath, fixture.dir);

    try std.testing.expectEqualStrings("new", try std.Io.Dir.cwd().readFileAlloc(io, destPath, allocator, .unlimited));
}

test "fails when the asset is not in the database" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-asset-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const outputDir = try temp_dirs.makeTempDir(allocator, io, "save-asset-worker-output");
    defer temp_dirs.removeTempDir(io, outputDir);
    const destPath = try std.fs.path.join(allocator, &.{ outputDir, "saved.jpg" });

    const result = run(allocator, io, log, &testContext, "no-such-asset", "asset", destPath, fixture.dir);

    try std.testing.expect(std.meta.isError(result));
    // A file is made only for an asset that was found.
    try std.testing.expect(!test_files.fileExists(io, destPath));
}

test "fails when the destination folder does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-asset-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const outputDir = try temp_dirs.makeTempDir(allocator, io, "save-asset-worker-output");
    defer temp_dirs.removeTempDir(io, outputDir);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "bytes");
    const destPath = try std.fs.path.join(allocator, &.{ outputDir, "missing-folder", "saved.jpg" });

    const result = run(allocator, io, log, &testContext, "asset-1", "asset", destPath, fixture.dir);

    try std.testing.expect(std.meta.isError(result));
}

test "throws a descriptive error when the task data is not valid" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-asset-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "assetId", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, saveAssetHandler(allocator, io, test_timers.timers(), log, .{ .object = object }, testContext.context.taskContext()));
    try std.testing.expectEqualStrings("The save-asset task data is not valid: assetId, assetType, destPath and databasePath must be strings", errors.lastErrorMessage());
}

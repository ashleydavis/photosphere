const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const database_fixture = @import("database-fixture.zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_task_context = @import("test-task-context.zig");
const saveAssetsBatchHandler = node_api.save_assets_batch_worker.saveAssetsBatchHandler;
const ISaveAssetsBatchResult = node_api.save_assets_batch_worker.ISaveAssetsBatchResult;
const ISaveAssetItem = api.save_assets_types.ISaveAssetItem;
const DatabaseFixture = database_fixture.DatabaseFixture;
const TestTaskContext = test_task_context.TestTaskContext;
const errors = utils.errors;

//
// These tests give the handler a real database holding assets and a
// real destination folder, and check what it wrote and what it reported.
//

//
// Runs the handler for a list of assets and reads its result.
//
fn run(allocator: std.mem.Allocator, io: std.Io, log: utils.log.ILog, testContext: *TestTaskContext, assets: []const ISaveAssetItem, folderPath: []const u8, databasePath: []const u8) !ISaveAssetsBatchResult {
    var items: std.json.Array = .init(allocator);
    for (assets) |asset| {
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "assetId", .{ .string = asset.assetId });
        try item.put(allocator, "assetType", .{ .string = asset.assetType });
        try item.put(allocator, "filename", .{ .string = asset.filename });
        try items.append(.{ .object = item });
    }
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "assets", .{ .array = items });
    try object.put(allocator, "folderPath", .{ .string = folderPath });
    try object.put(allocator, "databasePath", .{ .string = databasePath });
    const output = try saveAssetsBatchHandler(allocator, io, test_timers.timers(), log, .{ .object = object }, testContext.context.taskContext());
    return std.json.parseFromValueLeaky(ISaveAssetsBatchResult, allocator, output, .{});
}

test "saves every asset into the folder under its filename" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-assets-batch-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const folderPath = try temp_dirs.makeTempDir(allocator, io, "save-assets-batch-worker-output");
    defer temp_dirs.removeTempDir(io, folderPath);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "first original");
    try fixture.database.assetStorage.write(allocator, io, "display/asset-2", null, "second display copy");

    const result = try run(allocator, io, log, &testContext, &.{
        .{
            .assetId = "asset-1",
            .assetType = "asset",
            .filename = "one.jpg",
        },
        .{
            .assetId = "asset-2",
            .assetType = "display",
            .filename = "two.jpg",
        },
    }, folderPath, fixture.dir);

    try std.testing.expectEqualStrings(folderPath, result.folderPath);
    try std.testing.expectEqual(@as(usize, 2), result.succeededFiles.len);
    try std.testing.expectEqualStrings("one.jpg", result.succeededFiles[0]);
    try std.testing.expectEqualStrings("two.jpg", result.succeededFiles[1]);
    try std.testing.expectEqual(@as(usize, 0), result.failedFiles.len);
    try std.testing.expectEqualStrings("first original", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ folderPath, "one.jpg" }), allocator, .unlimited));
    try std.testing.expectEqualStrings("second display copy", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ folderPath, "two.jpg" }), allocator, .unlimited));
}

test "records an asset that is not in the database as a failure and carries on with the rest" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-assets-batch-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const folderPath = try temp_dirs.makeTempDir(allocator, io, "save-assets-batch-worker-output");
    defer temp_dirs.removeTempDir(io, folderPath);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "first original");
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-3", null, "third original");

    const result = try run(allocator, io, log, &testContext, &.{
        .{
            .assetId = "asset-1",
            .assetType = "asset",
            .filename = "one.jpg",
        },
        .{
            .assetId = "no-such-asset",
            .assetType = "asset",
            .filename = "missing.jpg",
        },
        .{
            .assetId = "asset-3",
            .assetType = "asset",
            .filename = "three.jpg",
        },
    }, folderPath, fixture.dir);

    try std.testing.expectEqual(@as(usize, 2), result.succeededFiles.len);
    try std.testing.expectEqualStrings("one.jpg", result.succeededFiles[0]);
    try std.testing.expectEqualStrings("three.jpg", result.succeededFiles[1]);
    try std.testing.expectEqual(@as(usize, 1), result.failedFiles.len);
    try std.testing.expectEqualStrings("missing.jpg", result.failedFiles[0].filename);
    // A file is made only for an asset that was found.
    try std.testing.expect(!test_files.fileExists(io, try std.fs.path.join(allocator, &.{ folderPath, "missing.jpg" })));
    try std.testing.expect(result.failedFiles[0].@"error".len > 0);
    try std.testing.expectEqualStrings("third original", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ folderPath, "three.jpg" }), allocator, .unlimited));
}

test "records every asset as a failure when the folder does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-assets-batch-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const outputDir = try temp_dirs.makeTempDir(allocator, io, "save-assets-batch-worker-output");
    defer temp_dirs.removeTempDir(io, outputDir);
    try fixture.database.assetStorage.write(allocator, io, "asset/asset-1", null, "first original");
    const folderPath = try std.fs.path.join(allocator, &.{ outputDir, "missing-folder" });

    const result = try run(allocator, io, log, &testContext, &.{
        .{
            .assetId = "asset-1",
            .assetType = "asset",
            .filename = "one.jpg",
        },
    }, folderPath, fixture.dir);

    try std.testing.expectEqual(@as(usize, 0), result.succeededFiles.len);
    try std.testing.expectEqual(@as(usize, 1), result.failedFiles.len);
    try std.testing.expectEqualStrings("one.jpg", result.failedFiles[0].filename);
}

test "saves nothing and reports nothing for an empty list" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-assets-batch-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    const folderPath = try temp_dirs.makeTempDir(allocator, io, "save-assets-batch-worker-output");
    defer temp_dirs.removeTempDir(io, folderPath);

    const result = try run(allocator, io, log, &testContext, &.{}, folderPath, fixture.dir);

    try std.testing.expectEqualStrings(folderPath, result.folderPath);
    try std.testing.expectEqual(@as(usize, 0), result.succeededFiles.len);
    try std.testing.expectEqual(@as(usize, 0), result.failedFiles.len);
}

test "throws a descriptive error when the task data is not valid" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "save-assets-batch-worker");
    defer fixture.deinit(io, log);
    var testContext: TestTaskContext = undefined;
    testContext.init(fixture.uuidGenerator.uuidGenerator());
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "assets", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, saveAssetsBatchHandler(allocator, io, test_timers.timers(), log, .{ .object = object }, testContext.context.taskContext()));
    try std.testing.expectEqualStrings("The save-assets-batch task data is not valid: assets must be a list of items with assetId, assetType and filename, and folderPath and databasePath must be strings", errors.lastErrorMessage());
}

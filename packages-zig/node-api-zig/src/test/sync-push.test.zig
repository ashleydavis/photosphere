//
// Tests for what a push refuses, deletes and leaves out: databases that are not related, assets the
// source has deleted, and files a partial target does not keep.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const media_file_database = node_api.media_file_database;
const merkle_tree = merkle_tree_zig.merkle_tree;
const pushFiles = node_api.sync.pushFiles;
const throughTheDatabases = node_api.sync.throughTheDatabases;
const errors = utils.errors;

//
// The id of the test databases.
//
const dbId = "6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";

//
// The asset the tests delete or copy.
//
const ASSET_ID = "0a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";

//
// Pushes everything the source holds into the target.
//
fn push(allocator: std.mem.Allocator, io: std.Io, log: ILog, source: *MemoryStorage, target: *MemoryStorage) !void {
    try pushFiles(allocator, io, log, source.asStorage(), target.asStorage(), try sync_helpers.makeBsonDatabase(allocator, target.asStorage()), throughTheDatabases(source.asStorage(), target.asStorage()));
}

//
// Loads the files tree of a storage.
//
fn loadFilesTree(allocator: std.mem.Allocator, io: std.Io, log: ILog, storage: *MemoryStorage) !merkle_tree.IMerkleTree {
    return (try merkle_tree.loadTree(allocator, io, log, ".db/files.dat", storage.asStorage(), "FTRE")).?;
}

test "refuses to push between databases that are not related" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, log, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, &.{"asset/a.jpg"}), &.{});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, log, target.asStorage(), "ffffffff-4e5f-4a6b-8c9d-0e1f2a3b4c5d", try sync_helpers.filesNamed(allocator, &.{"asset/b.jpg"}), &.{});

    try std.testing.expectError(error.FatalError, push(allocator, io, log, &source, &target));

    try std.testing.expectEqualStrings("You are trying to sync databases that have different IDs.\n" ++
        "Source database ID: " ++ dbId ++ "\n" ++
        "Target database ID: ffffffff-4e5f-4a6b-8c9d-0e1f2a3b4c5d\n" ++
        "The databases are not related to each other.", errors.lastErrorMessage());
    try std.testing.expect(!try target.asStorage().fileExists(allocator, io, "asset/a.jpg"));
}

test "deletes from the target an asset the source has deleted, and counts one fewer import" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const assetPath = "asset/" ++ ASSET_ID;
    const thumbPath = "thumb/" ++ ASSET_ID;
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, log, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, &.{"asset/kept.jpg"}), &.{ASSET_ID});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, log, target.asStorage(), dbId, try sync_helpers.filesNamed(allocator, &.{ "asset/kept.jpg", assetPath, thumbPath }), &.{});

    try push(allocator, io, log, &source, &target);

    try std.testing.expect(!try target.asStorage().fileExists(allocator, io, assetPath));
    try std.testing.expect(!try target.asStorage().fileExists(allocator, io, thumbPath));
    const targetTree = try loadFilesTree(allocator, io, log, &target);
    try std.testing.expect((try merkle_tree.getItemInfo(&targetTree, assetPath)) == null);
    // The target was filled with three files, so it counted three imports.
    try std.testing.expectEqual(@as(u64, 2), media_file_database.getFilesImported(targetTree.databaseMetadata));
    const deletedAssetIds = targetTree.databaseMetadata.?.get("deletedAssetIds").?.array;
    try std.testing.expectEqual(@as(usize, 1), deletedAssetIds.len);
    try std.testing.expectEqualStrings(ASSET_ID, deletedAssetIds[0].string);
}

test "copies only the thumbnails and root files into a partial target" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const assetPath = "asset/" ++ ASSET_ID;
    const thumbPath = "thumb/" ++ ASSET_ID;
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, log, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, &.{ "README.md", assetPath, thumbPath }), &.{});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, log, target.asStorage(), dbId, &.{}, &.{});
    var partialTree = try loadFilesTree(allocator, io, log, &target);
    try partialTree.databaseMetadata.?.put(allocator, "isPartial", .{ .boolean = true });
    try merkle_tree.saveTree(allocator, io, log, ".db/files.dat", &partialTree, target.asStorage(), "FTRE");

    try push(allocator, io, log, &source, &target);

    try std.testing.expect(try target.asStorage().fileExists(allocator, io, thumbPath));
    try std.testing.expect(try target.asStorage().fileExists(allocator, io, "README.md"));
    try std.testing.expect(!try target.asStorage().fileExists(allocator, io, assetPath));
}

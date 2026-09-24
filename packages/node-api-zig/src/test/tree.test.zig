const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const tree = node_api.tree;
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;

test "merkleTreeExists is false for an empty directory and true for a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "tree-empty");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expect(!try tree.merkleTreeExists(allocator, io, try helpers.directoryStorage(allocator, io, emptyDir)));

    const databaseDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.testing.expect(try tree.merkleTreeExists(allocator, io, try helpers.directoryStorage(allocator, io, databaseDir)));
}

test "loadMerkleTree loads the files tree of a v6 database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storage = try helpers.directoryStorage(allocator, io, helpers.TEST_DBS_DIR ++ "/v6");
    const loaded = (try tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(u32, 4), loaded.sort.?.leafCount);
    try std.testing.expect(loaded.merkle != null);
    try std.testing.expectEqual(@as(u64, 1), node_api.media_file_database.getFilesImported(loaded.databaseMetadata));
}

test "loadMerkleTree returns null when there is no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "tree-none");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expect(try tree.loadMerkleTree(allocator, io, try helpers.directoryStorage(allocator, io, emptyDir)) == null);
}

test "saveMerkleTree throws when no tree is provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "tree-null");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expectError(error.Thrown, tree.saveMerkleTree(allocator, io, null, try helpers.directoryStorage(allocator, io, emptyDir)));
    try std.testing.expectEqualStrings("Cannot save database. No merkle tree provided.", errors.lastErrorMessage());
}

test "saveMerkleTree rebuilds a dirty tree and saves it to .db/files.dat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "tree-save");
    defer helpers.removeTempDir(io, dir);
    const storage = try helpers.directoryStorage(allocator, io, dir);

    var merkleTree = merkle_tree.createTree("12345678-1234-5678-9abc-123456789abc");
    merkleTree = try merkle_tree.addItem(allocator, &merkleTree, .{ .name = "asset/a", .hash = &([_]u8{1} ** 32), .length = 5, .lastModified = 1000 });
    try std.testing.expect(merkleTree.dirty);
    try tree.saveMerkleTree(allocator, io, &merkleTree, storage);
    try std.testing.expect(!merkleTree.dirty);
    try std.testing.expect(merkleTree.merkle != null);

    const loaded = (try tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqualStrings("12345678-1234-5678-9abc-123456789abc", loaded.id);
    try std.testing.expectEqualSlices(u8, merkleTree.merkle.?.hash, loaded.merkle.?.hash);
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/files.dat", .{dir})));
}

test "loadCollectionMerkleTree and loadShardMerkleTree load the BSON trees of a v6 database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storage = try helpers.directoryStorage(allocator, io, helpers.TEST_DBS_DIR ++ "/v6");
    const collectionTree = (try tree.loadCollectionMerkleTree(allocator, io, storage, "metadata")).?;
    var shardNames = merkle_tree.iterateLeaves(merkle_tree.MerkleNode, allocator, collectionTree.merkle);
    const shardLeaf = (try shardNames.next()).?;
    try std.testing.expectEqualStrings("96", shardLeaf.name.?);

    const shardTree = (try tree.loadShardMerkleTree(allocator, io, storage, "metadata", "96")).?;
    var recordNames = merkle_tree.iterateLeaves(merkle_tree.MerkleNode, allocator, shardTree.merkle);
    const recordLeaf = (try recordNames.next()).?;
    try std.testing.expectEqualStrings("89171cd9-a652-4047-b869-1154bf2c95a1", recordLeaf.name.?);

    try std.testing.expect(try tree.loadShardMerkleTree(allocator, io, storage, "metadata", "1") == null);
    try std.testing.expect(try tree.loadCollectionMerkleTree(allocator, io, storage, "missing") == null);
}

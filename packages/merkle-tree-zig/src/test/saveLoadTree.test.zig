//
// Tests for saveTree, loadTree and loadTreeVersion (port of src/test/saveLoadTree.test.ts).
// (Zig: the TypeScript tests use FileStorage on temporary files; these use the in-memory storage.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const memory_storage = @import("memory-storage.zig");
const errors = @import("utils-zig").errors;
const bson = @import("serialization-zig").bson;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const MemoryStorage = memory_storage.MemoryStorage;

//
// The Io used by the tests.
//
const io = std.testing.io;

//
// The file the tests save to.
//
const TEST_FILE_PATH = "test-tree-v2.bin";

//
// Helper function to build a tree with the given file names
//
fn buildTree(allocator: std.mem.Allocator, fileNames: []const []const u8) !IMerkleTree {
    var merkleTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    for (fileNames) |fileName| {
        merkleTree = try merkle_tree.addItem(allocator, &merkleTree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
    }
    merkleTree.dirty = false;
    merkleTree.merkle = try merkle_tree.buildMerkleTree(allocator, merkleTree.sort);
    return merkleTree;
}

//
// Helper function to compare two binary trees
//
fn compareTrees(original: ?*const SortNode, loaded: ?*const SortNode) !void {
    if (original == null and loaded == null) {
        return;
    }
    if (original == null or loaded == null) {
        return error.TreeStructureMismatch;
    }
    try std.testing.expectEqual(original.?.nodeCount, loaded.?.nodeCount);
    try std.testing.expectEqual(original.?.leafCount, loaded.?.leafCount);
    try std.testing.expectEqual(original.?.size, loaded.?.size);
    try std.testing.expectEqualStrings(original.?.minName, loaded.?.minName);
    try std.testing.expectEqual(original.?.lastModified, loaded.?.lastModified);
    try compareTrees(original.?.left, loaded.?.left);
    try compareTrees(original.?.right, loaded.?.right);
}

//
// Saves a tree and loads it back.
//
fn saveAndLoad(allocator: std.mem.Allocator, tree: *const IMerkleTree) !IMerkleTree {
    var storage = MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, tree, storage.asStorage(), "FTRE");
    return (try merkle_tree.loadTree(allocator, io, TEST_FILE_PATH, storage.asStorage(), "FTRE")).?;
}

test "should save and load a small tree correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const originalTree = try buildTree(allocator, &.{ "A", "B" });
    const loadedTree = try saveAndLoad(allocator, &originalTree);

    try std.testing.expectEqual(originalTree.sort.?.leafCount, loadedTree.sort.?.leafCount);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try std.testing.expectEqual(@as(u32, 2), loadedTree.sort.?.leafCount);

    var leaves = merkle_tree.iterateLeaves(SortNode, allocator, loadedTree.sort);
    const leafA = (try leaves.next()).?;
    const leafB = (try leaves.next()).?;
    try std.testing.expectEqualStrings("A", leafA.name.?);
    try std.testing.expectEqualStrings("B", leafB.name.?);
    try std.testing.expectEqual(@as(usize, 32), leafA.contentHash.?.len);
    try std.testing.expectEqual(@as(usize, 32), leafB.contentHash.?.len);

    try compareTrees(originalTree.sort, loadedTree.sort);
}

test "should save and load a complex tree correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fileNames = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G" };
    const originalTree = try buildTree(allocator, &fileNames);
    const loadedTree = try saveAndLoad(allocator, &originalTree);

    try std.testing.expectEqual(@as(u32, fileNames.len), loadedTree.sort.?.leafCount);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try compareTrees(originalTree.sort, loadedTree.sort);

    // Verify hash integrity - the root hash should match
    try std.testing.expectEqualSlices(u8, originalTree.merkle.?.hash, loadedTree.merkle.?.hash);
    try std.testing.expectEqual(originalTree.merkle.?.nodeCount, loadedTree.merkle.?.nodeCount);
}

test "should handle trees with special characters in file names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const specialChars = "file-with-special-chars-!@#$%^&*()_+.txt";
    const tree = try buildTree(allocator, &.{specialChars});
    const loadedTree = try saveAndLoad(allocator, &tree);

    try std.testing.expectEqual(tree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try std.testing.expectEqualStrings(specialChars, loadedTree.sort.?.name.?);
    try std.testing.expectEqualSlices(u8, tree.sort.?.contentHash.?, loadedTree.sort.?.contentHash.?);
}

test "should handle large trees efficiently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fileNames: [100][]const u8 = undefined;
    for (&fileNames, 0..) |*fileName, index| {
        fileName.* = try std.fmt.allocPrint(allocator, "file-{d}.txt", .{index});
    }
    const originalTree = try buildTree(allocator, &fileNames);
    const loadedTree = try saveAndLoad(allocator, &originalTree);

    try std.testing.expectEqual(@as(u32, 100), loadedTree.sort.?.leafCount);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try compareTrees(originalTree.sort, loadedTree.sort);
}

test "saveTree throws for a dirty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{"A"});
    tree.dirty = true;
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &tree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("Tree is dirty. Cannot save. Make sure to rebuild the tree before saving.", errors.lastErrorMessage());
}

test "saveTree throws for an id that is not a UUID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = merkle_tree.createTree("test-tree");
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &tree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("Invalid UUID", errors.lastErrorMessage());
}

test "saveTree throws like Buffer.writeUInt32LE for a last modified date before 1970" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{"A"});
    tree.sort.?.lastModified = -315619200000; // 1960-01-01T00:00:00.000Z
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &tree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and <= 4294967295. Received -74", errors.lastErrorMessage());
}

test "saves and loads an empty tree and its database metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var metadata: bson.BsonDocument = .empty;
    try metadata.put(allocator, "filesImported", .{ .number = 3 });
    tree.databaseMetadata = metadata;

    const loadedTree = try saveAndLoad(allocator, &tree);
    try std.testing.expect(loadedTree.sort == null);
    try std.testing.expect(loadedTree.merkle == null);
    try std.testing.expectEqual(@as(u32, 6), loadedTree.version);
    try std.testing.expect(!loadedTree.dirty);
    try std.testing.expect(loadedTree.databaseMetadata.?.eql(metadata));
}

test "loadTree returns undefined for a missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect((try merkle_tree.loadTree(allocator, io, "missing.dat", storage.asStorage(), "FTRE")) == null);
}

test "should load version from a valid tree file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const originalTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var storage = MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, io, "test-tree-version.bin", &originalTree, storage.asStorage(), "FTRE");
    try std.testing.expectEqual(@as(?u32, merkle_tree.CURRENT_DATABASE_VERSION), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should return undefined for non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectEqual(@as(?u32, null), merkle_tree.loadTreeVersion(allocator, io, "non-existent-file.bin", storage.asStorage()));
}

test "should return undefined for empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.putFile("test-tree-version.bin", "");
    try std.testing.expectEqual(@as(?u32, null), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should return undefined for file with less than 4 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.putFile("test-tree-version.bin", &.{ 0x01, 0x02 });
    try std.testing.expectEqual(@as(?u32, null), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should correctly read version from file with exactly 4 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var versionBuffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &versionBuffer, 42, .little);
    try storage.putFile("test-tree-version.bin", &versionBuffer);
    try std.testing.expectEqual(@as(?u32, 42), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should read version from large file without loading entire file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const completeFile = try allocator.alloc(u8, 4 + 1024 * 1024);
    @memset(completeFile, 0xFF);
    std.mem.writeInt(u32, completeFile[0..4], 123, .little);
    try storage.putFile("test-tree-version.bin", completeFile);
    try std.testing.expectEqual(@as(?u32, 123), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should handle different version values correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const testVersions = [_]u32{ 0, 1, 2, 3, 255, 65535, 4294967295 }; // Test edge cases
    for (testVersions) |expectedVersion| {
        var versionBuffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &versionBuffer, expectedVersion, .little);
        try storage.putFile("test-tree-version.bin", &versionBuffer);
        try std.testing.expectEqual(@as(?u32, expectedVersion), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
    }
}

test "should work correctly with large tree files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var originalTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var index: usize = 0;
    while (index < 100) {
        const fileName = try std.fmt.allocPrint(allocator, "file-{d:0>3}.txt", .{index});
        originalTree = try merkle_tree.addItem(allocator, &originalTree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
        index += 1;
    }
    originalTree.dirty = false;
    originalTree.merkle = try merkle_tree.buildMerkleTree(allocator, originalTree.sort);

    var storage = MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, io, "test-tree-version.bin", &originalTree, storage.asStorage(), "FTRE");

    const version = merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage());
    const fullTree = (try merkle_tree.loadTree(allocator, io, "test-tree-version.bin", storage.asStorage(), "FTRE")).?;

    try std.testing.expectEqual(@as(?u32, merkle_tree.CURRENT_DATABASE_VERSION), version);
    try std.testing.expectEqual(merkle_tree.CURRENT_DATABASE_VERSION, fullTree.version);
    try std.testing.expectEqual(@as(u32, 100), fullTree.sort.?.leafCount);
}

//
// Tests for deleteItem and deleteItems (port of src/test/deleteFile.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const errors = @import("utils-zig").errors;
const memory_storage = @import("memory-storage.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;

//
// Helper function to build a small test tree
//
fn buildTestTree(allocator: std.mem.Allocator) !IMerkleTree {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const fileNames = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" };
    for (fileNames) |fileName| {
        tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
    }
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.
    return tree;
}

//
// The leaf count of a tree (0 when empty; TypeScript: `tree.sort?.leafCount || 0`).
//
fn leafCount(tree: *const IMerkleTree) u32 {
    return if (tree.sort) |sort| sort.leafCount else 0;
}

//
// The node count of a tree (0 when empty).
//
fn nodeCount(tree: *const IMerkleTree) u32 {
    return if (tree.sort) |sort| sort.nodeCount else 0;
}

test "should completely remove a file from the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a test tree
    var tree = try buildTestTree(allocator);
    const initialNumFiles = leafCount(&tree);
    const initialNodeCount = nodeCount(&tree);

    // Verify the file exists before deletion
    const fileToDelete = "file3.txt";
    const nodeBeforeDeletion = merkle_tree.findItemInTree(tree.sort, fileToDelete);
    try std.testing.expectEqualStrings(fileToDelete, nodeBeforeDeletion.?.name.?);

    // Delete the file completely
    try merkle_tree.deleteItem(allocator, &tree, fileToDelete);

    // Verify the file is completely gone
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, fileToDelete)) == null);

    // Verify the tree structure has changed (fewer nodes and files)
    try std.testing.expectEqual(initialNumFiles - 1, leafCount(&tree));
    try std.testing.expect(nodeCount(&tree) < initialNodeCount);

    // Verify remaining files are still present
    for ([_][]const u8{ "file1.txt", "file2.txt", "file4.txt", "file5.txt" }) |name| {
        try std.testing.expect((merkle_tree.findItemInTree(tree.sort, name)) != null);
    }
}

test "should handle deleting a non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const initialLeafCount = leafCount(&tree);
    const initialNodeCount = nodeCount(&tree);

    // Attempt to delete a non-existent file
    try merkle_tree.deleteItem(allocator, &tree, "non-existent-file.txt");

    // Verify the tree structure is unchanged
    try std.testing.expectEqual(initialLeafCount, leafCount(&tree));
    try std.testing.expectEqual(initialNodeCount, nodeCount(&tree));
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "non-existent-file.txt")) == null);
}

test "should persist deletion when saving and loading the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a test tree and delete a file
    var tree = try buildTestTree(allocator);
    const fileToDelete = "file2.txt";
    try merkle_tree.deleteItem(allocator, &tree, fileToDelete);
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);

    // Save the tree (in memory instead of a temporary file)
    var storage = memory_storage.MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, std.testing.io, "merkle-tree-delete-test.bin", &tree, storage.asStorage(), "FTRE");

    // Load the tree back
    const loadedTree = (try merkle_tree.loadTree(allocator, std.testing.io, "merkle-tree-delete-test.bin", storage.asStorage(), "FTRE")).?;

    // Verify the file is completely gone
    try std.testing.expect((merkle_tree.findItemInTree(loadedTree.sort, fileToDelete)) == null);
}

test "should allow multiple files to be deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const initialFiles = leafCount(&tree);

    // Delete multiple files
    try merkle_tree.deleteItem(allocator, &tree, "file1.txt");
    try merkle_tree.deleteItem(allocator, &tree, "file3.txt");
    try merkle_tree.deleteItem(allocator, &tree, "file5.txt");

    // Check that all files are completely gone
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file1.txt")) == null);
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file2.txt")) != null);
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file3.txt")) == null);
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file4.txt")) != null);
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file5.txt")) == null);

    // Verify metadata is correct
    try std.testing.expectEqual(initialFiles - 3, leafCount(&tree));
}

test "should update Merkle tree hashes when a file is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);

    // Save original root hash
    const originalRootHash = tree.merkle.?.hash;

    // Delete a file
    try merkle_tree.deleteItem(allocator, &tree, "file3.txt");
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    // The root hash should have changed
    try std.testing.expect(!std.mem.eql(u8, originalRootHash, tree.merkle.?.hash));
}

test "should handle deleting the only file in a tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a tree with just one file
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "single-file.txt", "single-file.txt", 15));
    try std.testing.expectEqual(@as(u32, 1), leafCount(&tree));
    try std.testing.expectEqual(@as(u32, 1), nodeCount(&tree));

    // Delete the only file
    try merkle_tree.deleteItem(allocator, &tree, "single-file.txt");

    // Tree should be empty
    try std.testing.expectEqual(@as(u32, 0), leafCount(&tree));
    try std.testing.expectEqual(@as(u32, 0), nodeCount(&tree));
}

test "should handle deleting from empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emptyTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);

    // Attempt to delete from empty tree
    try merkle_tree.deleteItem(allocator, &emptyTree, "any-file.txt");

    // Tree should remain empty
    try std.testing.expectEqual(@as(u32, 0), leafCount(&emptyTree));
    try std.testing.expectEqual(@as(u32, 0), nodeCount(&emptyTree));
    try std.testing.expect(emptyTree.dirty);
}

//
// Returns true when the tree has an item with the name (TypeScript: `findItemNode(tree, name)` is defined).
//
fn hasItem(tree: *const IMerkleTree, name: []const u8) bool {
    return merkle_tree.findItemInTree(tree.sort, name) != null;
}

//
// The size of a tree (0 when empty; TypeScript: `tree.sort?.size || 0`).
//
fn treeSize(tree: *const IMerkleTree) u64 {
    return if (tree.sort) |sort| sort.size else 0;
}

//
// Expects the call to throw with exactly the message.
//
fn expectThrown(expectedMessage: []const u8, result: anytype) !void {
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
}

test "Hard File Deletion (deleteItems): should completely remove a file from the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a test tree
    var tree = try buildTestTree(allocator);
    const initialNumFiles = leafCount(&tree);
    const initialNodeCount = nodeCount(&tree);

    // Verify the file exists before deletion
    const fileToDelete = "file3.txt";
    const nodeBeforeDeletion = merkle_tree.findItemInTree(tree.sort, fileToDelete);
    try std.testing.expectEqualStrings(fileToDelete, nodeBeforeDeletion.?.name.?);

    // Delete the file completely
    const result = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{fileToDelete});
    try std.testing.expectEqual(@as(usize, 1), result);

    // Verify the file is completely gone
    try std.testing.expect(!hasItem(&tree, fileToDelete));

    // Verify the tree structure has changed (fewer nodes and files)
    try std.testing.expectEqual(initialNumFiles - 1, leafCount(&tree));
    try std.testing.expect(nodeCount(&tree) < initialNodeCount);

    // Verify remaining files are still present
    for ([_][]const u8{ "file1.txt", "file2.txt", "file4.txt", "file5.txt" }) |name| {
        try std.testing.expect(hasItem(&tree, name));
    }
}

test "Hard File Deletion (deleteItems): should throw when trying to delete a non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);

    try expectThrown(
        "Cannot delete items: the following items do not exist: non-existent-file.txt",
        merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{"non-existent-file.txt"}),
    );
}

test "Hard File Deletion (deleteItems): should handle deleting the only file in a tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a tree with just one file
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "single-file.txt", "single-file.txt", 15));
    try std.testing.expectEqual(@as(u32, 1), leafCount(&tree));
    try std.testing.expectEqual(@as(u32, 1), nodeCount(&tree));

    // Delete the only file
    const result = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{"single-file.txt"});
    try std.testing.expectEqual(@as(usize, 1), result);

    // Tree should be empty
    try std.testing.expectEqual(@as(u32, 0), leafCount(&tree));
    try std.testing.expectEqual(@as(u32, 0), nodeCount(&tree));
}

test "Hard File Deletion (deleteItems): should persist hard deletion when saving and loading the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a test tree and delete a file
    var tree = try buildTestTree(allocator);
    const fileToDelete = "file2.txt";
    _ = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{fileToDelete});

    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);

    // Save the tree (in memory instead of a temporary file)
    var storage = memory_storage.MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, std.testing.io, "merkle-tree-hard-delete-test.bin", &tree, storage.asStorage(), "FTRE");

    // Load the tree back
    const loadedTree = (try merkle_tree.loadTree(allocator, std.testing.io, "merkle-tree-hard-delete-test.bin", storage.asStorage(), "FTRE")).?;

    // Verify the file is completely gone
    try std.testing.expect(!hasItem(&loadedTree, fileToDelete));
}

test "Hard File Deletion (deleteItems): should allow multiple files to be deleted completely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const initialFiles = leafCount(&tree);

    // Delete multiple files
    const result = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{ "file1.txt", "file3.txt", "file5.txt" });
    try std.testing.expectEqual(@as(usize, 3), result);

    // Check that all files are completely gone
    try std.testing.expect(!hasItem(&tree, "file1.txt"));
    try std.testing.expect(hasItem(&tree, "file2.txt"));
    try std.testing.expect(!hasItem(&tree, "file3.txt"));
    try std.testing.expect(hasItem(&tree, "file4.txt"));
    try std.testing.expect(!hasItem(&tree, "file5.txt"));

    // Verify metadata is correct
    try std.testing.expectEqual(initialFiles - 3, leafCount(&tree));
}

test "Hard File Deletion (deleteItems): should update Merkle tree hashes when a file is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);

    // Save original root hash
    const originalRootHash = tree.merkle.?.hash;

    // Delete a file
    _ = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{"file3.txt"});
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    // The root hash should have changed
    try std.testing.expect(!std.mem.eql(u8, originalRootHash, tree.merkle.?.hash));
}

test "Hard File Deletion (deleteItems): should handle deleting all files from a tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const allFiles = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" };

    // Delete all files
    const result = try merkle_tree.deleteItems(allocator, &tree, &allFiles);
    try std.testing.expectEqual(allFiles.len, result);

    // Tree should be empty
    try std.testing.expectEqual(@as(u32, 0), leafCount(&tree));
    try std.testing.expectEqual(@as(u32, 0), nodeCount(&tree));
}

test "Hard File Deletion (deleteItems): should preserve metadata id and update counts correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const originalId = tree.id;
    const originalLeafCount = leafCount(&tree);
    const originalNodeCount = nodeCount(&tree);
    const originalSize = treeSize(&tree);

    // Delete a file
    _ = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{"file3.txt"});

    // Check that metadata is preserved but counts are updated
    try std.testing.expectEqualStrings(originalId, tree.id);
    try std.testing.expectEqual(originalLeafCount - 1, leafCount(&tree));
    try std.testing.expect(nodeCount(&tree) < originalNodeCount);
    try std.testing.expect(treeSize(&tree) < originalSize);
}

test "Hard File Deletion (deleteItems): should throw when trying to delete from empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emptyTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);

    try expectThrown(
        "Cannot delete items from empty or invalid merkle tree",
        merkle_tree.deleteItems(allocator, &emptyTree, &[_][]const u8{"any-file.txt"}),
    );
}

test "Hard File Deletion (deleteItems): should throw when trying to delete 0 files (empty array)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);

    try expectThrown(
        "Cannot delete items: no names provided",
        merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{}),
    );
}

test "Hard File Deletion (deleteItems): should handle deleting 1 file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const initialFiles = leafCount(&tree);

    const result = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{"file2.txt"});
    try std.testing.expectEqual(@as(usize, 1), result);

    // Tree should have one less file
    try std.testing.expectEqual(initialFiles - 1, leafCount(&tree));
    try std.testing.expect(!hasItem(&tree, "file2.txt"));
    try std.testing.expect(hasItem(&tree, "file1.txt"));
    try std.testing.expect(hasItem(&tree, "file3.txt"));
}

test "Hard File Deletion (deleteItems): should handle deleting 2 files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const initialFiles = leafCount(&tree);

    const result = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{ "file1.txt", "file4.txt" });
    try std.testing.expectEqual(@as(usize, 2), result);

    // Tree should have two less files
    try std.testing.expectEqual(initialFiles - 2, leafCount(&tree));
    try std.testing.expect(!hasItem(&tree, "file1.txt"));
    try std.testing.expect(!hasItem(&tree, "file4.txt"));
    try std.testing.expect(hasItem(&tree, "file2.txt"));
    try std.testing.expect(hasItem(&tree, "file3.txt"));
    try std.testing.expect(hasItem(&tree, "file5.txt"));
}

test "Hard File Deletion (deleteItems): should handle deleting 3 files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    const initialFiles = leafCount(&tree);

    const result = try merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{ "file2.txt", "file3.txt", "file5.txt" });
    try std.testing.expectEqual(@as(usize, 3), result);

    // Tree should have three less files
    try std.testing.expectEqual(initialFiles - 3, leafCount(&tree));
    try std.testing.expect(!hasItem(&tree, "file2.txt"));
    try std.testing.expect(!hasItem(&tree, "file3.txt"));
    try std.testing.expect(!hasItem(&tree, "file5.txt"));
    try std.testing.expect(hasItem(&tree, "file1.txt"));
    try std.testing.expect(hasItem(&tree, "file4.txt"));
}

test "Hard File Deletion (deleteItems): should throw when trying to delete mix of existing and non-existing files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);

    try expectThrown(
        "Cannot delete items: the following items do not exist: non-existent.txt, another-missing.txt",
        merkle_tree.deleteItems(allocator, &tree, &[_][]const u8{ "file1.txt", "non-existent.txt", "file3.txt", "another-missing.txt" }),
    );
}

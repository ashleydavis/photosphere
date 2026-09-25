//
// Tests for deleteItem (port of the 'File Deletion (deleteItem)' tests of src/test/deleteFile.test.ts).
// Not ported: the 'Hard File Deletion (deleteItems)' tests (deleteItems is not ported).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
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

//
// Tests for pruneTree (port of src/test/prune-tree.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const merkle_diff = merkle_tree_zig.merkle_diff;
const IMerkleTree = merkle_tree.IMerkleTree;
const MerkleNode = merkle_tree.MerkleNode;
const SortNode = merkle_tree.SortNode;
const containsName = merkle_verify.containsName;

//
// Helper function to build a test tree with multiple files
//
fn buildTestTree(allocator: std.mem.Allocator, fileNames: []const []const u8) !IMerkleTree {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    for (fileNames) |fileName| {
        tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
    }
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    return tree;
}

//
// Helper function to find a MerkleNode by file name
//
fn findMerkleNodeByFileName(merkleNode: ?*MerkleNode, fileName: []const u8) ?*MerkleNode {
    const currentNode = merkleNode orelse {
        return null;
    };

    if (currentNode.left == null and currentNode.right == null) {
        // Leaf node
        if (currentNode.name != null and std.mem.eql(u8, currentNode.name.?, fileName)) {
            return currentNode;
        }
        return null;
    }

    // Internal node - search children
    if (findMerkleNodeByFileName(currentNode.left, fileName)) |leftResult| {
        return leftResult;
    }
    return findMerkleNodeByFileName(currentNode.right, fileName);
}

//
// The leaf count of a tree (0 when empty).
//
fn leafCount(tree: *const IMerkleTree) u32 {
    return if (tree.sort) |sort| sort.leafCount else 0;
}

//
// Returns true when the tree has an item with the name.
//
fn hasItem(tree: *const IMerkleTree, name: []const u8) !bool {
    return (merkle_tree.findItemInTree(tree.sort, name)) != null;
}

test "should prune a single leaf node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt" });
    const initialLeafCount = leafCount(&tree);

    // Find the MerkleNode for file2.txt
    const nodeToPrune = findMerkleNodeByFileName(tree.merkle, "file2.txt").?;

    // Verify file exists before pruning
    try std.testing.expect(try hasItem(&tree, "file2.txt"));

    // Prune the node
    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{nodeToPrune});

    // Verify correct file was pruned
    try std.testing.expectEqual(@as(usize, 1), prunedFiles.len);
    try std.testing.expectEqualStrings("file2.txt", prunedFiles[0]);

    // Verify file is removed from sort tree
    try std.testing.expect(!try hasItem(&tree, "file2.txt"));
    try std.testing.expectEqual(initialLeafCount - 1, leafCount(&tree));

    // Verify other files still exist
    try std.testing.expect(try hasItem(&tree, "file1.txt"));
    try std.testing.expect(try hasItem(&tree, "file3.txt"));

    // Verify tree is marked as dirty
    try std.testing.expect(tree.dirty);
}

test "should prune multiple leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" });
    const initialLeafCount = leafCount(&tree);

    const node1 = findMerkleNodeByFileName(tree.merkle, "file2.txt").?;
    const node2 = findMerkleNodeByFileName(tree.merkle, "file4.txt").?;

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{ node1, node2 });

    try std.testing.expect(containsName(prunedFiles, "file2.txt"));
    try std.testing.expect(containsName(prunedFiles, "file4.txt"));
    try std.testing.expectEqual(@as(usize, 2), prunedFiles.len);

    try std.testing.expect(!try hasItem(&tree, "file2.txt"));
    try std.testing.expect(!try hasItem(&tree, "file4.txt"));
    try std.testing.expectEqual(initialLeafCount - 2, leafCount(&tree));

    try std.testing.expect(try hasItem(&tree, "file1.txt"));
    try std.testing.expect(try hasItem(&tree, "file3.txt"));
    try std.testing.expect(try hasItem(&tree, "file5.txt"));
    try std.testing.expect(tree.dirty);
}

test "should prune a subtree (internal node)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt" });
    const initialLeafCount = leafCount(&tree);

    // We'll use findMerkleTreeDifferences to get a subtree
    const tree2 = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt" }); // Smaller tree
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree.merkle, tree2.merkle);

    // diff.onlyInTree1 should contain nodes for d.txt and e.txt
    try std.testing.expect(diff.onlyInTree1.len > 0);

    // Prune the subtree
    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, diff.onlyInTree1);

    try std.testing.expect(prunedFiles.len > 0);
    try std.testing.expect(containsName(prunedFiles, "d.txt"));
    try std.testing.expect(containsName(prunedFiles, "e.txt"));

    try std.testing.expect(!try hasItem(&tree, "d.txt"));
    try std.testing.expect(!try hasItem(&tree, "e.txt"));
    try std.testing.expect(leafCount(&tree) < initialLeafCount);

    try std.testing.expect(try hasItem(&tree, "a.txt"));
    try std.testing.expect(try hasItem(&tree, "b.txt"));
    try std.testing.expect(try hasItem(&tree, "c.txt"));
    try std.testing.expect(tree.dirty);
}

test "should prune multiple subtrees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt" });
    const initialLeafCount = leafCount(&tree);

    const tree1 = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt" });
    const tree2 = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt", "d.txt" });

    const diff1 = try merkle_diff.findMerkleTreeDifferences(allocator, tree.merkle, tree1.merkle);
    const diff2 = try merkle_diff.findMerkleTreeDifferences(allocator, tree.merkle, tree2.merkle);

    // Combine nodes from both diffs
    const nodesToPrune = try std.mem.concat(allocator, *MerkleNode, &.{ diff1.onlyInTree1, diff2.onlyInTree1 });

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, nodesToPrune);

    try std.testing.expect(prunedFiles.len > 0);
    try std.testing.expect(tree.dirty);
    try std.testing.expect(leafCount(&tree) < initialLeafCount);
}

test "should handle empty nodes array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt" });
    const initialLeafCount = leafCount(&tree);
    const initialDirty = tree.dirty;

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{});

    try std.testing.expectEqual(@as(usize, 0), prunedFiles.len);
    try std.testing.expectEqual(initialLeafCount, leafCount(&tree));
    try std.testing.expectEqual(initialDirty, tree.dirty);
}

test "should handle nodes without names (skip them)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt" });
    const initialLeafCount = leafCount(&tree);

    // Create a MerkleNode without a name (internal node) that contains two files
    var leftNode: MerkleNode = .{ .hash = try merkle_verify.sha256(allocator, "left"), .nodeCount = 1, .name = "file1.txt" };
    var rightNode: MerkleNode = .{ .hash = try merkle_verify.sha256(allocator, "right"), .nodeCount = 1, .name = "file2.txt" };
    var internalNode: MerkleNode = .{ .hash = try merkle_verify.sha256(allocator, "test"), .nodeCount = 3, .left = &leftNode, .right = &rightNode };

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{&internalNode});

    try std.testing.expect(containsName(prunedFiles, "file1.txt"));
    try std.testing.expect(containsName(prunedFiles, "file2.txt"));
    try std.testing.expect(!try hasItem(&tree, "file1.txt"));
    try std.testing.expect(!try hasItem(&tree, "file2.txt"));
    try std.testing.expect(try hasItem(&tree, "file3.txt"));
    try std.testing.expectEqual(initialLeafCount - 2, leafCount(&tree));
    try std.testing.expect(tree.dirty);
}

test "should handle pruning files that do not exist in sort tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt" });
    const initialLeafCount = leafCount(&tree);

    var nonExistentNode: MerkleNode = .{ .hash = try merkle_verify.sha256(allocator, "nonexistent"), .nodeCount = 1, .name = "nonexistent.txt" };

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{&nonExistentNode});

    try std.testing.expect(containsName(prunedFiles, "nonexistent.txt"));
    try std.testing.expectEqual(initialLeafCount, leafCount(&tree));
    try std.testing.expect(tree.dirty);
}

test "should return pruned file names in correct order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt" });
    const node1 = findMerkleNodeByFileName(tree.merkle, "c.txt").?;
    const node2 = findMerkleNodeByFileName(tree.merkle, "a.txt").?;
    const node3 = findMerkleNodeByFileName(tree.merkle, "e.txt").?;

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{ node1, node2, node3 });

    try std.testing.expect(containsName(prunedFiles, "a.txt"));
    try std.testing.expect(containsName(prunedFiles, "c.txt"));
    try std.testing.expect(containsName(prunedFiles, "e.txt"));
    try std.testing.expectEqual(@as(usize, 3), prunedFiles.len);
}

test "should handle pruning all files from tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt" });

    // Prune the entire tree by using the root merkle node
    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{tree.merkle.?});

    try std.testing.expectEqual(@as(usize, 3), prunedFiles.len);
    try std.testing.expect(containsName(prunedFiles, "file1.txt"));
    try std.testing.expect(containsName(prunedFiles, "file2.txt"));
    try std.testing.expect(containsName(prunedFiles, "file3.txt"));
    try std.testing.expectEqual(@as(u32, 0), leafCount(&tree));
    try std.testing.expect(tree.dirty);
}

test "should not mark tree as dirty when no files are pruned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt" });
    tree.dirty = false;

    // Create a node with no name
    var nodeWithoutName: MerkleNode = .{ .hash = try merkle_verify.sha256(allocator, "test"), .nodeCount = 1 };

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{&nodeWithoutName});

    try std.testing.expectEqual(@as(usize, 0), prunedFiles.len);
    try std.testing.expect(!tree.dirty);
}

test "should handle duplicate file names in different nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "file1.txt", "file2.txt" });
    const initialLeafCount = leafCount(&tree);

    const node1 = findMerkleNodeByFileName(tree.merkle, "file1.txt").?;
    const node2 = findMerkleNodeByFileName(tree.merkle, "file1.txt").?;

    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{ node1, node2 });

    try std.testing.expect(prunedFiles.len >= 1);
    try std.testing.expect(containsName(prunedFiles, "file1.txt"));
    try std.testing.expect(!try hasItem(&tree, "file1.txt"));
    try std.testing.expectEqual(initialLeafCount - 1, leafCount(&tree));
    try std.testing.expect(tree.dirty);
}

test "should maintain tree structure integrity after pruning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator, &.{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt" });
    const initialLeafCount = leafCount(&tree);

    const nodeToPrune = findMerkleNodeByFileName(tree.merkle, "c.txt").?;
    const prunedFiles = try merkle_tree.pruneTree(allocator, &tree, &.{nodeToPrune});

    try std.testing.expectEqual(@as(usize, 1), prunedFiles.len);
    try std.testing.expectEqualStrings("c.txt", prunedFiles[0]);
    try std.testing.expect(tree.sort != null);
    try std.testing.expectEqual(initialLeafCount - 1, leafCount(&tree));

    for ([_][]const u8{ "a.txt", "b.txt", "d.txt", "e.txt" }) |name| {
        try std.testing.expect(try hasItem(&tree, name));
    }

    var leafTotal: u32 = 0;
    var leaves = merkle_tree.iterateLeaves(SortNode, allocator, tree.sort);
    while (try leaves.next()) |_| {
        leafTotal += 1;
    }
    try std.testing.expectEqual(initialLeafCount - 1, leafTotal);
}

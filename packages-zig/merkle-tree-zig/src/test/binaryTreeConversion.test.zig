//
// Tests for arrayToBinaryTree (port of the arrayToBinaryTree and round-trip tests of src/test/binaryTreeConversion.test.ts).
// binaryTreeToArray is not ported (no caller in psi replicate or psi verify), so the flat arrays are made by the
// test helper below, which does what binaryTreeToArray does; its own describe block is not ported.
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const FlatSortNode = merkle_tree.FlatSortNode;
const HashedItem = merkle_tree.HashedItem;

//
// Converts a binary tree to a flat pre-order array (the TypeScript binaryTreeToArray, test only).
//
fn binaryTreeToArray(allocator: std.mem.Allocator, flatNodes: *std.ArrayList(FlatSortNode), root: ?*const SortNode) !void {
    const currentNode = root orelse {
        return;
    };
    try flatNodes.append(allocator, .{
        .contentHash = currentNode.contentHash,
        .name = currentNode.name,
        .nodeCount = currentNode.nodeCount,
        .leafCount = currentNode.leafCount,
        .size = currentNode.size,
        .lastModified = currentNode.lastModified,
    });
    try binaryTreeToArray(allocator, flatNodes, currentNode.left);
    try binaryTreeToArray(allocator, flatNodes, currentNode.right);
}

//
// Converts a tree to a flat array and back.
//
fn roundTrip(allocator: std.mem.Allocator, root: ?*const SortNode) !?*SortNode {
    var flatNodes: std.ArrayList(FlatSortNode) = .empty;
    try binaryTreeToArray(allocator, &flatNodes, root);
    return merkle_tree.arrayToBinaryTree(allocator, flatNodes.items);
}

//
// Helper function to create a file hash with a given name and content
//
fn createHashedItem(name: []const u8, size: u64) HashedItem {
    return .{
        .name = name,
        .hash = name,
        .lastModified = 1_672_531_200_000,
        .length = size,
    };
}

//
// Builds a tree from `file1.txt`, `file2.txt`... names.
//
fn buildFileTree(allocator: std.mem.Allocator, count: usize) !IMerkleTree {
    var tree = merkle_tree.createTree("test-tree");
    var index: usize = 1;
    while (index <= count) {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{index});
        tree = try merkle_tree.addItem(allocator, &tree, createHashedItem(name, 8));
        index += 1;
    }
    return tree;
}

test "should handle empty array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try merkle_tree.arrayToBinaryTree(arena.allocator(), &.{})) == null);
}

test "should convert single node array correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree("test-tree");
    tree = try merkle_tree.addItem(allocator, &tree, createHashedItem("test1.txt", 8));
    const reconstructed = (try roundTrip(allocator, tree.sort)).?;
    try std.testing.expectEqualStrings("test1.txt", reconstructed.name.?);
    try std.testing.expectEqual(@as(u32, 1), reconstructed.nodeCount);
    try std.testing.expectEqual(@as(u32, 1), reconstructed.leafCount);
    try std.testing.expect(reconstructed.left == null);
    try std.testing.expect(reconstructed.right == null);
}

test "should reconstruct tree structure correctly for multiple nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildFileTree(allocator, 3);
    const reconstructed = (try roundTrip(allocator, tree.sort)).?;
    try std.testing.expectEqual(@as(u32, 5), reconstructed.nodeCount);
    try std.testing.expectEqual(@as(u32, 3), reconstructed.leafCount);
    try std.testing.expect(reconstructed.left != null or reconstructed.right != null);
}

test "should preserve all node properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree("test-tree");
    tree = try merkle_tree.addItem(allocator, &tree, createHashedItem("test.txt", 8));
    const reconstructed = (try roundTrip(allocator, tree.sort)).?;
    try std.testing.expectEqualStrings(tree.sort.?.name.?, reconstructed.name.?);
    try std.testing.expectEqual(tree.sort.?.nodeCount, reconstructed.nodeCount);
    try std.testing.expectEqual(tree.sort.?.leafCount, reconstructed.leafCount);
    try std.testing.expectEqual(tree.sort.?.size, reconstructed.size);
    try std.testing.expectEqual(tree.sort.?.lastModified, reconstructed.lastModified);
}

test "should maintain tree integrity through conversion cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildFileTree(allocator, 7);
    const originalRoot = tree.sort.?;
    const reconstructed = (try roundTrip(allocator, originalRoot)).?;
    try std.testing.expectEqual(originalRoot.nodeCount, reconstructed.nodeCount);
    try std.testing.expectEqual(originalRoot.leafCount, reconstructed.leafCount);
    try std.testing.expectEqual(originalRoot.size, reconstructed.size);
    try std.testing.expectEqualStrings(originalRoot.minName, reconstructed.minName);
}

test "should handle leaf nodes correctly in round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree("test-tree");
    tree = try merkle_tree.addItem(allocator, &tree, createHashedItem("single.txt", 8));
    const reconstructed = (try roundTrip(allocator, tree.sort)).?;
    try std.testing.expectEqualStrings("single.txt", reconstructed.name.?);
    try std.testing.expectEqual(@as(u32, 1), reconstructed.nodeCount);
    try std.testing.expect(reconstructed.left == null);
    try std.testing.expect(reconstructed.right == null);
}

//
// Verifies leaves have names and no children, and internal nodes have counts matching their children.
//
fn verifyTreeStructure(sortNode: ?*const SortNode) !void {
    const currentNode = sortNode orelse {
        return;
    };
    if (currentNode.nodeCount == 1) {
        try std.testing.expect(currentNode.left == null);
        try std.testing.expect(currentNode.right == null);
        try std.testing.expect(currentNode.name != null);
    }
    else {
        try std.testing.expect(currentNode.name == null);
        var expectedCount: u32 = 1;
        if (currentNode.left) |left| {
            expectedCount += left.nodeCount;
            try verifyTreeStructure(left);
        }
        if (currentNode.right) |right| {
            expectedCount += right.nodeCount;
            try verifyTreeStructure(right);
        }
        try std.testing.expectEqual(expectedCount, currentNode.nodeCount);
    }
}

test "should maintain correct tree structure after round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildFileTree(allocator, 4);
    try verifyTreeStructure(try roundTrip(allocator, tree.sort));
}


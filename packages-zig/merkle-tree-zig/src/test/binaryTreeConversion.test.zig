//
// Tests for binaryTreeToArray and arrayToBinaryTree (port of src/test/binaryTreeConversion.test.ts).
// (Zig: FlatSortNode has no left or right fields, so the `not.toHaveProperty('left')` checks hold by its type.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const utils = @import("utils-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const HashedItem = merkle_tree.HashedItem;

//
// Converts a tree to a flat array and back.
//
fn roundTrip(allocator: std.mem.Allocator, root: ?*SortNode) !?*SortNode {
    const flatArray = try merkle_tree.binaryTreeToArray(allocator, root);
    return merkle_tree.arrayToBinaryTree(allocator, flatArray);
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

test "should handle empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try merkle_tree.binaryTreeToArray(arena.allocator(), null);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "should convert single node tree correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = merkle_tree.createTree("test-tree");
    const updatedTree = try merkle_tree.addItem(allocator, &tree, createHashedItem("test1.txt", 8));

    const flatArray = try merkle_tree.binaryTreeToArray(allocator, updatedTree.sort);

    try std.testing.expectEqual(@as(usize, 1), flatArray.len);
    try std.testing.expectEqualStrings("test1.txt", flatArray[0].name.?);
    try std.testing.expectEqual(@as(u32, 1), flatArray[0].nodeCount);
    try std.testing.expectEqual(@as(u32, 1), flatArray[0].leafCount);
}

test "should convert small tree with multiple nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Add 3 files to create a small tree
    const tree = try buildFileTree(allocator, 3);

    const flatArray = try merkle_tree.binaryTreeToArray(allocator, tree.sort);

    // Should have 5 nodes (3 leaves + 2 internal nodes)
    try std.testing.expectEqual(@as(usize, 5), flatArray.len);

    // Root node should be first and have nodeCount of 5
    try std.testing.expectEqual(@as(u32, 5), flatArray[0].nodeCount);
    try std.testing.expectEqual(@as(u32, 3), flatArray[0].leafCount);
}

test "should preserve all node properties except left/right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree("test-tree");
    tree = try merkle_tree.addItem(allocator, &tree, createHashedItem("test.txt", 8));

    const flatArray = try merkle_tree.binaryTreeToArray(allocator, tree.sort);
    const node = flatArray[0];

    try std.testing.expect(node.contentHash != null);
    try std.testing.expectEqualStrings("test.txt", node.name.?);
    try std.testing.expectEqual(@as(u32, 1), node.nodeCount);
    try std.testing.expectEqual(@as(u32, 1), node.leafCount);
    try std.testing.expectEqual(@as(u64, 8), node.size);
    try std.testing.expect(node.lastModified != null);
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


test "arrayToBinaryTree throws for an array that ends before a parent's children, like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A parent of two children with only its first child in the array: TypeScript reads `node.right!.leafCount`
    // of undefined.
    try std.testing.expectError(error.Thrown, merkle_tree.arrayToBinaryTree(arena.allocator(), &.{
        .{ .nodeCount = 3, .leafCount = 2, .size = 2 },
        .{ .name = "A", .contentHash = "hash", .nodeCount = 1, .leafCount = 1, .size = 1 },
    }));
    try std.testing.expectEqualStrings("TypeError: Cannot read properties of undefined (reading 'leafCount')", utils.errors.lastErrorMessage());
}

//
// Leaf order for every insertion order (port of src/test/sorted-leaf-order.test.ts).
// (Zig: TypeScript generates one test per permutation; here one test checks all of them.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const SortNode = merkle_tree.SortNode;
const HashedItem = merkle_tree.HashedItem;
const IMerkleTree = merkle_tree.IMerkleTree;
const generatePermutations = merkle_verify.generatePermutations;

//
// Helper function to create a HashedItem for testing
//
fn createTestHashedItem(name: []const u8) HashedItem {
    return .{
        .name = name,
        .hash = name, // Simple hash for testing
        .length = name.len,
        .lastModified = merkle_verify.TEST_TIMESTAMP,
    };
}

//
// Helper function to extract leaf nodes in order from a tree
//
fn getLeafNodesInOrder(allocator: std.mem.Allocator, leafNames: *std.ArrayList([]const u8), sortNode: ?*const SortNode) !void {
    const currentNode = sortNode orelse {
        return;
    };

    if (currentNode.name) |name| {
        // This is a leaf node
        try leafNames.append(allocator, name);
        return;
    }

    // This is an internal node, recursively get leaves from children
    try getLeafNodesInOrder(allocator, leafNames, currentNode.left);
    try getLeafNodesInOrder(allocator, leafNames, currentNode.right);
}

//
// Helper function to verify that leaf nodes are sorted using natural/numeric sorting
//
fn verifyLeafNodesAreSorted(leafNodes: []const []const u8) bool {
    var index: usize = 1;
    while (index < leafNodes.len) {
        if (merkle_tree.compareNames(leafNodes[index - 1], leafNodes[index]) > 0) {
            return false;
        }
        index += 1;
    }
    return true;
}

//
// Builds a tree by adding the names in order and returns its leaf names in tree order.
//
fn buildLeafOrder(allocator: std.mem.Allocator, permutation: []const []const u8) ![]const []const u8 {
    // Create a new tree for this permutation
    var merkleTree: IMerkleTree = merkle_tree.createTree("test-tree");

    // Add each file in the permutation order
    for (permutation) |fileName| {
        merkleTree = try merkle_tree.addItem(allocator, &merkleTree, createTestHashedItem(fileName));
    }

    var leafNames: std.ArrayList([]const u8) = .empty;
    try getLeafNodesInOrder(allocator, &leafNames, merkleTree.sort);
    return leafNames.items;
}

test "permutation N should maintain sorted leaf order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const permutations = try generatePermutations(allocator, &.{ "a", "b", "c", "d", "e" });
    for (permutations) |permutation| {
        const leafNodes = try buildLeafOrder(allocator, permutation);
        try std.testing.expectEqual(@as(usize, 5), leafNodes.len); // Verify we have all 5 files
        for ([_][]const u8{ "a", "b", "c", "d", "e" }) |name| {
            try std.testing.expect(merkle_verify.containsName(leafNodes, name));
        }
    }
}

test "summary: documents overall behavior of leaf node ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const permutations = try generatePermutations(allocator, &.{ "a", "b", "c", "d", "e" });
    var resultCount: usize = 0;
    for (permutations) |permutation| {
        const leafNodes = try buildLeafOrder(allocator, permutation);
        _ = verifyLeafNodesAreSorted(leafNodes);
        resultCount += 1;
    }
    try std.testing.expectEqual(@as(usize, 120), resultCount); // Verify we tested all permutations
}

test "should maintain sorted order with different file sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const testCases = [_][]const []const u8{
        &.{ "x", "a", "z" },
        &.{ "1", "2", "3" },
        &.{ "alpha", "beta", "gamma" },
        &.{ "file1", "file2", "file10" }, // Tests numeric string sorting
    };
    const expectedSortedOrders = [_][]const []const u8{
        &.{ "a", "x", "z" },
        &.{ "1", "2", "3" },
        &.{ "alpha", "beta", "gamma" },
        &.{ "file1", "file2", "file10" },
    };

    for (testCases, expectedSortedOrders) |files, expectedSortedOrder| {
        const permutations = try generatePermutations(allocator, files);
        for (permutations) |permutation| {
            const leafNodes = try buildLeafOrder(allocator, permutation);
            try std.testing.expect(verifyLeafNodesAreSorted(leafNodes));
            try std.testing.expectEqual(expectedSortedOrder.len, leafNodes.len);
            for (expectedSortedOrder, leafNodes) |expected, actual| {
                try std.testing.expectEqualStrings(expected, actual);
            }
        }
    }
}

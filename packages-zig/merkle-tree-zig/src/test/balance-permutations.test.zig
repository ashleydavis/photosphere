//
// Balance verification for every insertion order (port of src/test/balance-permutations.test.ts).
// (Zig: TypeScript generates one test per permutation; Zig test names are fixed, so each group is one test that
// checks every permutation and reports the failing one.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const SortNode = merkle_tree.SortNode;
const buildTree = merkle_verify.buildTree;
const generatePermutations = merkle_verify.generatePermutations;

//
// Helper function to check if a tree is balanced
//
fn isTreeBalanced(sortNode: ?*const SortNode) bool {
    const currentNode = sortNode orelse {
        return true;
    };

    // Leaf nodes are always balanced
    if (currentNode.nodeCount == 1) {
        return true;
    }

    // Check if this node is balanced (difference between left and right node counts <= 2)
    const leftCount: i64 = if (currentNode.left) |left| left.nodeCount else 0;
    const rightCount: i64 = if (currentNode.right) |right| right.nodeCount else 0;
    const balance = @abs(leftCount - rightCount);

    if (balance > 2) {
        return false;
    }

    // Recursively check both subtrees
    return isTreeBalanced(currentNode.left) and isTreeBalanced(currentNode.right);
}

//
// Checks that every permutation of the names builds a balanced tree.
//
fn expectAllPermutationsBalanced(names: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const permutations = try generatePermutations(allocator, names);
    for (permutations, 0..) |permutation, index| {
        const merkleTree = try buildTree(allocator, permutation);
        if (!isTreeBalanced(merkleTree.sort)) {
            std.debug.print("Permutation {d} is unbalanced: {any}\n", .{ index + 1, permutation });
            return error.TestUnexpectedResult;
        }
    }
}

test "3 files permutation N should result in balanced tree" {
    try expectAllPermutationsBalanced(&.{ "a", "b", "c" });
}

test "4 files permutation N should result in balanced tree" {
    try expectAllPermutationsBalanced(&.{ "a", "b", "c", "d" });
}

test "5 files permutation N should result in balanced tree" {
    try expectAllPermutationsBalanced(&.{ "a", "b", "c", "d", "e" });
}

test "verify balance criteria matches rebalanceTree function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test that our balance checking logic matches the rebalanceTree function's criteria
    const permutations = try generatePermutations(allocator, &.{ "a", "b", "c", "d", "e" });

    for (permutations) |permutation| {
        const merkleTree = try buildTree(allocator, permutation);

        if (merkleTree.sort) |sort| {
            // Check if our balance function thinks it needs rebalancing
            const isBalanced = isTreeBalanced(sort);

            // Check if rebalanceTree would change the tree
            const rebalanced = try merkle_tree.rebalanceTree(allocator, sort);
            const needsRebalancing = rebalanced != sort;

            // Our balance check should match the rebalanceTree behavior
            try std.testing.expectEqual(!needsRebalancing, isBalanced);
        }
    }
}

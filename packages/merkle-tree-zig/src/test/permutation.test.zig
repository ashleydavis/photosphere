//
// Every insertion order produces the same tree (port of src/test/permutation.test.ts).
// (Zig: TypeScript generates one test per permutation; here one test checks all of them.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;

//
// Builds a tree by adding the files in the permutation order and builds its merkle tree.
//
fn createPermutationTree(allocator: std.mem.Allocator, permutation: []const []const u8) !IMerkleTree {
    var tree = try merkle_verify.buildTree(allocator, permutation);
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.
    return tree;
}

test "should produce same tree for permutation 1 [a-b-c-d-e] and N" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const permutations = try merkle_verify.generatePermutations(allocator, &.{ "a", "b", "c", "d", "e" });
    const comparisonTree = try createPermutationTree(allocator, permutations[0]);

    // Test that every other permutation produces the same tree as the first permutation.
    for (permutations[1..]) |permutation| {
        const permutationTree = try createPermutationTree(allocator, permutation);
        const root = permutationTree.merkle;
        try std.testing.expect(root != null);
        try std.testing.expectEqualSlices(u8, comparisonTree.merkle.?.hash, root.?.hash);
    }
}

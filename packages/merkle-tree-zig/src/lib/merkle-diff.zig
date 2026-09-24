const std = @import("std");
const utils = @import("utils-zig");
const buffer_map = @import("buffer-map.zig");
const merkle_tree = @import("merkle-tree.zig");
const errors = utils.errors;
const BufferMap = buffer_map.BufferMap;
const MerkleNode = merkle_tree.MerkleNode;

//
// The result of comparing two merkle trees.
//
pub const MerkleTreeDiff = struct {
    // True when both trees have the same content.
    identical: bool,

    // Subtrees whose leaves are only in the first tree.
    onlyInTree1: []*MerkleNode,

    // Subtrees whose leaves are only in the second tree.
    onlyInTree2: []*MerkleNode,
};

//
// Processes remaining nodes after the main breadth-first traversal completes.
// For hashes in nodes that match mapB (count > 0), decrements the count.
// For internal nodes that don't match, recursively checks their leaves
// to handle duplicate files correctly.
//
// @internal - Exported for testing purposes only
//
pub fn processRemainingNodes(allocator: std.mem.Allocator, nodes: []const *MerkleNode, mapB: *BufferMap(u64), onlyInTree1: *std.ArrayList(*MerkleNode)) !void {
    for (nodes) |nodeA| {
        if (nodeA.nodeCount == 1) {
            // Leaf node - check against map
            const countB = try mapB.get(nodeA.hash);
            if (countB == null or countB.? == 0) {
                // This leaf hash doesn't exist in tree B or has been fully matched
                try onlyInTree1.append(allocator, nodeA);
            }
            else {
                // Decrement count for this match
                // This means this leaf in tree A matches a leaf in tree B
                // Note: We match by hash, not by name, so duplicate files with the same hash
                // will match against each other correctly
                _ = try mapB.set(nodeA.hash, countB.? - 1);
            }
        }
        else {
            // Internal node - check against map
            const countB = try mapB.get(nodeA.hash);
            if (countB != null and countB.? > 0) {
                // This internal node matches - decrement count and skip children
                _ = try mapB.set(nodeA.hash, countB.? - 1);
            }
            else {
                // This internal node doesn't match - expand it to check its children individually
                // This is necessary to detect duplicate files correctly
                if (nodeA.left != null and nodeA.right != null) {
                    try processRemainingNodes(allocator, &.{ nodeA.left.?, nodeA.right.? }, mapB, onlyInTree1);
                }
                else if (nodeA.left != null) {
                    return errors.throwError("Invalid tree structure: nodeA has a left child but no right child", .{});
                }
                else if (nodeA.right != null) {
                    return errors.throwError("Invalid tree structure: nodeA has a right child but no left child", .{});
                }
                else {
                    // This shouldn't happen for an internal node, but handle it
                    try onlyInTree1.append(allocator, nodeA);
                }
            }
        }
    }
}

//
// Efficiently finds differences between two Merkle trees by comparing hashes.
// Uses lazy expansion of tree B while traversing tree A breadth-first.
// When a node's hash from A is found anywhere in B, both subtrees are identical and skipped.
//
// @param treeA - The first Merkle tree root
// @param treeB - The second Merkle tree root
// @returns Nodes that are different or new in treeA compared to treeB
//
pub fn findDifferingNodes(allocator: std.mem.Allocator, treeA: *MerkleNode, treeB: *MerkleNode) ![]*MerkleNode {

    // Map of hash counts from tree B (lazily populated)
    // Tracks how many times each hash appears in tree B
    var mapB = BufferMap(u64).init(allocator);

    // Queue for traversing tree A breadth-first
    var queueA: std.ArrayList(*MerkleNode) = .empty;
    try queueA.append(allocator, treeA);

    // Queue for expanding tree B level by level
    var queueB: std.ArrayList(*MerkleNode) = .empty;
    try queueB.append(allocator, treeB);

    while (queueA.items.len > 0 and queueB.items.len > 0) {
        // Expand the next level of tree B into the map.
        if (queueB.items.len > 0) {
            const currentLevelB = queueB;
            queueB = .empty;

            for (currentLevelB.items) |nodeB| {
                // Track hash counts
                const currentCount = (try mapB.get(nodeB.hash)) orelse 0;
                _ = try mapB.set(nodeB.hash, currentCount + 1);

                if (nodeB.left != null and nodeB.right != null) {
                    // Queue children of nodeB to further expand the maps on the next iteration.
                    try queueB.append(allocator, nodeB.left.?);
                    try queueB.append(allocator, nodeB.right.?);
                }
                else if (nodeB.left != null) {
                    return errors.throwError("Invalid tree structure: nodeB has a left child but no right child", .{});
                }
                else if (nodeB.right != null) {
                    return errors.throwError("Invalid tree structure: nodeB has a right child but no left child", .{});
                }
                else {
                    // nodeB is a leaf node, at this point we have worked our way through tree B.
                }
            }
        }

        const currentLevelA = queueA; // Process the current level of tree A.
        queueA = .empty; // Clear the queue for the next level.

        for (currentLevelA.items) |nodeA| {
            // Check if this node exists in tree B
            if (nodeA.nodeCount == 1) {
                // Leaf node - match against map
                const countB = try mapB.get(nodeA.hash);
                if (countB != null and countB.? > 0) {
                    // Decrement count - this leaf hash has been matched once
                    _ = try mapB.set(nodeA.hash, countB.? - 1);
                    // Don't add children (there are none for leaf nodes)
                    continue;
                }
            }

            // For internal nodes, always expand them to check leaves individually
            // This ensures duplicate file counts are handled correctly.
            // Note: This is slower than matching internal nodes directly, but necessary
            // for correctness when duplicate files exist.
            if (nodeA.left != null and nodeA.right != null) {
                // Queue children of nodeA to check against expanded maps in next iteration.
                try queueA.append(allocator, nodeA.left.?);
                try queueA.append(allocator, nodeA.right.?);
            }
            else if (nodeA.left != null) {
                return errors.throwError("Invalid tree structure: nodeA has a left child but no right child", .{});
            }
            else if (nodeA.right != null) {
                return errors.throwError("Invalid tree structure: nodeA has a right child but no left child", .{});
            }
            else {
                // This is a leaf node, requeue it to check against the expanded maps in next iteration.
                try queueA.append(allocator, nodeA);
            }
        }
    }

    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;

    // Process any remaining nodes in queueA after the main loop completes
    if (queueA.items.len > 0) {
        try processRemainingNodes(allocator, queueA.items, &mapB, &onlyInTree1);
    }

    return onlyInTree1.items;
}

//
// Finds differences between two Merkle trees by running the comparison both ways.
//
pub fn findMerkleTreeDifferences(
    allocator: std.mem.Allocator,
    tree1: ?*MerkleNode,
    tree2: ?*MerkleNode,
) !MerkleTreeDiff {
    const firstTree = tree1 orelse {
        const secondTree = tree2 orelse {
            // Empty trees are considered identical.
            return .{
                .identical = true,
                .onlyInTree1 = &.{},
                .onlyInTree2 = &.{},
            };
        };
        // Tree1 is empty and tree2 is not empty.
        const onlyInTree2 = try allocator.alloc(*MerkleNode, 1);
        onlyInTree2[0] = secondTree; // The entire tree2 is only in tree2.
        return .{
            .identical = false,
            .onlyInTree1 = &.{},
            .onlyInTree2 = onlyInTree2,
        };
    };
    const secondTree = tree2 orelse {
        // Tree1 is not empty and tree2 is empty.
        const onlyInTree1 = try allocator.alloc(*MerkleNode, 1);
        onlyInTree1[0] = firstTree; // The entire tree1 is only in tree1.
        return .{
            .identical = false,
            .onlyInTree1 = onlyInTree1,
            .onlyInTree2 = &.{},
        };
    };
    // Both trees are not empty, so we need to compare the trees.

    // Quick check: if root hashes are identical, trees are identical
    if (std.mem.eql(u8, firstTree.hash, secondTree.hash)) {
        return .{
            .identical = true,
            .onlyInTree1 = &.{},
            .onlyInTree2 = &.{},
        };
    }

    const onlyInTree1 = try findDifferingNodes(allocator, firstTree, secondTree); //todo: This could be done in a single pass.
    const onlyInTree2 = try findDifferingNodes(allocator, secondTree, firstTree);
    return .{
        .identical = false,
        .onlyInTree1 = onlyInTree1,
        .onlyInTree2 = onlyInTree2,
    };
}

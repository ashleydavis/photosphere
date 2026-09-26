//
// Tests for findMerkleTreeDifferences, findDifferingNodes and processRemainingNodes (port of src/test/merkle-diff.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const merkle_diff = merkle_tree_zig.merkle_diff;
const errors = @import("utils-zig").errors;
const MerkleNode = merkle_tree.MerkleNode;
const BufferMap = merkle_tree_zig.buffer_map.BufferMap;
const containsName = merkle_verify.containsName;

//
// Creates a leaf whose hash is the SHA-256 of its content.
//
fn createLeaf(allocator: std.mem.Allocator, name: []const u8, content: []const u8) !*MerkleNode {
    const leafNode = try allocator.create(MerkleNode);
    leafNode.* = .{
        .name = name,
        .hash = try merkle_verify.sha256(allocator, content),
        .nodeCount = 1,
    };
    return leafNode;
}

//
// Creates a leaf whose content is its name.
//
fn createNamedLeaf(allocator: std.mem.Allocator, name: []const u8) !*MerkleNode {
    return createLeaf(allocator, name, name);
}

//
// Creates an internal node over two nodes.
//
fn createInternal(allocator: std.mem.Allocator, left: *MerkleNode, right: *MerkleNode) !*MerkleNode {
    const hash = try allocator.create([32]u8);
    hash.* = merkle_tree.combineHashes(left.hash, right.hash);
    const internal = try allocator.create(MerkleNode);
    internal.* = .{
        .left = left,
        .right = right,
        .hash = hash,
        .nodeCount = left.nodeCount + right.nodeCount + 1,
    };
    return internal;
}

//
// Builds a simple Merkle tree from an array of leaves.
// This is a helper function for testing.
//
fn buildMerkleTreeFromLeaves(allocator: std.mem.Allocator, leafs: []const *MerkleNode) !?*MerkleNode {
    // Start with the leaf nodes
    var nodes: []const *MerkleNode = leafs;

    // Build tree bottom-up
    while (nodes.len > 1) {
        var nextLevel: std.ArrayList(*MerkleNode) = .empty;
        var index: usize = 0;
        while (index < nodes.len) {
            const left = nodes[index];

            // If there's an odd number of nodes, promote the last one directly
            if (index + 1 >= nodes.len) {
                try nextLevel.append(allocator, left);
                break;
            }

            const right = nodes[index + 1];
            try nextLevel.append(allocator, try createInternal(allocator, left, right));
            index += 2;
        }
        nodes = nextLevel.items;
    }

    if (nodes.len == 0) {
        return null;
    }
    return nodes[0];
}

//
// Builds a tree from leaves named after (and with the content of) the names.
//
fn buildNamedTree(allocator: std.mem.Allocator, names: []const []const u8) !?*MerkleNode {
    var leaves: std.ArrayList(*MerkleNode) = .empty;
    for (names) |name| {
        try leaves.append(allocator, try createNamedLeaf(allocator, name));
    }
    return buildMerkleTreeFromLeaves(allocator, leaves.items);
}

//
// Extracts the sorted leaf names of the diff result nodes.
//
fn diffLeafNames(allocator: std.mem.Allocator, nodes: []const *MerkleNode) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (nodes) |diffNode| {
        try merkle_verify.collectMerkleLeafNames(allocator, &names, diffNode);
    }
    merkle_verify.sortNames(names.items);
    return names.items;
}

//
// Checks the names of the diff result nodes, in order.
//
fn expectNodeNames(expected: []const []const u8, nodes: []const *MerkleNode) !void {
    try std.testing.expectEqual(expected.len, nodes.len);
    for (expected, nodes) |expectedName, actual| {
        try std.testing.expectEqualStrings(expectedName, actual.name.?);
    }
}

//
// Checks two lists of names are equal.
//
fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }
}

test "should handle empty trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{}), try buildNamedTree(allocator, &.{}));
    try std.testing.expect(diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should handle empty tree and non-empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{}), try buildNamedTree(allocator, &.{"file1"}));
    try std.testing.expect(!diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try expectNodeNames(&.{"file1"}, diff.onlyInTree2);
}

test "should handle non-empty tree and empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{"file1"}), try buildNamedTree(allocator, &.{}));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{"file1"}, diff.onlyInTree1);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should detect identical trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaves = [_]*MerkleNode{ try createNamedLeaf(allocator, "file1"), try createNamedLeaf(allocator, "file2"), try createNamedLeaf(allocator, "file3") };
    const tree1 = try buildMerkleTreeFromLeaves(allocator, &leaves);
    const tree2 = try buildMerkleTreeFromLeaves(allocator, &leaves);
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should detect single leaf difference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{ "file1", "file2" }), try buildNamedTree(allocator, &.{ "file1", "file2-modified" }));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{"file2"}, diff.onlyInTree1);
    try expectNodeNames(&.{"file2-modified"}, diff.onlyInTree2);
}

test "should detect added file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{ "file1", "file2" }), try buildNamedTree(allocator, &.{ "file1", "file2", "file3" }));
    try std.testing.expect(!diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try expectNodeNames(&.{"file3"}, diff.onlyInTree2);
}

test "should detect removed file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{ "file1", "file2", "file3" }), try buildNamedTree(allocator, &.{ "file1", "file2" }));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{"file3"}, diff.onlyInTree1);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should handle completely different trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{ "fileA", "fileB" }), try buildNamedTree(allocator, &.{ "fileX", "fileY" }));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{ "fileA", "fileB" }, diff.onlyInTree1);
    try expectNodeNames(&.{ "fileX", "fileY" }, diff.onlyInTree2);
}

test "should handle single node trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{"file1"}), try buildNamedTree(allocator, &.{"file2"}));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{"file1"}, diff.onlyInTree1);
    try expectNodeNames(&.{"file2"}, diff.onlyInTree2);
}

test "should detect multiple changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildMerkleTreeFromLeaves(allocator, &.{
        try createLeaf(allocator, "file1", "content1"),
        try createLeaf(allocator, "file2", "content2"),
        try createLeaf(allocator, "file3", "content3"),
        try createLeaf(allocator, "file4", "content4"),
    });
    const tree2 = try buildMerkleTreeFromLeaves(allocator, &.{
        try createLeaf(allocator, "file1", "content1-modified"),
        try createLeaf(allocator, "file2", "content2"),
        try createLeaf(allocator, "file3", "content3-modified"),
        try createLeaf(allocator, "file4", "content4"),
    });
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{ "file1", "file3" }, diff.onlyInTree1);
    try expectNodeNames(&.{ "file1", "file3" }, diff.onlyInTree2);
}

test "should handle trees with overlapping content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{ "file1", "file2", "file3" }), try buildNamedTree(allocator, &.{ "file2", "file3", "file4" }));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{"file1"}, diff.onlyInTree1);
    try expectNodeNames(&.{"file4"}, diff.onlyInTree2);
}

test "should handle large trees efficiently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var leaves1: std.ArrayList(*MerkleNode) = .empty;
    var leaves2: std.ArrayList(*MerkleNode) = .empty;
    var index: usize = 0;
    while (index < 1000) {
        const name = try std.fmt.allocPrint(allocator, "file{d}", .{index});
        try leaves1.append(allocator, try createLeaf(allocator, name, try std.fmt.allocPrint(allocator, "content{d}", .{index})));
        const content2 = if (index < 50) try std.fmt.allocPrint(allocator, "content{d}", .{index}) else try std.fmt.allocPrint(allocator, "modified{d}", .{index});
        try leaves2.append(allocator, try createLeaf(allocator, name, content2));
        index += 1;
    }
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildMerkleTreeFromLeaves(allocator, leaves1.items), try buildMerkleTreeFromLeaves(allocator, leaves2.items));
    try std.testing.expect(!diff.identical);
}

test "should detect changes when trees have different structures but same leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaves1 = [_]*MerkleNode{ try createNamedLeaf(allocator, "a"), try createNamedLeaf(allocator, "b"), try createNamedLeaf(allocator, "c") };
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildMerkleTreeFromLeaves(allocator, &leaves1), try buildMerkleTreeFromLeaves(allocator, &leaves1));
    try std.testing.expect(diff.identical); // Same leaves, same order = identical
}

test "should handle empty overlap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildNamedTree(allocator, &.{ "unique1", "unique2" }), try buildNamedTree(allocator, &.{ "different1", "different2" }));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{ "unique1", "unique2" }, diff.onlyInTree1);
    try expectNodeNames(&.{ "different1", "different2" }, diff.onlyInTree2);
}

test "should detect subset relationship" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sharedLeaves = [_]*MerkleNode{ try createNamedLeaf(allocator, "file1"), try createNamedLeaf(allocator, "file2") };
    const tree1 = try buildMerkleTreeFromLeaves(allocator, &sharedLeaves);
    const tree2 = try buildMerkleTreeFromLeaves(allocator, &.{ sharedLeaves[0], sharedLeaves[1], try createNamedLeaf(allocator, "file3"), try createNamedLeaf(allocator, "file4") });
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try expectNodeNames(&.{ "file3", "file4" }, diff.onlyInTree2);
}

test "should handle trees with 7 nodes (complex odd structure)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var leaves1: [7]*MerkleNode = undefined;
    var leaves2: [7]*MerkleNode = undefined;
    for (&leaves1, &leaves2, 0..) |*leaf1, *leaf2, index| {
        const name = try std.fmt.allocPrint(allocator, "file{d}", .{index});
        leaf1.* = try createNamedLeaf(allocator, name);
        leaf2.* = try createLeaf(allocator, name, if (index == 3) "modified" else name);
    }
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildMerkleTreeFromLeaves(allocator, &leaves1), try buildMerkleTreeFromLeaves(allocator, &leaves2));
    try std.testing.expect(!diff.identical);
    try expectNodeNames(&.{"file3"}, diff.onlyInTree1);
    try expectNodeNames(&.{"file3"}, diff.onlyInTree2);
}

test "should detect missing files in tree 2 (a1098947 case)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Tree 1: Contains all files including the three a1098947 files
    const tree1 = try buildNamedTree(allocator, &.{
        "asset/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b",
        "asset/3171e283-0fe4-4378-8f1a-e364a209ed67",
        "asset/03861e30-e852-4589-96cf-87cd760ff662",
        "asset/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9",
        "asset/a1098947-c6a3-4fe3-abb3-58c6ea951e21", // Only in tree 1
        "asset/ebb4a79f-e991-4934-a164-15f032804e0e",
        "display/3171e283-0fe4-4378-8f1a-e364a209ed67",
        "display/03861e30-e852-4589-96cf-87cd760ff662",
        "display/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9",
        "display/a1098947-c6a3-4fe3-abb3-58c6ea951e21", // Only in tree 1
        "display/ebb4a79f-e991-4934-a164-15f032804e0e",
        "README.md",
        "thumb/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b",
        "thumb/3171e283-0fe4-4378-8f1a-e364a209ed67",
        "thumb/03861e30-e852-4589-96cf-87cd760ff662",
        "thumb/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9",
        "thumb/a1098947-c6a3-4fe3-abb3-58c6ea951e21", // Only in tree 1
        "thumb/ebb4a79f-e991-4934-a164-15f032804e0e",
    });

    // Tree 2: Missing the three a1098947 files
    const tree2 = try buildNamedTree(allocator, &.{
        "asset/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b",
        "asset/3171e283-0fe4-4378-8f1a-e364a209ed67",
        "asset/03861e30-e852-4589-96cf-87cd760ff662",
        "asset/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9",
        "asset/ebb4a79f-e991-4934-a164-15f032804e0e",
        "display/3171e283-0fe4-4378-8f1a-e364a209ed67",
        "display/03861e30-e852-4589-96cf-87cd760ff662",
        "display/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9",
        "display/ebb4a79f-e991-4934-a164-15f032804e0e",
        "README.md",
        "thumb/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b",
        "thumb/3171e283-0fe4-4378-8f1a-e364a209ed67",
        "thumb/03861e30-e852-4589-96cf-87cd760ff662",
        "thumb/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9",
        "thumb/ebb4a79f-e991-4934-a164-15f032804e0e",
    });

    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    try expectNames(&.{
        "asset/a1098947-c6a3-4fe3-abb3-58c6ea951e21",
        "display/a1098947-c6a3-4fe3-abb3-58c6ea951e21",
        "thumb/a1098947-c6a3-4fe3-abb3-58c6ea951e21",
    }, try diffLeafNames(allocator, diff.onlyInTree1));
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should return empty array for identical trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaves = [_]*MerkleNode{ try createNamedLeaf(allocator, "file1"), try createNamedLeaf(allocator, "file2") };
    const diff = try merkle_diff.findDifferingNodes(allocator, (try buildMerkleTreeFromLeaves(allocator, &leaves)).?, (try buildMerkleTreeFromLeaves(allocator, &leaves)).?);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "should find nodes unique to tree A" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findDifferingNodes(allocator, (try buildNamedTree(allocator, &.{ "file1", "file2", "file3" })).?, (try buildNamedTree(allocator, &.{ "file1", "file2" })).?);
    try expectNodeNames(&.{"file3"}, diff);
}

test "should not find nodes when tree A is subset of tree B" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findDifferingNodes(allocator, (try buildNamedTree(allocator, &.{ "file1", "file2" })).?, (try buildNamedTree(allocator, &.{ "file1", "file2", "file3" })).?);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "should handle when queueB becomes empty first (treeB exhausted)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findDifferingNodes(allocator, (try buildNamedTree(allocator, &.{ "file1", "file2", "file3", "file4" })).?, (try buildNamedTree(allocator, &.{"file1"})).?);
    try expectNames(&.{ "file2", "file3", "file4" }, try diffLeafNames(allocator, diff));
}

test "should handle when queueA becomes empty first (treeA exhausted)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findDifferingNodes(allocator, (try buildNamedTree(allocator, &.{"file1"})).?, (try buildNamedTree(allocator, &.{ "file1", "file2", "file3" })).?);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "should skip identical subtrees via hash matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sharedLeaf = try createNamedLeaf(allocator, "shared");
    const tree1 = try buildMerkleTreeFromLeaves(allocator, &.{ sharedLeaf, try createNamedLeaf(allocator, "unique1") });
    const tree2 = try buildMerkleTreeFromLeaves(allocator, &.{ sharedLeaf, try createNamedLeaf(allocator, "unique2") });
    const diff = try merkle_diff.findDifferingNodes(allocator, tree1.?, tree2.?);
    try expectNodeNames(&.{"unique1"}, diff);
}

test "should handle leaf node requeueing when hash not found initially" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diff = try merkle_diff.findDifferingNodes(allocator, (try buildNamedTree(allocator, &.{"file1"})).?, (try buildNamedTree(allocator, &.{"file2"})).?);
    try expectNodeNames(&.{"file1"}, diff);
}

//
// Creates an invalid internal node with only one child.
//
fn createInvalidNode(allocator: std.mem.Allocator, left: ?*MerkleNode, right: ?*MerkleNode) !*MerkleNode {
    const invalidNode = try allocator.create(MerkleNode);
    invalidNode.* = .{
        .hash = try merkle_verify.sha256(allocator, "invalid"),
        .nodeCount = 2,
        .left = left,
        .right = right,
    };
    return invalidNode;
}

test "should throw error for invalid tree structure - nodeA with left but no right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalidNode = try createInvalidNode(allocator, try createNamedLeaf(allocator, "left"), null);
    const validTree = (try buildNamedTree(allocator, &.{"file1"})).?;
    try std.testing.expectError(error.Thrown, merkle_diff.findDifferingNodes(allocator, invalidNode, validTree));
    try std.testing.expectEqualStrings("Invalid tree structure: nodeA has a left child but no right child", errors.lastErrorMessage());
}

test "should throw error for invalid tree structure - nodeA with right but no left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalidNode = try createInvalidNode(allocator, null, try createNamedLeaf(allocator, "right"));
    const validTree = (try buildNamedTree(allocator, &.{"file1"})).?;
    try std.testing.expectError(error.Thrown, merkle_diff.findDifferingNodes(allocator, invalidNode, validTree));
    try std.testing.expectEqualStrings("Invalid tree structure: nodeA has a right child but no left child", errors.lastErrorMessage());
}

test "should throw error for invalid tree structure - nodeB with left but no right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const validTree = (try buildNamedTree(allocator, &.{"file1"})).?;
    const invalidNode = try createInvalidNode(allocator, try createNamedLeaf(allocator, "left"), null);
    try std.testing.expectError(error.Thrown, merkle_diff.findDifferingNodes(allocator, validTree, invalidNode));
    try std.testing.expectEqualStrings("Invalid tree structure: nodeB has a left child but no right child", errors.lastErrorMessage());
}

test "should throw error for invalid tree structure - nodeB with right but no left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const validTree = (try buildNamedTree(allocator, &.{"file1"})).?;
    const invalidNode = try createInvalidNode(allocator, null, try createNamedLeaf(allocator, "right"));
    try std.testing.expectError(error.Thrown, merkle_diff.findDifferingNodes(allocator, validTree, invalidNode));
    try std.testing.expectEqualStrings("Invalid tree structure: nodeB has a right child but no left child", errors.lastErrorMessage());
}

test "should handle deep trees with multiple levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildNamedTree(allocator, &.{ "a", "b", "c", "d", "e", "f", "g", "h" });
    const tree2 = try buildNamedTree(allocator, &.{ "a", "b", "c", "d", "e", "f", "g", "x" }); // Different last leaf
    const diff = try merkle_diff.findDifferingNodes(allocator, tree1.?, tree2.?);
    try expectNodeNames(&.{"h"}, diff);
}

test "should handle internal nodes with matching hashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createNamedLeaf(allocator, "file1");
    const leaf2 = try createNamedLeaf(allocator, "file2");
    const leaf3 = try createNamedLeaf(allocator, "file3");

    // Tree1: (file1, file2), file3
    const tree1 = try buildMerkleTreeFromLeaves(allocator, &.{ leaf1, leaf2, leaf3 });

    // Tree2: (file1, file2), file4 (shared subtree should match)
    const tree2 = try buildMerkleTreeFromLeaves(allocator, &.{ leaf1, leaf2, try createNamedLeaf(allocator, "file4") });

    const diff = try merkle_diff.findDifferingNodes(allocator, tree1.?, tree2.?);
    try expectNodeNames(&.{"file3"}, diff);
}

//
// Builds a tree from (name, content) pairs.
//
fn buildContentTree(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !?*MerkleNode {
    var leaves: std.ArrayList(*MerkleNode) = .empty;
    for (pairs) |pair| {
        try leaves.append(allocator, try createLeaf(allocator, pair[0], pair[1]));
    }
    return buildMerkleTreeFromLeaves(allocator, leaves.items);
}

test "should correctly identify identical trees when both have duplicate files with same hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const pairs = [_][2][]const u8{ .{ "file1", "same content" }, .{ "file2", "same content" }, .{ "file3", "different content" } };
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, try buildContentTree(allocator, &pairs), try buildContentTree(allocator, &pairs));
    try std.testing.expect(diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should correctly handle when tree1 has 2 duplicates and tree2 has 1 duplicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildContentTree(allocator, &.{ .{ "file1", "same content" }, .{ "file2", "same content" }, .{ "file3", "other content" } });
    const tree2 = try buildContentTree(allocator, &.{ .{ "file1", "same content" }, .{ "file3", "other content" } });
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    try std.testing.expect(containsName(try diffLeafNames(allocator, diff.onlyInTree1), "file2"));
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should correctly handle when tree1 has 1 duplicate and tree2 has 2 duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildContentTree(allocator, &.{ .{ "file1", "same content" }, .{ "file3", "other content" } });
    const tree2 = try buildContentTree(allocator, &.{ .{ "file1", "same content" }, .{ "file2", "same content" }, .{ "file3", "other content" } });
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    try std.testing.expect(containsName(try diffLeafNames(allocator, diff.onlyInTree2), "file2"));
}

test "should correctly handle two sets of duplicate files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildContentTree(allocator, &.{ .{ "file1", "content A" }, .{ "file2", "content A" }, .{ "file3", "content B" }, .{ "file4", "content B" }, .{ "file5", "unique content" } });
    const tree2 = try buildContentTree(allocator, &.{ .{ "file1", "content A" }, .{ "file3", "content B" }, .{ "file5", "unique content" } });
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    const onlyInTree1Names = try diffLeafNames(allocator, diff.onlyInTree1);
    try std.testing.expect(containsName(onlyInTree1Names, "file2"));
    try std.testing.expect(containsName(onlyInTree1Names, "file4"));
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree2.len);
}

test "should correctly handle two sets of duplicate files - reverse case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildContentTree(allocator, &.{ .{ "file1", "content A" }, .{ "file3", "content B" }, .{ "file5", "unique content" } });
    const tree2 = try buildContentTree(allocator, &.{ .{ "file1", "content A" }, .{ "file2", "content A" }, .{ "file3", "content B" }, .{ "file4", "content B" }, .{ "file5", "unique content" } });
    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    try std.testing.expectEqual(@as(usize, 0), diff.onlyInTree1.len);
    const onlyInTree2Names = try diffLeafNames(allocator, diff.onlyInTree2);
    try std.testing.expect(containsName(onlyInTree2Names, "file2"));
    try std.testing.expect(containsName(onlyInTree2Names, "file4"));
}

test "should correctly handle mixed duplicate scenarios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Tree 1: Has 2x A, 1x B, 3x C
    const tree1 = try buildContentTree(allocator, &.{ .{ "file1", "content A" }, .{ "file2", "content A" }, .{ "file3", "content B" }, .{ "file4", "content C" }, .{ "file5", "content C" }, .{ "file6", "content C" } });

    // Tree 2: Has 1x A, 2x B, 2x C
    const tree2 = try buildContentTree(allocator, &.{ .{ "file1", "content A" }, .{ "file3", "content B" }, .{ "file7", "content B" }, .{ "file4", "content C" }, .{ "file5", "content C" } });

    const diff = try merkle_diff.findMerkleTreeDifferences(allocator, tree1, tree2);
    try std.testing.expect(!diff.identical);
    const onlyInTree1Names = try diffLeafNames(allocator, diff.onlyInTree1);
    const onlyInTree2Names = try diffLeafNames(allocator, diff.onlyInTree2);
    try std.testing.expect(containsName(onlyInTree1Names, "file2"));
    try std.testing.expect(containsName(onlyInTree1Names, "file6"));
    try std.testing.expect(containsName(onlyInTree2Names, "file7"));
}

test "should handle empty nodes array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var mapB = BufferMap(u64).init(allocator);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{}, &mapB, &onlyInTree1);
    try std.testing.expectEqual(@as(usize, 0), onlyInTree1.items.len);
}

test "should add leaf node when hash not in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leafNode = try createNamedLeaf(allocator, "file1");
    var mapB = BufferMap(u64).init(allocator);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{leafNode}, &mapB, &onlyInTree1);
    try std.testing.expectEqual(@as(usize, 1), onlyInTree1.items.len);
    try std.testing.expectEqual(leafNode, onlyInTree1.items[0]);
}

test "should add leaf node when count is zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leafNode = try createNamedLeaf(allocator, "file1");
    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(leafNode.hash, 0); // Count is zero
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{leafNode}, &mapB, &onlyInTree1);
    try std.testing.expectEqual(@as(usize, 1), onlyInTree1.items.len);
    try std.testing.expectEqual(leafNode, onlyInTree1.items[0]);
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leafNode.hash)); // Count remains zero
}

test "should decrement count and not add leaf when hash matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leafNode = try createNamedLeaf(allocator, "file1");
    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(leafNode.hash, 2); // Count is 2
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{leafNode}, &mapB, &onlyInTree1);
    try std.testing.expectEqual(@as(usize, 0), onlyInTree1.items.len);
    try std.testing.expectEqual(@as(?u64, 1), try mapB.get(leafNode.hash)); // Count decremented
}

test "should handle multiple leaf nodes with same hash (duplicates)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createLeaf(allocator, "file1", "same content");
    const leaf2 = try createLeaf(allocator, "file2", "same content"); // Same hash as leaf1
    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(leaf1.hash, 2); // Two matches available
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{ leaf1, leaf2 }, &mapB, &onlyInTree1);
    try std.testing.expectEqual(@as(usize, 0), onlyInTree1.items.len);
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf1.hash)); // Both matched
}

test "should handle leaf nodes with partial duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createLeaf(allocator, "file1", "same content");
    const leaf2 = try createLeaf(allocator, "file2", "same content");
    const leaf3 = try createLeaf(allocator, "file3", "same content");
    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(leaf1.hash, 2); // Only 2 matches available
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{ leaf1, leaf2, leaf3 }, &mapB, &onlyInTree1);

    // First two should match, third should be added
    try std.testing.expectEqual(@as(usize, 1), onlyInTree1.items.len);
    try std.testing.expectEqual(leaf3, onlyInTree1.items[0]);
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf1.hash)); // Both matches used
}

test "should skip internal node when hash matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const internal = try createInternal(allocator, try createNamedLeaf(allocator, "file1"), try createNamedLeaf(allocator, "file2"));
    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(internal.hash, 1); // Internal node hash matches
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{internal}, &mapB, &onlyInTree1);

    // Should skip children and not add anything
    try std.testing.expectEqual(@as(usize, 0), onlyInTree1.items.len);
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(internal.hash)); // Count decremented
}

test "should expand internal node when hash does not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createNamedLeaf(allocator, "file1");
    const internal = try createInternal(allocator, leaf1, try createNamedLeaf(allocator, "file2"));
    var mapB = BufferMap(u64).init(allocator);

    // Internal hash not in map, but leaf1 is
    _ = try mapB.set(leaf1.hash, 1);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{internal}, &mapB, &onlyInTree1);

    // leaf1 matches, leaf2 doesn't
    try expectNodeNames(&.{"file2"}, onlyInTree1.items);
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf1.hash)); // leaf1 matched
}

test "should recursively expand nested internal nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createNamedLeaf(allocator, "file1");
    const leaf2 = try createNamedLeaf(allocator, "file2");
    const leaf3 = try createNamedLeaf(allocator, "file3");
    const leaf4 = try createNamedLeaf(allocator, "file4");

    // Build nested structure: ((file1, file2), (file3, file4))
    const root = try createInternal(allocator, try createInternal(allocator, leaf1, leaf2), try createInternal(allocator, leaf3, leaf4));

    var mapB = BufferMap(u64).init(allocator);

    // Only leaf1 and leaf3 are in mapB
    _ = try mapB.set(leaf1.hash, 1);
    _ = try mapB.set(leaf3.hash, 1);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{root}, &mapB, &onlyInTree1);

    // Should recursively expand and find leaf2 and leaf4
    try expectNames(&.{ "file2", "file4" }, try diffLeafNames(allocator, onlyInTree1.items));
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf1.hash));
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf3.hash));
}

test "should handle mixed leaf and internal nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createNamedLeaf(allocator, "file1");
    const leaf2 = try createNamedLeaf(allocator, "file2");
    const leaf3 = try createNamedLeaf(allocator, "file3");
    const internal = try createInternal(allocator, leaf2, leaf3);

    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(leaf1.hash, 1); // leaf1 matches
    _ = try mapB.set(leaf2.hash, 1); // leaf2 matches

    // leaf3 and internal don't match
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{ leaf1, internal }, &mapB, &onlyInTree1);

    try expectNodeNames(&.{"file3"}, onlyInTree1.items);
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf1.hash));
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf2.hash));
}

test "should throw error for invalid tree structure - left child but no right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalidInternal = try createInvalidNode(allocator, try createNamedLeaf(allocator, "file1"), null);
    var mapB = BufferMap(u64).init(allocator);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try std.testing.expectError(error.Thrown, merkle_diff.processRemainingNodes(allocator, &.{invalidInternal}, &mapB, &onlyInTree1));
    try std.testing.expectEqualStrings("Invalid tree structure: nodeA has a left child but no right child", errors.lastErrorMessage());
}

test "should throw error for invalid tree structure - right child but no left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalidInternal = try createInvalidNode(allocator, null, try createNamedLeaf(allocator, "file1"));
    var mapB = BufferMap(u64).init(allocator);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try std.testing.expectError(error.Thrown, merkle_diff.processRemainingNodes(allocator, &.{invalidInternal}, &mapB, &onlyInTree1));
    try std.testing.expectEqualStrings("Invalid tree structure: nodeA has a right child but no left child", errors.lastErrorMessage());
}

test "should handle internal node with no children (edge case)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalidInternal = try createInvalidNode(allocator, null, null); // Claims to be internal but has no children
    var mapB = BufferMap(u64).init(allocator);
    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{invalidInternal}, &mapB, &onlyInTree1);

    // Should handle gracefully and add to onlyInTree1
    try std.testing.expectEqual(@as(usize, 1), onlyInTree1.items.len);
    try std.testing.expectEqual(invalidInternal, onlyInTree1.items[0]);
}

test "should handle complex scenario with multiple internal nodes and duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createLeaf(allocator, "file1", "duplicate");
    const leaf2 = try createLeaf(allocator, "file2", "duplicate"); // Same hash as leaf1
    const leaf3 = try createNamedLeaf(allocator, "file3");
    const leaf4 = try createNamedLeaf(allocator, "file4");
    const internal1 = try createInternal(allocator, leaf1, leaf2);
    const internal2 = try createInternal(allocator, leaf3, leaf4);

    var mapB = BufferMap(u64).init(allocator);
    _ = try mapB.set(leaf1.hash, 1); // One duplicate match available
    _ = try mapB.set(leaf3.hash, 1); // leaf3 matches

    var onlyInTree1: std.ArrayList(*MerkleNode) = .empty;
    try merkle_diff.processRemainingNodes(allocator, &.{ internal1, internal2 }, &mapB, &onlyInTree1);

    try expectNames(&.{ "file2", "file4" }, try diffLeafNames(allocator, onlyInTree1.items));
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf1.hash));
    try std.testing.expectEqual(@as(?u64, 0), try mapB.get(leaf3.hash));
}

test "should correctly handle merged map with both leaf and internal node hashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf1 = try createNamedLeaf(allocator, "file1");
    const leaf2 = try createNamedLeaf(allocator, "file2");
    const leaf3 = try createNamedLeaf(allocator, "file3");
    const leaf4 = try createNamedLeaf(allocator, "file4");

    // Tree1 has all 4 files
    const tree1 = try buildMerkleTreeFromLeaves(allocator, &.{ leaf1, leaf2, leaf3, leaf4 });

    // Tree2 has only file1 and file2
    const tree2 = try buildMerkleTreeFromLeaves(allocator, &.{ leaf1, leaf2 });

    const diffNames = try diffLeafNames(allocator, try merkle_diff.findDifferingNodes(allocator, tree1.?, tree2.?));
    try std.testing.expect(containsName(diffNames, "file3"));
    try std.testing.expect(containsName(diffNames, "file4"));
    try std.testing.expect(!containsName(diffNames, "file1"));
    try std.testing.expect(!containsName(diffNames, "file2"));
}

test "should handle large trees with many duplicates using merged map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree1 = try buildContentTree(allocator, &.{ .{ "file1", "duplicate" }, .{ "file2", "duplicate" }, .{ "file3", "duplicate" }, .{ "file4", "duplicate" }, .{ "file5", "unique" }, .{ "file6", "unique" } });
    const tree2 = try buildContentTree(allocator, &.{ .{ "file1", "duplicate" }, .{ "file2", "duplicate" }, .{ "file5", "unique" } });
    const diffNames = try diffLeafNames(allocator, try merkle_diff.findDifferingNodes(allocator, tree1.?, tree2.?));
    try std.testing.expect(containsName(diffNames, "file3"));
    try std.testing.expect(containsName(diffNames, "file4"));
    try std.testing.expect(containsName(diffNames, "file6"));
    try std.testing.expect(!containsName(diffNames, "file1"));
    try std.testing.expect(!containsName(diffNames, "file2"));
    try std.testing.expect(!containsName(diffNames, "file5"));
}

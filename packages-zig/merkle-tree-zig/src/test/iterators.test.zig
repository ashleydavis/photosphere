//
// Tests for iterateNodes and iterateLeaves (port of src/test/iterators.test.ts).
// (Zig: test names are prefixed with the describe name.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const SortNode = merkle_tree.SortNode;
const buildTree = merkle_verify.buildTree;
const leaf = merkle_verify.leaf;
const node = merkle_verify.node;

//
// Collects every node iterateLeaves yields.
//
fn allLeaves(allocator: std.mem.Allocator, root: ?*SortNode) ![]const *SortNode {
    var nodes: std.ArrayList(*SortNode) = .empty;
    var iterator = merkle_tree.iterateLeaves(SortNode, allocator, root);
    while (try iterator.next()) |current| {
        try nodes.append(allocator, current);
    }
    return nodes.items;
}

//
// Collects every node iterateNodes yields.
//
fn allNodes(allocator: std.mem.Allocator, root: ?*SortNode) ![]const *SortNode {
    var nodes: std.ArrayList(*SortNode) = .empty;
    var iterator = merkle_tree.iterateNodes(SortNode, allocator, root);
    while (try iterator.next()) |current| {
        try nodes.append(allocator, current);
    }
    return nodes.items;
}

//
// The names of the nodes that have a name.
//
fn namesOf(allocator: std.mem.Allocator, nodes: []const *SortNode) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (nodes) |current| {
        if (current.name) |name| {
            try names.append(allocator, name);
        }
    }
    return names.items;
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

//
// Names like `file_000` (TypeScript: `file_${i.toString().padStart(3, '0')}`).
//
fn paddedFileNames(allocator: std.mem.Allocator, count: usize, width: usize) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, count);
    for (names, 0..) |*name, index| {
        const digits = try std.fmt.allocPrint(allocator, "{d}", .{index});
        const padding = try allocator.alloc(u8, width -| digits.len);
        @memset(padding, '0');
        name.* = try std.fmt.allocPrint(allocator, "file_{s}{s}", .{ padding, digits });
    }
    return names;
}

test "iterateNodes: returns nothing for undefined node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try allNodes(arena.allocator(), null)).len);
}

test "iterateNodes: iterates single leaf node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const nodes = try allNodes(allocator, try leaf(allocator, "A", 100));
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqualStrings("A", nodes[0].name.?);
    try std.testing.expectEqualStrings("A", nodes[0].contentHash.?);
}

test "iterateNodes: iterates two leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const nodes = try allNodes(allocator, try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100)));

    // Should return parent node, then left child, then right child
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqualStrings("A", nodes[0].minName); // Parent node
    try std.testing.expectEqualStrings("A", nodes[1].name.?); // Left leaf
    try std.testing.expectEqualStrings("B", nodes[2].name.?); // Right leaf
}

test "iterateNodes: performs pre-order traversal (parent, left, right)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build tree: ((A, B), C)
    const sortTree = try node(
        allocator,
        try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100)),
        try leaf(allocator, "C", 100),
    );
    const nodes = try allNodes(allocator, sortTree);

    // Pre-order: root, left subtree (parent, A, B), right (C)
    try std.testing.expectEqual(@as(usize, 5), nodes.len);

    // First node is root
    try std.testing.expectEqualStrings("A", nodes[0].minName);
    try std.testing.expectEqual(@as(u32, 5), nodes[0].nodeCount);

    // Second node is left child (parent of A and B)
    try std.testing.expectEqualStrings("A", nodes[1].minName);
    try std.testing.expectEqual(@as(u32, 3), nodes[1].nodeCount);

    // Third node is leaf A
    try std.testing.expectEqualStrings("A", nodes[2].name.?);

    // Fourth node is leaf B
    try std.testing.expectEqualStrings("B", nodes[3].name.?);

    // Fifth node is leaf C
    try std.testing.expectEqualStrings("C", nodes[4].name.?);
}

test "iterateNodes: visits all nodes in correct order for balanced tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build tree with 4 leaves: ((A, B), (C, D))
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    const nodes = try allNodes(allocator, tree.sort);

    // Should have 7 nodes total: 1 root + 2 internal + 4 leaves
    try std.testing.expectEqual(@as(usize, 7), nodes.len);

    // Verify all nodes are present
    const leafNames = try namesOf(allocator, nodes);
    try std.testing.expectEqual(@as(usize, 4), leafNames.len);
    try expectNames(&.{ "A", "B", "C", "D" }, leafNames);
}

test "iterateNodes: counts all nodes correctly for small tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });

    // Tree structure: ((A, B), C) = 5 nodes total
    try std.testing.expectEqual(@as(usize, 5), (try allNodes(allocator, tree.sort)).len);
}

test "iterateNodes: counts all nodes correctly for power of 2 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G", "H" });

    // For 8 leaves in a binary tree, we have 15 total nodes (8 leaves + 7 internal)
    try std.testing.expectEqual(@as(usize, 15), (try allNodes(allocator, tree.sort)).len);
}

test "iterateNodes: counts all nodes correctly for non-power of 2 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });

    // For 5 leaves, we should have 9 total nodes
    try std.testing.expectEqual(@as(usize, 9), (try allNodes(allocator, tree.sort)).len);
}

test "iterateNodes: all nodes have valid nodeCount property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F" });
    for (try allNodes(allocator, tree.sort)) |current| {
        try std.testing.expect(current.nodeCount >= 1);
    }
}

test "iterateNodes: all nodes have valid minFileName property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    for (try allNodes(allocator, tree.sort)) |current| {
        try std.testing.expect(current.minName.len > 0);
    }
}

test "iterateNodes: leaf nodes have name property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    const nodes = try allNodes(allocator, tree.sort);

    var leafCount: usize = 0;
    for (nodes) |current| {
        if (current.name != null) {
            leafCount += 1;
            try std.testing.expect(current.contentHash != null);
            try std.testing.expectEqual(@as(u32, 1), current.nodeCount);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), leafCount);
}

test "iterateNodes: iterates large tree with 100 nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fileNames = try paddedFileNames(allocator, 100, 3);
    const tree = try buildTree(allocator, fileNames);
    const nodes = try allNodes(allocator, tree.sort);

    // Should have all nodes
    try std.testing.expect(nodes.len >= 100);

    // All 100 files should be present
    try std.testing.expectEqual(@as(usize, 100), (try namesOf(allocator, nodes)).len);
}

test "iterateNodes: can be used in for...of loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    var nodeNames: std.ArrayList([]const u8) = .empty;
    var iterator = merkle_tree.iterateNodes(SortNode, allocator, tree.sort);
    while (try iterator.next()) |current| {
        try nodeNames.append(allocator, current.minName);
    }
    try std.testing.expect(nodeNames.items.len > 0);
}

test "iterateNodes: can be converted to array multiple times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    const nodes1 = try allNodes(allocator, tree.sort);
    const nodes2 = try allNodes(allocator, tree.sort);
    try std.testing.expectEqual(nodes1.len, nodes2.len);
}

test "iterateNodes: is lazy and does not iterate until consumed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });

    // Creating the generator should not iterate
    var iterator = merkle_tree.iterateNodes(SortNode, allocator, tree.sort);
    try std.testing.expectEqual(@as(usize, 0), iterator.stack.items.len);

    // Only when we consume it does it iterate
    const firstNode = try iterator.next();
    try std.testing.expect(firstNode != null);
}

test "iterateLeaves: returns nothing for undefined node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try allLeaves(arena.allocator(), null)).len);
}

test "iterateLeaves: iterates single leaf node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaves = try allLeaves(allocator, try leaf(allocator, "A", 100));
    try std.testing.expectEqual(@as(usize, 1), leaves.len);
    try std.testing.expectEqualStrings("A", leaves[0].name.?);
    try std.testing.expectEqualStrings("A", leaves[0].contentHash.?);
}

test "iterateLeaves: iterates two leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaves = try allLeaves(allocator, try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100)));
    try expectNames(&.{ "A", "B" }, try namesOf(allocator, leaves));
}

test "iterateLeaves: only returns leaf nodes, not internal nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    const leaves = try allLeaves(allocator, tree.sort);
    try std.testing.expectEqual(@as(usize, 4), leaves.len);
    for (leaves) |current| {
        try std.testing.expect(current.name != null);
        try std.testing.expect(current.contentHash != null);
        try std.testing.expectEqual(@as(u32, 1), current.nodeCount);
    }
}

test "iterateLeaves: does not return parent nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    const leaves = try allLeaves(allocator, tree.sort);
    const allNodeList = try allNodes(allocator, tree.sort);
    try std.testing.expect(leaves.len < allNodeList.len);
    try std.testing.expect(leaves.len < tree.sort.?.nodeCount);
    try std.testing.expectEqual(@as(usize, 5), leaves.len);
}

test "iterateLeaves: preserves in-order traversal of leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    try expectNames(&.{ "A", "B", "C", "D" }, try namesOf(allocator, try allLeaves(allocator, tree.sort)));
}

test "iterateLeaves: maintains sorted order for unsorted input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "D", "A", "C", "B", "E" });
    try expectNames(&.{ "A", "B", "C", "D", "E" }, try namesOf(allocator, try allLeaves(allocator, tree.sort)));
}

test "iterateLeaves: maintains order with UUID filenames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fileNames = [_][]const u8{
        "asset/3e4f1677-dfc1-4efe-be57-6969e0b1c9b6",
        "asset/7b4f6865-26a5-4316-98ba-41e528594ec0",
        "asset/7c86cb29-c6ee-40dc-9d08-a8dc5c5a0dc7",
    };
    const tree = try buildTree(allocator, &fileNames);
    try expectNames(&fileNames, try namesOf(allocator, try allLeaves(allocator, tree.sort)));
}

test "iterateLeaves: counts leaves correctly for power of 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G", "H" });
    try std.testing.expectEqual(@as(usize, 8), (try allLeaves(allocator, tree.sort)).len);
}

test "iterateLeaves: counts leaves correctly for non-power of 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G" });
    try std.testing.expectEqual(@as(usize, 7), (try allLeaves(allocator, tree.sort)).len);
}

test "iterateLeaves: leaf count matches tree leafCount property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F" });
    try std.testing.expectEqual(@as(usize, tree.sort.?.leafCount), (try allLeaves(allocator, tree.sort)).len);
}

test "iterateLeaves: all leaves have contentHash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    for (try allLeaves(allocator, tree.sort)) |current| {
        try std.testing.expect(current.contentHash != null);
    }
}

test "iterateLeaves: all leaves have name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    for (try allLeaves(allocator, tree.sort)) |current| {
        try std.testing.expect(current.name != null);
    }
}

test "iterateLeaves: all leaves have nodeCount of 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    for (try allLeaves(allocator, tree.sort)) |current| {
        try std.testing.expectEqual(@as(u32, 1), current.nodeCount);
    }
}

test "iterateLeaves: all leaves have leafCount of 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    for (try allLeaves(allocator, tree.sort)) |current| {
        try std.testing.expectEqual(@as(u32, 1), current.leafCount);
    }
}

test "iterateLeaves: all leaves have no children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    for (try allLeaves(allocator, tree.sort)) |current| {
        try std.testing.expect(current.left == null);
        try std.testing.expect(current.right == null);
    }
}

test "iterateLeaves: iterates 100 leaves efficiently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fileNames = try paddedFileNames(allocator, 100, 3);
    const tree = try buildTree(allocator, fileNames);
    try expectNames(fileNames, try namesOf(allocator, try allLeaves(allocator, tree.sort)));
}

test "iterateLeaves: iterates 1000 leaves efficiently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, try paddedFileNames(allocator, 1000, 4));
    try std.testing.expectEqual(@as(usize, 1000), (try allLeaves(allocator, tree.sort)).len);
}

test "iterateLeaves: can be used in for...of loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    try expectNames(&.{ "A", "B", "C" }, try namesOf(allocator, try allLeaves(allocator, tree.sort)));
}

test "iterateLeaves: can be converted to array multiple times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    const leaves1 = try namesOf(allocator, try allLeaves(allocator, tree.sort));
    const leaves2 = try namesOf(allocator, try allLeaves(allocator, tree.sort));
    try expectNames(leaves1, leaves2);
}

test "iterateLeaves: is lazy and does not iterate until consumed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    var iterator = merkle_tree.iterateLeaves(SortNode, allocator, tree.sort);
    try std.testing.expectEqual(@as(usize, 0), iterator.stack.items.len);
    const firstLeaf = try iterator.next();
    try std.testing.expectEqualStrings("A", firstLeaf.?.name.?);
}

test "iterateLeaves: can be partially consumed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    var iterator = merkle_tree.iterateLeaves(SortNode, allocator, tree.sort);

    // Consume first 3 leaves
    try std.testing.expectEqualStrings("A", (try iterator.next()).?.name.?);
    try std.testing.expectEqualStrings("B", (try iterator.next()).?.name.?);
    try std.testing.expectEqualStrings("C", (try iterator.next()).?.name.?);

    // Can still get remaining leaves
    try std.testing.expectEqualStrings("D", (try iterator.next()).?.name.?);
    try std.testing.expectEqualStrings("E", (try iterator.next()).?.name.?);
    try std.testing.expect((try iterator.next()) == null);
}

//
// Collects leaves by manual recursion (like the existing tests).
//
fn collectLeaves(allocator: std.mem.Allocator, leaves: *std.ArrayList(*SortNode), sortNode: ?*SortNode) !void {
    const currentNode = sortNode orelse {
        return;
    };
    if (currentNode.left == null and currentNode.right == null) {
        try leaves.append(allocator, currentNode);
    }
    else {
        try collectLeaves(allocator, leaves, currentNode.left);
        try collectLeaves(allocator, leaves, currentNode.right);
    }
}

test "iterateLeaves: produces same results as manual recursive collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F" });

    var manualLeaves: std.ArrayList(*SortNode) = .empty;
    try collectLeaves(allocator, &manualLeaves, tree.sort);
    const iteratorLeaves = try allLeaves(allocator, tree.sort);
    try expectNames(try namesOf(allocator, manualLeaves.items), try namesOf(allocator, iteratorLeaves));
}

test "iterateLeaves: handles nodes with only left child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leftLeaf = try leaf(allocator, "A", 100);
    var parent: SortNode = .{ .nodeCount = 2, .leafCount = 1, .size = leftLeaf.size, .minName = "A", .left = leftLeaf };
    try expectNames(&.{"A"}, try namesOf(allocator, try allLeaves(allocator, &parent)));
}

test "iterateLeaves: handles nodes with only right child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rightLeaf = try leaf(allocator, "B", 100);
    var parent: SortNode = .{ .nodeCount = 2, .leafCount = 1, .size = rightLeaf.size, .minName = "B", .right = rightLeaf };
    try expectNames(&.{"B"}, try namesOf(allocator, try allLeaves(allocator, &parent)));
}

test "iterateNodes vs iterateLeaves: iterateNodes returns more nodes than iterateLeaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });

    const nodes = try allNodes(allocator, tree.sort);
    const leaves = try allLeaves(allocator, tree.sort);

    try std.testing.expect(nodes.len > leaves.len);
}

test "iterateNodes vs iterateLeaves: all leaves from iterateLeaves are present in iterateNodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });

    const nodes = try allNodes(allocator, tree.sort);
    const leaves = try allLeaves(allocator, tree.sort);

    try expectNames(try namesOf(allocator, leaves), try namesOf(allocator, nodes));
}

test "iterateNodes vs iterateLeaves: difference in count equals number of internal nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G", "H" });

    const nodes = try allNodes(allocator, tree.sort);
    const leaves = try allLeaves(allocator, tree.sort);

    const internalNodeCount = nodes.len - leaves.len;

    // For a binary tree with n leaves, we have n-1 internal nodes
    // (but this can vary based on tree structure)
    try std.testing.expect(internalNodeCount > 0);
    try std.testing.expect(internalNodeCount < leaves.len);
}

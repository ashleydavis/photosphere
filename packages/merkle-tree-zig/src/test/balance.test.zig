//
// Tests for rotateRight, rotateLeft and rebalanceTree (port of src/test/balance.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const leaf = merkle_verify.leaf;
const node = merkle_verify.node;
const expectNode = merkle_verify.expectNode;

test "right rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // Before rotation:
    //     A
    //    / \
    //   B   D
    //  / \
    // C   E
    //
    // After rotation:
    //     B
    //    / \
    //   C   A
    //      / \
    //     E   D
    //
    const nodeC = try leaf(allocator, "C", 100);
    const nodeE = try leaf(allocator, "E", 200);
    const nodeD = try leaf(allocator, "D", 300);
    const nodeB = try node(allocator, nodeC, nodeE);
    const nodeA = try node(allocator, nodeB, nodeD);

    const result = try merkle_tree.rotateRight(allocator, nodeA);
    try expectNode(allocator, result, "(C,(E,D))");
}

test "left rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // Before rotation:
    //     A
    //    / \
    //   B   C
    //      / \
    //     D   E
    //
    // After rotation:
    //     C
    //    / \
    //   A   E
    //  / \
    // B   D
    //
    const nodeB = try leaf(allocator, "B", 100);
    const nodeD = try leaf(allocator, "D", 200);
    const nodeE = try leaf(allocator, "E", 300);
    const nodeC = try node(allocator, nodeD, nodeE);
    const nodeA = try node(allocator, nodeB, nodeC);

    const result = try merkle_tree.rotateLeft(allocator, nodeA);
    try expectNode(allocator, result, "((B,D),E)");
}

test "simple balanced tree requires no rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodeC = try leaf(allocator, "C", 100);
    const nodeB = try leaf(allocator, "B", 100);
    const nodeA = try node(allocator, nodeB, nodeC);

    const result = try merkle_tree.rebalanceTree(allocator, nodeA);
    try std.testing.expectEqual(nodeA, result);
    try expectNode(allocator, result, "(B,C)");
}

test "slightly left heavy tree requires no rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodeE = try leaf(allocator, "E", 100);
    const nodeD = try leaf(allocator, "D", 100);
    const nodeC = try leaf(allocator, "C", 100);
    const nodeB = try node(allocator, nodeC, nodeD);
    const nodeA = try node(allocator, nodeB, nodeE);

    const result = try merkle_tree.rebalanceTree(allocator, nodeA);
    try expectNode(allocator, result, "((C,D),E)");
}

test "slightly right heavy tree requires rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodeB = try leaf(allocator, "B", 100);
    const nodeD = try leaf(allocator, "D", 100);
    const nodeE = try leaf(allocator, "E", 100);
    const nodeC = try node(allocator, nodeD, nodeE);
    const nodeA = try node(allocator, nodeB, nodeC);

    const result = try merkle_tree.rebalanceTree(allocator, nodeA);
    try expectNode(allocator, result, "((B,D),E)");
}

test "left heavy tree requires right rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodeF = try leaf(allocator, "F", 100);
    const nodeG = try leaf(allocator, "G", 100);
    const nodeD = try node(allocator, nodeF, nodeG);
    const nodeE = try leaf(allocator, "E", 100);
    const nodeB = try node(allocator, nodeD, nodeE);
    const nodeC = try leaf(allocator, "C", 100);
    const nodeA = try node(allocator, nodeB, nodeC);

    const result = try merkle_tree.rebalanceTree(allocator, nodeA);

    // Verify the structure after rebalancing
    try expectNode(allocator, result, "((F,G),(E,C))");
}

test "right heavy tree requires left rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodeB = try leaf(allocator, "B", 100);
    const nodeD = try leaf(allocator, "D", 100);
    const nodeF = try leaf(allocator, "F", 100);
    const nodeG = try leaf(allocator, "G", 100);
    const nodeE = try node(allocator, nodeF, nodeG);
    const nodeC = try node(allocator, nodeD, nodeE);
    const nodeA = try node(allocator, nodeB, nodeC);

    const result = try merkle_tree.rebalanceTree(allocator, nodeA);

    // Verify the structure after rebalancing
    try expectNode(allocator, result, "((B,D),(F,G))");
}

test "rebalanceTree throws for a node without children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lonely = try leaf(allocator, "A", 100);
    try std.testing.expectError(error.Thrown, merkle_tree.rebalanceTree(allocator, lonely));
    try std.testing.expectError(error.Thrown, merkle_tree.rotateLeft(allocator, lonely));
    try std.testing.expectError(error.Thrown, merkle_tree.rotateRight(allocator, lonely));
}

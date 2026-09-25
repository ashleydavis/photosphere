//
// Tests for addItem and updateItem (port of src/test/merkle.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const errors = @import("utils-zig").errors;
const merkle_tree = merkle_tree_zig.merkle_tree;
const HashedItem = merkle_tree.HashedItem;
const createHashedItem = merkle_verify.createHashedItem;
const expectTree = merkle_verify.expectTree;
const buildTree = merkle_verify.buildTree;

//
// Builds a tree from the given names, adds one more name and checks the resulting shape.
//
fn expectShapeAfterAdding(existingNames: []const []const u8, addedName: []const u8, expectedShape: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, existingNames);
    const updatedTree = try merkle_tree.addItem(allocator, &tree, createHashedItem(addedName));
    try expectTree(allocator, &updatedTree, expectedShape);
}

test "creates a new tree with a single file" {
    try expectShapeAfterAdding(&.{}, "A", "A");
}

test "adds a second file to an existing tree" {
    try expectShapeAfterAdding(&.{"A"}, "B", "(A,B)");
}

test "adds a third file to an existing tree" {
    try expectShapeAfterAdding(&.{ "A", "B" }, "C", "((A,B),C)");
}

test "adds a fourth file to an existing tree (balanced approach)" {
    try expectShapeAfterAdding(&.{ "A", "B", "C" }, "D", "((A,B),(C,D))");
}

test "adds a fifth file to an existing tree (balanced approach)" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D" }, "E", "(((A,B),C),(D,E))");
}

test "adds a sixth file to an existing tree (balanced approach)" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D", "E" }, "F", "(((A,B),C),((D,E),F))");
}

test "adds a seventh file to an existing tree (balanced approach)" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D", "E", "F" }, "G", "((((A,B),C),(D,E)),(F,G))");
}

test "adds an eighth file to an existing tree (perfectly balanced)" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D", "E", "F", "G" }, "H", "(((A,B),C),((D,E),((F,G),H)))");
}

test "adds a ninth file to create a balanced binary merkle tree" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D", "E", "F", "G", "H" }, "I", "((((A,B),C),(D,E)),((F,G),(H,I)))");
}

test "adds a tenth file to create a balanced binary merkle tree" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D", "E", "F", "G", "H", "I" }, "J", "((((A,B),C),(D,E)),(((F,G),H),(I,J)))");
}

test "adds an eleventh file to create a balanced binary merkle tree" {
    try expectShapeAfterAdding(&.{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" }, "K", "(((((A,B),C),(D,E)),((F,G),H)),((I,J),K))");
}

//
// Helper function to create a modified file hash with different content
//
fn createModifiedHashedItem(name: []const u8, content: []const u8) HashedItem {
    return .{
        .name = name,
        .hash = content,
        .length = 200 * @as(u64, name[0]), // Different size than original
        .lastModified = merkle_verify.TEST_TIMESTAMP,
    };
}

test "finds a file node by name in the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a tree with files A through E
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });

    // Find node with file C
    const nodeC = merkle_tree.findItemInTree(tree.sort, "C");

    // Verify it's the correct node
    try std.testing.expect(nodeC != null);
    try std.testing.expectEqualStrings("C", nodeC.?.contentHash.?);
    try std.testing.expectEqual(@as(u32, 1), nodeC.?.nodeCount);
}

test "returns undefined when file is not found in the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a tree with files A through E
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });

    // Try to find a non-existent file
    const nodeZ = merkle_tree.findItemInTree(tree.sort, "Z");

    // Verify it returns undefined
    try std.testing.expect(nodeZ == null);
}

test "updates a file in a small tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a tree with files A, B, C
    var tree = try buildTree(allocator, &.{ "A", "B", "C" });

    // Create modified version of file B
    const modifiedB = createModifiedHashedItem("B", "B_modified");

    // Update file B in the tree
    const updated = try merkle_tree.updateItem(&tree, modifiedB);
    try std.testing.expect(updated); // Ensure the update was successful.

    const nodeB = merkle_tree.findItemInTree(tree.sort, "B"); // Verify B is still in the tree.
    try std.testing.expect(nodeB != null);
    try std.testing.expectEqualStrings(modifiedB.hash, nodeB.?.contentHash.?); // Hash should have been updated.

    // Verify the tree structure on the new hash.
    try expectTree(allocator, &tree, "((A,B),C)");
}

test "updates a file in a larger balanced tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a tree with files A through G
    var tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G" });

    // Create modified version of file E
    const modifiedE = createModifiedHashedItem("E", "E_modified");

    // Update file E in the tree
    const updated = try merkle_tree.updateItem(&tree, modifiedE);
    try std.testing.expect(updated); // Ensure the update was successful.

    const nodeE = merkle_tree.findItemInTree(tree.sort, "E"); // Verify E is still in the tree.
    try std.testing.expect(nodeE != null);
    try std.testing.expectEqualStrings(modifiedE.hash, nodeE.?.contentHash.?); // Hash should have been updated.

    // Verify the tree structure on the new hash.
    try expectTree(allocator, &tree, "((((A,B),C),(D,E)),(F,G))");
}

test "expect no update for a non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a tree with files A through E.
    var tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });

    // Create a hash for a file that doesn't exist in the tree.
    const nonExistentFile = createHashedItem("Z");

    const updated = try merkle_tree.updateItem(&tree, nonExistentFile);
    try std.testing.expect(!updated); // Ensure no update was made.
}

test "maintains tree structure after file update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a tree with files A through J
    var originalTree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" });

    // Create modified version of file D
    const modifiedD = createModifiedHashedItem("D", "D_modified");

    // Update file D in the tree
    const updated = try merkle_tree.updateItem(&originalTree, modifiedD);
    try std.testing.expect(updated); // Ensure the update was successful.

    const nodeD = merkle_tree.findItemInTree(originalTree.sort, "D"); // Verify D is still in the tree.
    try std.testing.expect(nodeD != null);
    try std.testing.expectEqualStrings(modifiedD.hash, nodeD.?.contentHash.?); // Hash should have been updated.
    try std.testing.expectEqual(@as(u32, 1), nodeD.?.nodeCount); // Ensure node count is still 1

    // Verify the tree structure on the new hash.
    try expectTree(allocator, &originalTree, "((((A,B),C),(D,E)),(((F,G),H),(I,J)))");
}

test "adds files with UUIDs and verifies leaf order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fileNames = [_][]const u8{
        "asset/3e4f1677-dfc1-4efe-be57-6969e0b1c9b6",
        "asset/7b4f6865-26a5-4316-98ba-41e528594ec0",
        "asset/7c86cb29-c6ee-40dc-9d08-a8dc5c5a0dc7",
        "asset/f7ef0545-219b-4bf0-92e6-62a79c1f24de",
        "asset/fde1d531-1559-472f-9df9-878b7acec068",
    };

    const tree = try buildTree(allocator, &fileNames);

    // Collect all leaf nodes in order
    var leafNodes: std.ArrayList([]const u8) = .empty;
    var leaves = merkle_tree.iterateLeaves(merkle_tree.SortNode, allocator, tree.sort);
    while (try leaves.next()) |leafNode| {
        try leafNodes.append(allocator, leafNode.name.?);
    }

    // Verify the leaf nodes are in the same order as added
    try std.testing.expectEqual(fileNames.len, leafNodes.items.len);
    for (fileNames, leafNodes.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "updateItem throws for an empty tree" {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    try std.testing.expectError(error.Thrown, merkle_tree.updateItem(&tree, createHashedItem("A")));
    try std.testing.expectEqualStrings("Tree is empty, cannot update item 'A'", errors.lastErrorMessage());
}

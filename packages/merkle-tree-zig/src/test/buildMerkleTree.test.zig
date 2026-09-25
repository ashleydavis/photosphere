//
// Tests for buildMerkleTree (port of src/test/buildMerkleTree.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const MerkleNode = merkle_tree.MerkleNode;
const SortNode = merkle_tree.SortNode;
const buildTree = merkle_verify.buildTree;
const leaf = merkle_verify.leaf;
const node = merkle_verify.node;

//
// Collects the hashes of the leaves (nodes without children) of a merkle tree in order.
//
fn collectLeaves(allocator: std.mem.Allocator, leaves: *std.ArrayList([]const u8), merkleNode: ?*const MerkleNode) !void {
    const currentNode = merkleNode orelse {
        return;
    };
    if (currentNode.left == null and currentNode.right == null) {
        try leaves.append(allocator, currentNode.hash);
    }
    else {
        try collectLeaves(allocator, leaves, currentNode.left);
        try collectLeaves(allocator, leaves, currentNode.right);
    }
}

//
// Builds the merkle tree of a sort tree built from the names and returns its leaf hashes in order.
//
fn merkleLeafHashes(allocator: std.mem.Allocator, fileNames: []const []const u8) ![]const []const u8 {
    const tree = try buildTree(allocator, fileNames);
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expect(merkleTree != null);
    var leaves: std.ArrayList([]const u8) = .empty;
    try collectLeaves(allocator, &leaves, merkleTree);
    return leaves.items;
}

//
// Collects leaf names with iterateLeaves (works for sort and merkle trees).
//
fn iterateLeafNames(comptime NodeT: type, allocator: std.mem.Allocator, root: ?*NodeT) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var leaves = merkle_tree.iterateLeaves(NodeT, allocator, root);
    while (try leaves.next()) |leafNode| {
        if (leafNode.name) |name| {
            try names.append(allocator, name);
        }
    }
    return names.items;
}

//
// Checks the merkle tree of the names has leaf names in the same order as the sort tree.
//
fn expectSameLeafOrder(allocator: std.mem.Allocator, fileNames: []const []const u8) !void {
    const tree = try buildTree(allocator, fileNames);
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    const sortLeafNames = try iterateLeafNames(SortNode, allocator, tree.sort);
    const merkleLeafNames = try iterateLeafNames(MerkleNode, allocator, merkleTree);
    try std.testing.expectEqual(sortLeafNames.len, merkleLeafNames.len);
    for (sortLeafNames, merkleLeafNames) |sortName, merkleName| {
        try std.testing.expectEqualStrings(sortName, merkleName);
    }
}

//
// Counts the leaves of a merkle tree.
//
fn countLeaves(merkleNode: ?*const MerkleNode) usize {
    const currentNode = merkleNode orelse {
        return 0;
    };
    if (currentNode.left == null and currentNode.right == null) {
        return 1;
    }
    return countLeaves(currentNode.left) + countLeaves(currentNode.right);
}

//
// Names like `file_000` (TypeScript: `file_${i.toString().padStart(width, '0')}`).
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

test "returns undefined for undefined sort tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try merkle_tree.buildMerkleTree(arena.allocator(), null);
    try std.testing.expect(result == null);
}

test "builds merkle tree from single leaf node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sortTree = try leaf(allocator, "A", 100);
    const merkleTree = (try merkle_tree.buildMerkleTree(allocator, sortTree)).?;
    try std.testing.expectEqualStrings("A", merkleTree.hash);
    try std.testing.expect(merkleTree.left == null);
    try std.testing.expect(merkleTree.right == null);
}

test "builds merkle tree from two leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sortTree = try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100));
    const merkleTree = (try merkle_tree.buildMerkleTree(allocator, sortTree)).?;
    try std.testing.expectEqualStrings("A", merkleTree.left.?.hash);
    try std.testing.expectEqualStrings("B", merkleTree.right.?.hash);
    try std.testing.expectEqualSlices(u8, &merkle_tree.combineHashes("A", "B"), merkleTree.hash);
}

test "builds perfectly balanced tree with 2 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sortTree = try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100));
    const merkleTree = (try merkle_tree.buildMerkleTree(allocator, sortTree)).?;
    try std.testing.expectEqualStrings("A", merkleTree.left.?.hash);
    try std.testing.expectEqualStrings("B", merkleTree.right.?.hash);

    // Verify root hash is combination of children
    try std.testing.expectEqualSlices(u8, &merkle_tree.combineHashes(merkleTree.left.?.hash, merkleTree.right.?.hash), merkleTree.hash);
}

test "builds perfectly balanced tree with 4 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    const merkleTree = (try merkle_tree.buildMerkleTree(allocator, tree.sort)).?;

    // Should have structure: ((A,B),(C,D))
    try std.testing.expectEqualStrings("A", merkleTree.left.?.left.?.hash);
    try std.testing.expectEqualStrings("B", merkleTree.left.?.right.?.hash);
    try std.testing.expectEqualStrings("C", merkleTree.right.?.left.?.hash);
    try std.testing.expectEqualStrings("D", merkleTree.right.?.right.?.hash);
}

test "builds perfectly balanced tree with 8 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G", "H" });
    const merkleTree = (try merkle_tree.buildMerkleTree(allocator, tree.sort)).?;

    // Should have 3 levels: (((A,B),(C,D)),((E,F),(G,H)))
    try std.testing.expectEqualStrings("A", merkleTree.left.?.left.?.left.?.hash);
    try std.testing.expectEqualStrings("B", merkleTree.left.?.left.?.right.?.hash);
    try std.testing.expectEqualStrings("C", merkleTree.left.?.right.?.left.?.hash);
    try std.testing.expectEqualStrings("D", merkleTree.left.?.right.?.right.?.hash);
    try std.testing.expectEqualStrings("E", merkleTree.right.?.left.?.left.?.hash);
    try std.testing.expectEqualStrings("F", merkleTree.right.?.left.?.right.?.hash);
    try std.testing.expectEqualStrings("G", merkleTree.right.?.right.?.left.?.hash);
    try std.testing.expectEqualStrings("H", merkleTree.right.?.right.?.right.?.hash);
}

//
// Checks the merkle tree of the first `count` letters has exactly those leaves in order (no duplicated last node).
//
fn expectLettersWithoutDuplication(count: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const letters = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I" };
    const leaves = try merkleLeafHashes(allocator, letters[0..count]);
    try std.testing.expectEqual(count, leaves.len);
    for (letters[0..count], leaves) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "builds tree with 3 leaves without duplicating last node" {
    try expectLettersWithoutDuplication(3);
}

test "builds tree with 5 leaves without duplicating last node" {
    try expectLettersWithoutDuplication(5);
}

test "builds tree with 7 leaves without duplicating last node" {
    try expectLettersWithoutDuplication(7);
}

test "builds tree with 9 leaves without duplicating last node" {
    try expectLettersWithoutDuplication(9);
}

//
// Checks that every internal node's hash combines its children's hashes.
//
fn verifyHashes(merkleNode: ?*const MerkleNode) bool {
    const currentNode = merkleNode orelse {
        return true;
    };

    // If it's a leaf node (no children), hash is valid
    if (currentNode.left == null and currentNode.right == null) {
        return true;
    }

    // If it has children, verify hash is combination
    if (currentNode.left != null and currentNode.right != null) {
        const expectedHash = merkle_tree.combineHashes(currentNode.left.?.hash, currentNode.right.?.hash);
        if (!std.mem.eql(u8, currentNode.hash, &expectedHash)) {
            return false;
        }
        return verifyHashes(currentNode.left) and verifyHashes(currentNode.right);
    }

    // If it has only one child (carried up), just recurse
    if (currentNode.left != null) {
        return verifyHashes(currentNode.left);
    }
    return verifyHashes(currentNode.right);
}

test "all parent hashes are combinations of child hashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F" });
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expect(verifyHashes(merkleTree));
}

test "root hash changes when any leaf changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree1 = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    const merkle1 = (try merkle_tree.buildMerkleTree(allocator, tree1.sort)).?;
    const tree2 = try buildTree(allocator, &.{ "A", "B", "X", "D" }); // Changed C to X
    const merkle2 = (try merkle_tree.buildMerkleTree(allocator, tree2.sort)).?;
    try std.testing.expect(!std.mem.eql(u8, merkle1.hash, merkle2.hash));
}

test "root hash is same for same leaves regardless of sort tree structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree1 = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    const merkle1 = (try merkle_tree.buildMerkleTree(allocator, tree1.sort)).?;
    const tree2 = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    const merkle2 = (try merkle_tree.buildMerkleTree(allocator, tree2.sort)).?;

    // Root hash should be identical
    try std.testing.expectEqualSlices(u8, merkle1.hash, merkle2.hash);
}

test "preserves leaf order from sort tree traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "E", "B", "A", "D", "C" }); // Unsorted input
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);

    const sortLeaves = try iterateLeafNames(SortNode, allocator, tree.sort);
    var merkleLeaves: std.ArrayList([]const u8) = .empty;
    try collectLeaves(allocator, &merkleLeaves, merkleTree);

    // Leaves should appear in the same order
    try std.testing.expectEqual(sortLeaves.len, merkleLeaves.items.len);
    for (sortLeaves, merkleLeaves.items) |sortName, merkleHash| {
        try std.testing.expectEqualStrings(sortName, merkleHash);
    }
}

test "merkle tree leaf names appear in same order as sort tree when using iterateLeaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSameLeafOrder(arena.allocator(), &.{ "E", "B", "A", "D", "C" });
}

test "merkle tree leaf order matches sort tree leaf order - FAILS: buildMerkleTree does not preserve order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSameLeafOrder(arena.allocator(), &.{ "A", "B", "C" });
}

test "merkle tree leaf order matches sort tree for 5 leaves - FAILS: demonstrates ordering bug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectSameLeafOrder(arena.allocator(), &.{ "E", "B", "A", "D", "C" });
}

test "merkle tree preserves leaf order for various tree sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const letters = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G" };
    var count: usize = 1;
    while (count <= letters.len) {
        try expectSameLeafOrder(allocator, letters[0..count]);
        count += 1;
    }
}

test "builds tree with 100 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, try paddedFileNames(allocator, 100, 3));
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expectEqual(@as(usize, 100), countLeaves(merkleTree));
}

test "builds tree with 1000 leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, try paddedFileNames(allocator, 1000, 4));
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expectEqual(@as(usize, 1000), countLeaves(merkleTree));
}

//
// The depth of a merkle tree (a leaf has depth 1).
//
fn getDepth(merkleNode: ?*const MerkleNode) usize {
    const currentNode = merkleNode orelse {
        return 0;
    };
    if (currentNode.left == null and currentNode.right == null) {
        return 1;
    }
    return 1 + @max(getDepth(currentNode.left), getDepth(currentNode.right));
}

test "merkle tree depth is logarithmic for powers of 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 8 leaves should have depth 4 (log2(8) + 1)
    const tree8 = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G", "H" });
    const merkle8 = try merkle_tree.buildMerkleTree(allocator, tree8.sort);
    try std.testing.expectEqual(@as(usize, 4), getDepth(merkle8));

    // 16 leaves should have depth 5 (log2(16) + 1)
    var names16: [16][]const u8 = undefined;
    for (&names16, 0..) |*name, index| {
        name.* = try std.fmt.allocPrint(allocator, "file_{d}", .{index});
    }
    const tree16 = try buildTree(allocator, &names16);
    const merkle16 = try merkle_tree.buildMerkleTree(allocator, tree16.sort);
    try std.testing.expectEqual(@as(usize, 5), getDepth(merkle16));
}

//
// Checks every non-leaf node has at least one child.
//
fn verifyStructure(merkleNode: ?*const MerkleNode) bool {
    const currentNode = merkleNode orelse {
        return true;
    };
    const isLeaf = currentNode.left == null and currentNode.right == null;
    if (isLeaf) {
        return true;
    }
    return verifyStructure(currentNode.left) and verifyStructure(currentNode.right);
}

test "every non-leaf node has at least one child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G" });
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expect(verifyStructure(merkleTree));
}

//
// Counts the nodes of a merkle tree.
//
fn countNodes(merkleNode: ?*const MerkleNode) usize {
    const currentNode = merkleNode orelse {
        return 0;
    };
    return 1 + countNodes(currentNode.left) + countNodes(currentNode.right);
}

test "merkle tree has fewer nodes than sort tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expect(countNodes(merkleTree) <= tree.sort.?.nodeCount);
}

//
// Returns true when two merkle trees have the same hashes and shape.
//
fn compareNodes(node1: ?*const MerkleNode, node2: ?*const MerkleNode) bool {
    if (node1 == null and node2 == null) {
        return true;
    }
    if (node1 == null or node2 == null) {
        return false;
    }
    if (!std.mem.eql(u8, node1.?.hash, node2.?.hash)) {
        return false;
    }
    return compareNodes(node1.?.left, node2.?.left) and compareNodes(node1.?.right, node2.?.right);
}

test "building merkle tree twice produces identical results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    const merkle1 = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    const merkle2 = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expect(compareNodes(merkle1, merkle2));
}

test "merkle tree is deterministic for same input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var firstHash: ?[]const u8 = null;
    var iteration: usize = 0;
    while (iteration < 5) {
        const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E", "F", "G" });
        const merkleTree = (try merkle_tree.buildMerkleTree(allocator, tree.sort)).?;
        if (firstHash) |hash| {
            try std.testing.expectEqualSlices(u8, hash, merkleTree.hash);
        }
        else {
            firstHash = merkleTree.hash;
        }
        iteration += 1;
    }
}

test "builds tree with UUID filenames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{
        "asset/3e4f1677-dfc1-4efe-be57-6969e0b1c9b6",
        "asset/7b4f6865-26a5-4316-98ba-41e528594ec0",
        "asset/7c86cb29-c6ee-40dc-9d08-a8dc5c5a0dc7",
    });
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expectEqual(@as(usize, 3), countLeaves(merkleTree));
}

test "builds tree with paths containing slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildTree(allocator, &.{ "a/b/c/file1.txt", "a/b/file2.txt", "a/file3.txt", "file4.txt" });
    const merkleTree = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    try std.testing.expect(merkleTree != null);
}

test "buildMerkleTree throws for a leaf without a content hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sortTree = try leaf(allocator, "A", 100);
    sortTree.contentHash = null;
    try std.testing.expectError(error.Thrown, merkle_tree.buildMerkleTree(allocator, sortTree));
    try std.testing.expectEqualStrings("Leaf node has no content hash", @import("utils-zig").errors.lastErrorMessage());
}

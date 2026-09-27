//
// Tests for rebuildTree. The TypeScript package has no tests for rebuildTree, so these are new; they check
// what the TypeScript rebuildTree does: keep every leaf not under a removed path, in sorted order, in a clean
// tree with a built merkle tree, the same id and the same database metadata, and throw for a malformed leaf.
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const errors = @import("utils-zig").errors;
const bson = @import("serialization-zig").bson;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;

//
// Collects the names of the leaves of a sort tree, left to right.
//
fn collectSortLeafNames(allocator: std.mem.Allocator, sortNode: ?*SortNode) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const flatArray = try merkle_tree.binaryTreeToArray(allocator, sortNode);
    for (flatArray) |flatNode| {
        if (flatNode.nodeCount == 1) {
            try names.append(allocator, flatNode.name.?);
        }
    }
    return names.items;
}

//
// Collects the names of the leaves of a tree's merkle tree, left to right.
//
fn collectMerkleNames(allocator: std.mem.Allocator, tree: *const IMerkleTree) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try merkle_verify.collectMerkleLeafNames(allocator, &names, tree.merkle.?);
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

test "rebuilds a tree with every item in sorted order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{ "D", "B", "E", "A", "C" });
    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{});

    try expectNames(&.{ "A", "B", "C", "D", "E" }, try collectSortLeafNames(allocator, rebuiltTree.sort));
    try expectNames(&.{ "A", "B", "C", "D", "E" }, try collectMerkleNames(allocator, &rebuiltTree));
    try std.testing.expectEqual(@as(u32, 9), rebuiltTree.sort.?.nodeCount);
    try std.testing.expectEqual(@as(u32, 5), rebuiltTree.sort.?.leafCount);
    try std.testing.expectEqual(@as(u64, 5), rebuiltTree.sort.?.size);
}

test "rebuilt tree is clean, keeps its id and has a merkle tree built from the sorted items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{ "C", "A", "B" });
    try std.testing.expect(tree.dirty);
    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{});

    try std.testing.expect(!rebuiltTree.dirty);
    try std.testing.expectEqualStrings(tree.id, rebuiltTree.id);
    try std.testing.expectEqual(merkle_tree.CURRENT_DATABASE_VERSION, rebuiltTree.version);

    // The merkle tree is the one built from the items added in sorted order.
    const sortedTree = try merkle_verify.buildTree(allocator, &.{ "A", "B", "C" });
    const expectedMerkle = (try merkle_tree.buildMerkleTree(allocator, sortedTree.sort)).?;
    try std.testing.expectEqualSlices(u8, expectedMerkle.hash, rebuiltTree.merkle.?.hash);
    try std.testing.expectEqual(expectedMerkle.nodeCount, rebuiltTree.merkle.?.nodeCount);
}

test "removes items whose names start with a path to remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{
        "metadata/version.json",
        "assets/one",
        "display/one",
        ".db/files.dat",
        "assets/two",
        "metadata/other.json",
        "thumb/one",
    });
    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{ "metadata/", "assets/" });

    try expectNames(&.{ ".db/files.dat", "display/one", "thumb/one" }, try collectSortLeafNames(allocator, rebuiltTree.sort));
    try expectNames(&.{ ".db/files.dat", "display/one", "thumb/one" }, try collectMerkleNames(allocator, &rebuiltTree));
}

test "removes every item when every item is under a path to remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{ "assets/one", "assets/two" });
    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{"assets/"});

    try std.testing.expect(rebuiltTree.sort == null);
    try std.testing.expect(rebuiltTree.merkle == null);
    try std.testing.expect(!rebuiltTree.dirty);
}

test "rebuilds an empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{});

    try std.testing.expect(rebuiltTree.sort == null);
    try std.testing.expect(rebuiltTree.merkle == null);
    try std.testing.expectEqualStrings(merkle_verify.TEST_TREE_ID, rebuiltTree.id);
}

test "keeps the database metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try merkle_verify.buildTree(allocator, &.{ "B", "A" });
    var metadata: bson.BsonDocument = .empty;
    try metadata.put(allocator, "filesImported", .{ .number = 3 });
    tree.databaseMetadata = metadata;

    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{});

    try std.testing.expect(rebuiltTree.databaseMetadata.?.eql(metadata));
}

test "keeps the hash, size and last modified date of each item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "B", "content b", 20));
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "A", "content a", 10));
    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{});

    const itemInfo = (try merkle_tree.getItemInfo(&rebuiltTree, "B")).?;
    try std.testing.expectEqualSlices(u8, try merkle_verify.sha256(allocator, "content b"), itemInfo.hash);
    try std.testing.expectEqual(@as(u64, 20), itemInfo.length);
    try std.testing.expectEqual(merkle_verify.TEST_TIMESTAMP, itemInfo.lastModified);
    try std.testing.expectEqual(@as(u64, 30), rebuiltTree.sort.?.size);
}

test "throws for a leaf node with no name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var leafNode: SortNode = .{
        .contentHash = "hash",
        .nodeCount = 1,
        .leafCount = 1,
        .size = 1,
        .lastModified = merkle_verify.TEST_TIMESTAMP,
        .minName = "",
    };
    tree.sort = &leafNode;

    try std.testing.expectError(error.Thrown, merkle_tree.rebuildTree(allocator, &tree, &.{}));
    try std.testing.expectEqualStrings("Leaf node has no name. This could be a bug.", errors.lastErrorMessage());
}

test "throws for a leaf node with no content hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var leafNode: SortNode = .{
        .name = "A",
        .nodeCount = 1,
        .leafCount = 1,
        .size = 1,
        .lastModified = merkle_verify.TEST_TIMESTAMP,
        .minName = "A",
    };
    tree.sort = &leafNode;

    try std.testing.expectError(error.Thrown, merkle_tree.rebuildTree(allocator, &tree, &.{}));
    try std.testing.expectEqualStrings("Leaf node has no content hash. This could be a bug.", errors.lastErrorMessage());
}

test "throws for a leaf node with no last modified date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // merkle_verify.leaf makes leaves with no last modified date.
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree.sort = try merkle_verify.node(allocator, try merkle_verify.leaf(allocator, "A", 1), try merkle_verify.leaf(allocator, "B", 1));

    try std.testing.expectError(error.Thrown, merkle_tree.rebuildTree(allocator, &tree, &.{}));
    try std.testing.expectEqualStrings("Leaf node has no last modified date. This could be a bug.", errors.lastErrorMessage());
}

//
// Creates a leaf node with a content hash and a last modified date, which rebuildTree requires.
//
fn datedLeaf(allocator: std.mem.Allocator, name: []const u8) !*SortNode {
    const leafNode = try merkle_verify.leaf(allocator, name, 1);
    leafNode.lastModified = merkle_verify.TEST_TIMESTAMP;
    return leafNode;
}

test "sorts items that are out of order in the source tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A sort tree whose leaves are in reverse order, as addItem would never make it.
    // (Adding these items in this order gives (((A,B),(C,D)),((E,F),(G,H))), so the shape shows they were sorted first.)
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree.sort = try merkle_verify.node(
        allocator,
        try merkle_verify.node(
            allocator,
            try merkle_verify.node(allocator, try datedLeaf(allocator, "H"), try datedLeaf(allocator, "G")),
            try merkle_verify.node(allocator, try datedLeaf(allocator, "F"), try datedLeaf(allocator, "E")),
        ),
        try merkle_verify.node(
            allocator,
            try merkle_verify.node(allocator, try datedLeaf(allocator, "D"), try datedLeaf(allocator, "C")),
            try merkle_verify.node(allocator, try datedLeaf(allocator, "B"), try datedLeaf(allocator, "A")),
        ),
    );

    const rebuiltTree = try merkle_tree.rebuildTree(allocator, &tree, &.{});

    // The rebuilt tree is the tree made by adding the items in sorted order.
    try std.testing.expectEqualStrings("(((A,B),C),((D,E),((F,G),H)))", try merkle_verify.sortTreeShape(allocator, rebuiltTree.sort));
    try expectNames(&.{ "A", "B", "C", "D", "E", "F", "G", "H" }, try collectMerkleNames(allocator, &rebuiltTree));
}

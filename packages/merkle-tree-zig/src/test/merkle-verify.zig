//
// Test helpers shared by the merkle tree tests (the equivalent of src/test/merkle-verify.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const SortNode = merkle_tree.SortNode;
const MerkleNode = merkle_tree.MerkleNode;
const HashedItem = merkle_tree.HashedItem;
const IMerkleTree = merkle_tree.IMerkleTree;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The timestamp the tests use for `new Date()` (Zig tests use a fixed time so they are deterministic).
//
pub const TEST_TIMESTAMP: i64 = 1_700_000_000_000;

//
// The tree id the TypeScript tests use.
//
pub const TEST_TREE_ID = "12345678-1234-5678-9abc-123456789abc";

//
// Helper function to create a file hash with a given name and length
//
pub fn createHashedItem(name: []const u8) HashedItem {
    return .{
        .name = name,
        .hash = name,
        .length = 1,
        .lastModified = TEST_TIMESTAMP,
    };
}

//
// Computes the SHA-256 of content, allocated so it can be used as a hash slice
// (TypeScript: `crypto.createHash('sha256').update(content).digest()`).
//
pub fn sha256(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const digest = try allocator.create([Sha256.digest_length]u8);
    Sha256.hash(content, digest, .{});
    return digest;
}

//
// Creates a hashed item whose hash is the SHA-256 of content (the helper most TypeScript test files define).
//
pub fn createSha256HashedItem(allocator: std.mem.Allocator, name: []const u8, content: []const u8, length: u64) !HashedItem {
    return .{
        .name = name,
        .hash = try sha256(allocator, content),
        .length = length,
        .lastModified = TEST_TIMESTAMP,
    };
}

//
// Helper function to build a tree with the given file names
//
pub fn buildTree(allocator: std.mem.Allocator, fileNames: []const []const u8) !IMerkleTree {
    var merkleTree = merkle_tree.createTree(TEST_TREE_ID);

    for (fileNames) |fileName| {
        const fileHash = createHashedItem(fileName);
        merkleTree = try merkle_tree.addItem(allocator, &merkleTree, fileHash);
    }

    return merkleTree;
}

//
// Helper function to create a leaf node
//
pub fn leaf(allocator: std.mem.Allocator, name: []const u8, size: u64) !*SortNode {
    const leafNode = try allocator.create(SortNode);
    leafNode.* = .{
        .contentHash = name,
        .name = name,
        .nodeCount = 1,
        .leafCount = 1,
        .size = size,
        .minName = name,
    };
    return leafNode;
}

//
// Helper function to create an internal node
//
pub fn node(allocator: std.mem.Allocator, left: *SortNode, right: *SortNode) !*SortNode {
    const parent = try allocator.create(SortNode);
    parent.* = .{
        .nodeCount = 1 + left.nodeCount + right.nodeCount,
        .leafCount = left.leafCount + right.leafCount,
        .size = left.size + right.size,
        .minName = left.minName,
        .left = left,
        .right = right,
    };
    return parent;
}

//
// Writes the shape of a sort tree: a leaf is its name, an internal node is "(left,right)".
//
fn writeShape(writer: *std.Io.Writer, sortNode: *const SortNode) !void {
    if (sortNode.left == null and sortNode.right == null) {
        try writer.writeAll(sortNode.name orelse "?");
        return;
    }
    try writer.writeAll("(");
    if (sortNode.left) |left| {
        try writeShape(writer, left);
    }
    try writer.writeAll(",");
    if (sortNode.right) |right| {
        try writeShape(writer, right);
    }
    try writer.writeAll(")");
}

//
// Renders the shape of a sort tree (for example "((A,B),C)").
//
pub fn sortTreeShape(allocator: std.mem.Allocator, sortNode: ?*const SortNode) ![]const u8 {
    const root = sortNode orelse {
        return "";
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeShape(&output.writer, root);
    return output.written();
}

//
// Checks the invariants _expectNode in merkle-verify.ts checks on every node: leaves have a name, a content hash,
// nodeCount 1 and minName equal to the name; internal nodes have nodeCount >= 3 and minName equal to the left minName.
//
fn expectNodeInvariants(sortNode: *const SortNode) !void {
    if (sortNode.left == null and sortNode.right == null) {
        try std.testing.expectEqual(@as(u32, 1), sortNode.nodeCount);
        try std.testing.expect(sortNode.name != null);
        try std.testing.expect(sortNode.contentHash != null);
        try std.testing.expectEqualStrings(sortNode.name.?, sortNode.minName);
        return;
    }
    try std.testing.expect(sortNode.nodeCount >= 3);
    if (sortNode.left) |left| {
        try std.testing.expectEqualStrings(left.minName, sortNode.minName);
        try expectNodeInvariants(left);
    }
    if (sortNode.right) |right| {
        try expectNodeInvariants(right);
    }
}

//
// Checks that a node matches the expected structure (TypeScript: expectNode with a nested structure object;
// Zig: the expected structure is written as a shape string, for example "(C,(E,D))").
//
pub fn expectNode(allocator: std.mem.Allocator, sortNode: *const SortNode, expectedShape: []const u8) !void {
    try expectNodeInvariants(sortNode);
    try std.testing.expectEqualStrings(expectedShape, try sortTreeShape(allocator, sortNode));
}

//
// Verify the entire tree structure matches the expected structure.
//
pub fn expectTree(allocator: std.mem.Allocator, tree: *const IMerkleTree, expectedShape: []const u8) !void {
    try expectNode(allocator, tree.sort.?, expectedShape);
}

//
// Collects the leaf names of a merkle node (the `extract` helper the merkle-diff tests use).
//
pub fn collectMerkleLeafNames(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), merkleNode: *const MerkleNode) !void {
    if (merkleNode.name != null and merkleNode.left == null and merkleNode.right == null) {
        try names.append(allocator, merkleNode.name.?);
        return;
    }
    if (merkleNode.left) |left| {
        try collectMerkleLeafNames(allocator, names, left);
    }
    if (merkleNode.right) |right| {
        try collectMerkleLeafNames(allocator, names, right);
    }
}

//
// Returns true when a list of names contains a name (Jest: `expect(list).toContain(name)`).
//
pub fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }
    return false;
}

//
// Sorts names in JavaScript default sort order (ASCII names in the tests, so byte order).
//
pub fn sortNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, lessThanName);
}

//
// Byte order of two names.
//
fn lessThanName(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.order(u8, left, right) == .lt;
}

//
// Generates all permutations of names (the generatePermutations helper of several TypeScript test files).
//
pub fn generatePermutations(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const []const u8 {
    if (names.len <= 1) {
        const single = try allocator.alloc([]const []const u8, 1);
        single[0] = names;
        return single;
    }

    var result: std.ArrayList([]const []const u8) = .empty;
    for (names, 0..) |current, index| {
        const remaining = try std.mem.concat(allocator, []const u8, &.{ names[0..index], names[index + 1 ..] });
        const permutations = try generatePermutations(allocator, remaining);
        for (permutations) |permutation| {
            const combined = try std.mem.concat(allocator, []const u8, &.{ &.{current}, permutation });
            try result.append(allocator, combined);
        }
    }
    return result.items;
}

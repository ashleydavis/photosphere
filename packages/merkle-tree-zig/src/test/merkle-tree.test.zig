//
// Unit tests for the merkle-tree.zig functions that the TypeScript test files do not test directly
// (no TypeScript counterpart file).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const errors = @import("utils-zig").errors;
const bson = @import("serialization-zig").bson;
const merkle_tree = merkle_tree_zig.merkle_tree;
const SortNode = merkle_tree.SortNode;
const IMerkleTree = merkle_tree.IMerkleTree;
const Sha256 = std.crypto.hash.sha2.Sha256;

test "compareNames orders names like localeCompare with numeric collation" {
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("file2", "file10"));
    try std.testing.expectEqual(@as(i32, 1), merkle_tree.compareNames("file10", "file2"));
    try std.testing.expectEqual(@as(i32, 0), merkle_tree.compareNames("file02", "file2"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("a", "A"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("A", "b"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("a-b", "ab"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("_a", "-a"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("$", "0"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("9", "a"));
    try std.testing.expectEqual(@as(i32, 0), merkle_tree.compareNames("x\x00", "x"));
    try std.testing.expectEqual(@as(i32, 0), merkle_tree.compareNames("", ""));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("", "a"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("README.md", "thumb/x"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("99999999999999999999999", "100000000000000000000000"));
    try std.testing.expectEqual(@as(i32, -1), merkle_tree.compareNames("z", "\xc3\xa9"));
}

test "combineHashes is the SHA-256 of the two hashes" {
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("leftright", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &merkle_tree.combineHashes("left", "right"));
}

test "createTree creates an empty clean tree of the current version" {
    const tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    try std.testing.expectEqualStrings(merkle_verify.TEST_TREE_ID, tree.id);
    try std.testing.expect(tree.sort == null);
    try std.testing.expect(tree.merkle == null);
    try std.testing.expect(!tree.dirty);
    try std.testing.expect(tree.databaseMetadata == null);
    try std.testing.expectEqual(merkle_tree.CURRENT_DATABASE_VERSION, tree.version);
}

test "createLeafNode and createParentNode compute counts, sizes and minName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const left = try merkle_tree.createLeafNode(allocator, .{ .name = "a", .hash = "ha", .length = 10, .lastModified = 5 });
    const right = try merkle_tree.createLeafNode(allocator, .{ .name = "b", .hash = "hb", .length = 20, .lastModified = 6 });
    try std.testing.expectEqual(@as(u32, 1), left.nodeCount);
    try std.testing.expectEqual(@as(u32, 1), left.leafCount);
    try std.testing.expectEqual(@as(u64, 10), left.size);
    try std.testing.expectEqual(@as(?i64, 5), left.lastModified);
    try std.testing.expectEqualStrings("a", left.minName);

    const parent = try merkle_tree.createParentNode(allocator, left, right);
    try std.testing.expectEqual(@as(u32, 3), parent.nodeCount);
    try std.testing.expectEqual(@as(u32, 2), parent.leafCount);
    try std.testing.expectEqual(@as(u64, 30), parent.size);
    try std.testing.expectEqualStrings("a", parent.minName);
    try std.testing.expect(parent.name == null);
}

test "findItemInTree searches every leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    try std.testing.expectEqualStrings("D", merkle_tree.findItemInTree(tree.sort, "D").?.name.?);
    try std.testing.expect(merkle_tree.findItemInTree(tree.sort, "Z") == null);
    try std.testing.expect(merkle_tree.findItemInTree(null, "A") == null);
}

//
// An updater that sets the size of the found leaf.
//
fn setSize(newSize: u64, node: *SortNode, targetName: []const u8) bool {
    _ = targetName;
    node.size = newSize;
    return true;
}

test "updateNodeInTree updates the leaf and recalculates parent sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{ "A", "B", "C" });
    try std.testing.expectEqual(@as(u64, 3), tree.sort.?.size);
    try std.testing.expectEqual(@as(?bool, true), merkle_tree.updateNodeInTree(bool, tree.sort.?, "C", @as(u64, 10), setSize));
    try std.testing.expectEqual(@as(u64, 12), tree.sort.?.size);
    try std.testing.expectEqual(@as(?bool, null), merkle_tree.updateNodeInTree(bool, tree.sort.?, "Z", @as(u64, 10), setSize));
}

test "addItem keeps the id, merkle tree, version and metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree.version = 4;
    var metadata: bson.BsonDocument = .empty;
    try metadata.put(allocator, "filesImported", .{ .number = 1 });
    tree.databaseMetadata = metadata;
    const updated = try merkle_tree.addItem(allocator, &tree, merkle_verify.createHashedItem("A"));
    try std.testing.expectEqualStrings(tree.id, updated.id);
    try std.testing.expectEqual(@as(u32, 4), updated.version);
    try std.testing.expect(updated.dirty);
    try std.testing.expect(updated.databaseMetadata.?.eql(metadata));
}

test "getItemInfo throws when the leaf has no lastModified date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree.sort = try merkle_verify.leaf(allocator, "A", 1);
    try std.testing.expectError(error.Thrown, merkle_tree.getItemInfo(&tree, "A"));
    try std.testing.expectEqualStrings("Item A is missing lastModified date. This could be a bug.", errors.lastErrorMessage());

    tree.sort.?.lastModified = 7;
    const info = (try merkle_tree.getItemInfo(&tree, "A")).?;
    try std.testing.expectEqualStrings("A", info.hash);
    try std.testing.expectEqual(@as(u64, 1), info.length);
    try std.testing.expectEqual(@as(i64, 7), info.lastModified);
}

test "parseUuid and stringifyUuid round trip and validate like the uuid package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bytes = try merkle_tree.parseUuid("12345678-1234-5678-9ABC-123456789abc");
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc }, &bytes);
    try std.testing.expectEqualStrings("12345678-1234-5678-9abc-123456789abc", try merkle_tree.stringifyUuid(allocator, &bytes));

    // The nil and max UUIDs are valid.
    _ = try merkle_tree.parseUuid("00000000-0000-0000-0000-000000000000");
    _ = try merkle_tree.parseUuid("ffffffff-ffff-ffff-ffff-ffffffffffff");

    // Version 0 and variant 'c' are not valid.
    try std.testing.expectError(error.Thrown, merkle_tree.parseUuid("12345678-1234-0678-9abc-123456789abc"));
    try std.testing.expectError(error.Thrown, merkle_tree.parseUuid("12345678-1234-5678-cabc-123456789abc"));
    try std.testing.expectError(error.Thrown, merkle_tree.parseUuid("test-tree"));
    try std.testing.expectEqualStrings("Invalid UUID", errors.lastErrorMessage());

    const invalidBytes = [_]u8{0x11} ** 16;
    try std.testing.expectError(error.Thrown, merkle_tree.stringifyUuid(allocator, &invalidBytes));
    try std.testing.expectEqualStrings("Stringified UUID is invalid", errors.lastErrorMessage());
}

test "iterateLeaves works on merkle trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try merkle_verify.buildTree(allocator, &.{ "A", "B", "C" });
    const merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    var leaves = merkle_tree.iterateLeaves(merkle_tree.MerkleNode, allocator, merkle);
    try std.testing.expectEqualStrings("A", (try leaves.next()).?.name.?);
    try std.testing.expectEqualStrings("B", (try leaves.next()).?.name.?);
    try std.testing.expectEqualStrings("C", (try leaves.next()).?.name.?);
    try std.testing.expect((try leaves.next()) == null);
}

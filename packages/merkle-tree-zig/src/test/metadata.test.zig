//
// Tree metadata tests (port of src/test/metadata.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const memory_storage = @import("memory-storage.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;

//
// Helper function to build a tree with the given file names
//
fn buildTree(allocator: std.mem.Allocator, fileNames: []const []const u8) !IMerkleTree {
    var merkleTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    for (fileNames) |fileName| {
        merkleTree = try merkle_tree.addItem(allocator, &merkleTree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
    }
    merkleTree.dirty = false;
    merkleTree.merkle = try merkle_tree.buildMerkleTree(allocator, merkleTree.sort);
    return merkleTree;
}

//
// Returns true when text has the lowercase UUID format.
//
fn isUuidFormat(text: []const u8) bool {
    if (text.len != 36) {
        return false;
    }
    for (text, 0..) |character, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (character != '-') {
                return false;
            }
        }
        else if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) {
            return false;
        }
    }
    return true;
}

test "should initialize metadata when creating a new tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const originalTree = try buildTree(arena.allocator(), &.{ "A", "B" });
    try std.testing.expect(isUuidFormat(originalTree.id));
    try std.testing.expect(originalTree.sort.?.leafCount > 0);
}

test "should update metadata when modifying the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{ "A", "B" });
    const originalId = tree.id;
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "C", "C", 1));
    try std.testing.expectEqualStrings(originalId, tree.id);
    try std.testing.expect(tree.sort.?.leafCount > 0);
}

test "should update metadata when updating a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{ "A", "B" });
    const originalId = tree.id;
    const originalNodeCount = tree.sort.?.nodeCount;
    const originalLeafCount = tree.sort.?.leafCount;
    _ = try merkle_tree.updateItem(&tree, try merkle_verify.createSha256HashedItem(allocator, "A", "modified content", 16));
    try std.testing.expectEqualStrings(originalId, tree.id);
    try std.testing.expectEqual(originalNodeCount, tree.sort.?.nodeCount);
    try std.testing.expectEqual(originalLeafCount, tree.sort.?.leafCount);
}

test "should update metadata when deleting a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{ "A", "B", "C" });
    const originalId = tree.id;
    const originalNodeCount = tree.sort.?.nodeCount;
    const originalLeafCount = tree.sort.?.leafCount;
    try merkle_tree.deleteItem(allocator, &tree, "B");
    try std.testing.expectEqualStrings(originalId, tree.id);
    try std.testing.expect(tree.sort.?.nodeCount < originalNodeCount);
    try std.testing.expectEqual(originalLeafCount - 1, tree.sort.?.leafCount);
}

test "should save and load metadata with V2 format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const originalTree = try buildTree(allocator, &.{ "A", "B", "C" });
    var storage = memory_storage.MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, std.testing.io, "test-tree-metadata.bin", &originalTree, storage.asStorage(), "FTRE");
    const loadedTree = (try merkle_tree.loadTree(allocator, std.testing.io, "test-tree-metadata.bin", storage.asStorage(), "FTRE")).?;
    try std.testing.expectEqualStrings(originalTree.id, loadedTree.id);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try std.testing.expectEqual(originalTree.sort.?.leafCount, loadedTree.sort.?.leafCount);
}

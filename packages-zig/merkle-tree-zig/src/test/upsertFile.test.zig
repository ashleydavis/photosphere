//
// Tests for upsertItem (port of src/test/upsertFile.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const traverse = merkle_tree_zig.traverse;
const MerkleNode = merkle_tree.MerkleNode;
const HashedItem = merkle_tree.HashedItem;

//
// Helper to create a file hash
//
fn createHashedItem(allocator: std.mem.Allocator, name: []const u8, content: []const u8) !HashedItem {
    return merkle_verify.createSha256HashedItem(allocator, name, content, content.len);
}

//
// Records the hash of every visited merkle node.
//
const HashRecorder = struct {
    // Allocates the list.
    allocator: std.mem.Allocator,

    // The hashes in visit order.
    hashes: std.ArrayList([]const u8),

    //
    // The traversal callback.
    //
    fn record(self: *HashRecorder, currentNode: *MerkleNode) anyerror!bool {
        try self.hashes.append(self.allocator, currentNode.hash);
        return true; // Continue traversal
    }
};

test "adds new file when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file1.txt", "original content"));
    try std.testing.expectEqual(@as(u32, 1), tree.sort.?.leafCount);

    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file2.txt", "second file"));
    try std.testing.expectEqual(@as(u32, 2), tree.sort.?.leafCount);
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file1.txt")) != null);
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file2.txt")) != null);
}

test "updates existing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const file = try createHashedItem(allocator, "file1.txt", "original content");
    tree = try merkle_tree.upsertItem(allocator, &tree, file);
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    try std.testing.expectEqual(@as(u32, 1), tree.sort.?.leafCount);
    try std.testing.expectEqualSlices(u8, file.hash, (merkle_tree.findItemInTree(tree.sort, "file1.txt")).?.contentHash.?);
    const originalRootHash = tree.merkle.?.hash;

    const updatedFile = try createHashedItem(allocator, "file1.txt", "updated content");
    tree = try merkle_tree.upsertItem(allocator, &tree, updatedFile);
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    try std.testing.expectEqual(@as(u32, 1), tree.sort.?.leafCount); // Still just one file
    try std.testing.expectEqualSlices(u8, updatedFile.hash, (merkle_tree.findItemInTree(tree.sort, "file1.txt")).?.contentHash.?);
    try std.testing.expect(!std.mem.eql(u8, originalRootHash, tree.merkle.?.hash));
}

test "maintains tree structure when updating files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file1.txt", "content 1"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file2.txt", "content 2"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file3.txt", "content 3"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file4.txt", "content 4"));
    try std.testing.expectEqual(@as(u32, 4), tree.sort.?.leafCount);

    const updatedFile2 = try createHashedItem(allocator, "file2.txt", "updated content 2");
    tree = try merkle_tree.upsertItem(allocator, &tree, updatedFile2);

    try std.testing.expectEqual(@as(u32, 4), tree.sort.?.leafCount); // Still 4 files
    for ([_][]const u8{ "file1.txt", "file2.txt", "file3.txt", "file4.txt" }) |name| {
        try std.testing.expect((merkle_tree.findItemInTree(tree.sort, name)) != null);
    }
    try std.testing.expectEqualSlices(u8, updatedFile2.hash, (merkle_tree.findItemInTree(tree.sort, "file2.txt")).?.contentHash.?);
}

test "propagates hash changes up the tree when updating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "A.txt", "content A"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "B.txt", "content B"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "C.txt", "content C"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "D.txt", "content D"));
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    // Record original node hashes using depth-first traversal
    var originalHashes: HashRecorder = .{ .allocator = allocator, .hashes = .empty };
    try traverse.traverseTreeAsync(MerkleNode, tree.merkle, &originalHashes, HashRecorder.record);

    // Update one file
    const updatedFileC = try createHashedItem(allocator, "C.txt", "updated content C");
    tree = try merkle_tree.upsertItem(allocator, &tree, updatedFileC);
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    try std.testing.expectEqualSlices(u8, updatedFileC.hash, (merkle_tree.findItemInTree(tree.sort, "C.txt")).?.contentHash.?);

    //        Root(0)
    //       /      \
    //    AB(1)    CD(4)
    //   /  \      /  \
    //  A(2) B(3) C(5) D(6)
    var newHashes: HashRecorder = .{ .allocator = allocator, .hashes = .empty };
    try traverse.traverseTreeAsync(MerkleNode, tree.merkle, &newHashes, HashRecorder.record);

    const original = originalHashes.hashes.items;
    const updated = newHashes.hashes.items;
    try std.testing.expect(!std.mem.eql(u8, updated[5], original[5])); // C node hash changed
    try std.testing.expect(!std.mem.eql(u8, updated[4], original[4])); // CD node hash changed
    try std.testing.expect(!std.mem.eql(u8, updated[0], original[0])); // Root hash changed
    try std.testing.expectEqualSlices(u8, original[2], updated[2]); // A node hash unchanged
    try std.testing.expectEqualSlices(u8, original[3], updated[3]); // B node hash unchanged
    try std.testing.expectEqualSlices(u8, original[1], updated[1]); // AB node hash unchanged
    try std.testing.expectEqualSlices(u8, original[6], updated[6]); // D node hash unchanged
}

test "handle updates with identical content (no change needed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file1.txt", "original content"));
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.
    const originalRootHash = tree.merkle.?.hash;

    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file1.txt", "original content"));
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    try std.testing.expectEqualSlices(u8, originalRootHash, tree.merkle.?.hash);
}

test "handles multiple add/update operations on files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file1.txt", "content 1"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file2.txt", "content 2"));
    try std.testing.expectEqual(@as(u32, 2), tree.sort.?.leafCount);

    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file1.txt", "updated content 1"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file3.txt", "content 3"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file2.txt", "updated content 2"));
    tree = try merkle_tree.upsertItem(allocator, &tree, try createHashedItem(allocator, "file3.txt", "updated content 3"));

    try std.testing.expectEqual(@as(u32, 3), tree.sort.?.leafCount);
    try std.testing.expectEqualSlices(u8, try merkle_verify.sha256(allocator, "updated content 1"), (merkle_tree.findItemInTree(tree.sort, "file1.txt")).?.contentHash.?);
    try std.testing.expectEqualSlices(u8, try merkle_verify.sha256(allocator, "updated content 2"), (merkle_tree.findItemInTree(tree.sort, "file2.txt")).?.contentHash.?);
    try std.testing.expectEqualSlices(u8, try merkle_verify.sha256(allocator, "updated content 3"), (merkle_tree.findItemInTree(tree.sort, "file3.txt")).?.contentHash.?);
}

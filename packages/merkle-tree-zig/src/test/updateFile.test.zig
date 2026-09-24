//
// Tests for updateItem (port of src/test/updateFile.test.ts).
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

test "should update a file and recalculate hashes along the path to root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const file1 = try createHashedItem(allocator, "file1.txt", "original content 1");
    tree = try merkle_tree.addItem(allocator, &tree, file1);
    tree = try merkle_tree.addItem(allocator, &tree, try createHashedItem(allocator, "file2.txt", "original content 2"));
    tree = try merkle_tree.addItem(allocator, &tree, try createHashedItem(allocator, "file3.txt", "original content 3"));
    tree = try merkle_tree.addItem(allocator, &tree, try createHashedItem(allocator, "file4.txt", "original content 4"));
    tree = try merkle_tree.addItem(allocator, &tree, try createHashedItem(allocator, "file5.txt", "original content 5"));
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    // Get the root hash before update
    const originalRootHash = tree.merkle.?.hash;

    // Now update file3
    const updatedFile3 = try createHashedItem(allocator, "file3.txt", "UPDATED content 3");
    const updated = try merkle_tree.updateItem(&tree, updatedFile3);
    tree.dirty = false;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort); // Force tree rebuild.

    try std.testing.expect(updated);

    // The root hash should have changed
    try std.testing.expect(!std.mem.eql(u8, originalRootHash, tree.merkle.?.hash));

    // Verify the file was actually updated
    try std.testing.expectEqualSlices(u8, updatedFile3.hash, (merkle_tree.findItemInTree(tree.sort, "file3.txt")).?.contentHash.?);

    // All other files should remain unchanged
    try std.testing.expectEqualSlices(u8, file1.hash, (merkle_tree.findItemInTree(tree.sort, "file1.txt")).?.contentHash.?);

    // Update a non-existent file should return false
    try std.testing.expect(!try merkle_tree.updateItem(&tree, try createHashedItem(allocator, "not-exists.txt", "content")));
}

//
// Checks each internal merkle node's hash equals the combined hash of its children.
//
fn verifyNodeHash(allHashesValid: *bool, currentNode: *MerkleNode) anyerror!bool {
    // Leaf nodes can't be verified this way
    if (currentNode.left == null and currentNode.right == null) {
        return true; // Continue traversal
    }

    // For internal nodes, recalculate hash from children
    const expectedHash = merkle_tree.combineHashes(currentNode.left.?.hash, currentNode.right.?.hash);
    if (!std.mem.eql(u8, &expectedHash, currentNode.hash)) {
        allHashesValid.* = false;
        return false; // Stop traversal on first error
    }
    return true; // Continue traversal
}

test "should preserve hash integrity through the entire tree after update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const fileNames = [_][]const u8{ "A.txt", "B.txt", "C.txt", "D.txt", "E.txt", "F.txt", "G.txt" };
    var originalHashes: [fileNames.len][]const u8 = undefined;

    for (fileNames, 0..) |fileName, index| {
        const content = try std.fmt.allocPrint(allocator, "Original content of {s}", .{fileName});
        const fileHash = try createHashedItem(allocator, fileName, content);
        originalHashes[index] = fileHash.hash;
        tree = try merkle_tree.addItem(allocator, &tree, fileHash);
    }

    // Update one of the files
    const updateFileName = "D.txt";
    const updatedFile = try createHashedItem(allocator, updateFileName, "UPDATED CONTENT!");
    try std.testing.expect(try merkle_tree.updateItem(&tree, updatedFile));

    // Verify the entire tree starting from the root
    var treeIntegrity = true;
    try traverse.traverseTreeAsync(MerkleNode, tree.merkle, &treeIntegrity, verifyNodeHash);
    try std.testing.expect(treeIntegrity);

    // Verify all non-updated files still have their original hash
    for (fileNames, originalHashes) |fileName, originalHash| {
        if (!std.mem.eql(u8, fileName, updateFileName)) {
            try std.testing.expectEqualSlices(u8, originalHash, (merkle_tree.findItemInTree(tree.sort, fileName)).?.contentHash.?);
        }
    }

    // Verify the updated file has the new hash
    try std.testing.expectEqualSlices(u8, updatedFile.hash, (merkle_tree.findItemInTree(tree.sort, updateFileName)).?.contentHash.?);
}

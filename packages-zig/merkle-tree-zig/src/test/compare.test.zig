//
// Tests for compareTrees (port of src/test/compare.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const compare = merkle_tree_zig.compare;
const IMerkleTree = merkle_tree.IMerkleTree;
const HashedItem = merkle_tree.HashedItem;

//
// Helper function to create a file hash
//
fn createHashedItem(allocator: std.mem.Allocator, name: []const u8, content: []const u8) !HashedItem {
    return merkle_verify.createSha256HashedItem(allocator, name, content, content.len);
}

//
// Builds a tree of files whose content is their name.
//
fn buildTree(allocator: std.mem.Allocator, fileNames: []const []const u8) !IMerkleTree {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);

    for (fileNames) |fileName| {
        tree = try merkle_tree.addItem(allocator, &tree, try createHashedItem(allocator, fileName, fileName));
    }

    // Build the merkle tree from the sort tree
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    return tree;
}

//
// The two trees most of the tests compare.
//
const TestTrees = struct {
    // The first tree.
    treeA: IMerkleTree,

    // The second tree.
    treeB: IMerkleTree,
};

//
// Helper function to build test trees
//
fn buildTestTrees(allocator: std.mem.Allocator) !TestTrees {
    // Create first tree
    var treeA = try buildTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" });
    try merkle_tree.deleteItem(allocator, &treeA, "file3.txt");
    treeA.merkle = try merkle_tree.buildMerkleTree(allocator, treeA.sort);
    treeA.dirty = false;

    // Create second tree with differences
    var treeB = try buildTree(allocator, &.{"file1.txt"});
    treeB = try merkle_tree.addItem(allocator, &treeB, try createHashedItem(allocator, "file4.txt", "Modified content")); // Modified
    treeB = try merkle_tree.addItem(allocator, &treeB, try createHashedItem(allocator, "file5.txt", "file5.txt"));
    treeB = try merkle_tree.addItem(allocator, &treeB, try createHashedItem(allocator, "file6.txt", "file6.txt")); // New file
    treeB.merkle = try merkle_tree.buildMerkleTree(allocator, treeB.sort);
    treeB.dirty = false;

    return .{
        .treeA = treeA,
        .treeB = treeB,
    };
}

//
// Whether a list of names contains a name.
//
fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }
    return false;
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

test "should identify files only in first tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trees = try buildTestTrees(allocator);

    const diff = try compare.compareTrees(allocator, &trees.treeA, &trees.treeB, null);

    // File2 exists in A but not in B
    try std.testing.expect(contains(diff.onlyInA, "file2.txt"));

    // File3 is deleted in A, so shouldn't be in onlyInA
    try std.testing.expect(!contains(diff.onlyInA, "file3.txt"));
}

test "should identify files only in second tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trees = try buildTestTrees(allocator);

    const diff = try compare.compareTrees(allocator, &trees.treeA, &trees.treeB, null);

    // File6 exists in B but not in A
    try std.testing.expect(contains(diff.onlyInB, "file6.txt"));
}

test "should identify modified files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trees = try buildTestTrees(allocator);

    const diff = try compare.compareTrees(allocator, &trees.treeA, &trees.treeB, null);

    // File4 is modified (different content)
    try std.testing.expect(contains(diff.modified, "file4.txt"));

    // File1 and file5 are identical, so shouldn't be in modified
    try std.testing.expect(!contains(diff.modified, "file1.txt"));
    try std.testing.expect(!contains(diff.modified, "file5.txt"));
}

test "should identify deleted files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create two trees with the same files initially
    var treeA = try buildTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" });
    const treeB = try buildTree(allocator, &.{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" });

    // Delete file3 from treeA
    try merkle_tree.deleteItem(allocator, &treeA, "file3.txt");
    treeA.merkle = try merkle_tree.buildMerkleTree(allocator, treeA.sort);
    treeA.dirty = false;

    const diff = try compare.compareTrees(allocator, &treeA, &treeB, null);

    // file3 should be in the onlyInB category (exists in B but not in A)
    try std.testing.expect(contains(diff.onlyInB, "file3.txt"));
}

test "should handle identical trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const treeA = try buildTree(allocator, &.{ "file1.txt", "file2.txt" });
    const treeB = try buildTree(allocator, &.{ "file1.txt", "file2.txt" });

    const diff = try compare.compareTrees(allocator, &treeA, &treeB, null);

    // Should have no differences
    try expectNames(&.{}, diff.onlyInA);
    try expectNames(&.{}, diff.onlyInB);
    try expectNames(&.{}, diff.modified);
}

test "should handle completely different trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const treeA = try buildTree(allocator, &.{ "fileA.txt", "fileB.txt" });
    const treeB = try buildTree(allocator, &.{ "fileC.txt", "fileD.txt" });

    const diff = try compare.compareTrees(allocator, &treeA, &treeB, null);

    // All files should be in their respective "only in" categories
    try expectNames(&.{ "fileA.txt", "fileB.txt" }, diff.onlyInA);
    try expectNames(&.{ "fileC.txt", "fileD.txt" }, diff.onlyInB);
    try expectNames(&.{}, diff.modified);
}

//
// A file of a tree built by buildTreeWithContent.
//
const TestFile = struct {
    // The name of the file.
    name: []const u8,

    // The content of the file.
    content: []const u8,
};

//
// Builds a tree of files with the given content.
//
fn buildTreeWithContent(allocator: std.mem.Allocator, files: []const TestFile) !IMerkleTree {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    for (files) |file| {
        tree = try merkle_tree.addItem(allocator, &tree, try createHashedItem(allocator, file.name, file.content));
    }
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    return tree;
}

//
// The merkle diff counts hashes, so it sees one of these two as present and the other as missing
// according to the order it visits them, and names the wrong one when the one B holds is
// visited second.
//
test "a name only in A is reported even when B holds its content under another name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const photo = "the same photo imported twice";
    const treeA = try buildTreeWithContent(allocator, &.{
        .{
            .name = "asset/first-import",
            .content = photo,
        },
        .{
            .name = "asset/second-import",
            .content = photo,
        },
    });
    const treeB = try buildTreeWithContent(allocator, &.{
        .{
            .name = "asset/second-import",
            .content = photo,
        },
    });

    const diff = try compare.compareTrees(allocator, &treeA, &treeB, null);

    try expectNames(&.{"asset/first-import"}, diff.onlyInA);
    try expectNames(&.{}, diff.onlyInB);
    try expectNames(&.{}, diff.modified);
}

test "a name only in B is reported even when A holds its content under another name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const photo = "the same photo imported twice";
    const treeA = try buildTreeWithContent(allocator, &.{
        .{
            .name = "asset/second-import",
            .content = photo,
        },
    });
    const treeB = try buildTreeWithContent(allocator, &.{
        .{
            .name = "asset/first-import",
            .content = photo,
        },
        .{
            .name = "asset/second-import",
            .content = photo,
        },
    });

    const diff = try compare.compareTrees(allocator, &treeA, &treeB, null);

    try expectNames(&.{}, diff.onlyInA);
    try expectNames(&.{"asset/first-import"}, diff.onlyInB);
    try expectNames(&.{}, diff.modified);
}

//
// Records the progress messages it is given.
//
const ProgressRecorder = struct {
    // The number of messages received.
    count: u32 = 0,

    // The last message received.
    lastMessage: []const u8 = "",

    //
    // The callback function.
    //
    fn record(context: ?*anyopaque, progress: []const u8) void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(context.?));
        self.count += 1;
        self.lastMessage = progress;
    }
};

test "compareTrees reports its progress to the callback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const treeA = try buildTree(allocator, &.{"file1.txt"});
    const treeB = try buildTree(allocator, &.{"file1.txt"});
    var recorder: ProgressRecorder = .{};

    _ = try compare.compareTrees(allocator, &treeA, &treeB, .{
        .context = &recorder,
        .function = ProgressRecorder.record,
    });

    try std.testing.expectEqual(@as(u32, 1), recorder.count);
    try std.testing.expectEqualStrings("Comparing merkle trees...", recorder.lastMessage);
}

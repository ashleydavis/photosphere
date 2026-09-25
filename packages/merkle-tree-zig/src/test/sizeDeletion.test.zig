//
// Size calculation with file deletion (port of src/test/sizeDeletion.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;

//
// Helper to build a test tree with files of specific sizes
//
fn buildTestTree(allocator: std.mem.Allocator) !IMerkleTree {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const names = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" };
    const contents = [_][]const u8{ "content 1", "content 2", "content 3", "content 4", "content 5" };
    const sizes = [_]u64{ 1000, 2000, 3000, 4000, 5000 };
    for (names, contents, sizes) |name, content, size| {
        tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, name, content, size));
    }
    return tree;
}

test "deleting a file removes it completely from the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    try std.testing.expectEqual(@as(u64, 3000), (merkle_tree.findItemInTree(tree.sort, "file3.txt")).?.size);
    try merkle_tree.deleteItem(allocator, &tree, "file3.txt");
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file3.txt")) == null);
}

test "deleting a file updates parent node sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    try std.testing.expectEqual(@as(u64, 15000), tree.sort.?.size);
    try merkle_tree.deleteItem(allocator, &tree, "file3.txt");
    try std.testing.expectEqual(@as(u64, 12000), tree.sort.?.size);
}

test "deleting multiple files correctly updates size throughout the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    try std.testing.expectEqual(@as(u64, 15000), tree.sort.?.size);
    try merkle_tree.deleteItem(allocator, &tree, "file1.txt"); // -1000
    try merkle_tree.deleteItem(allocator, &tree, "file4.txt"); // -4000
    try std.testing.expectEqual(@as(u64, 10000), tree.sort.?.size);
    try merkle_tree.deleteItem(allocator, &tree, "file5.txt"); // -5000
    try std.testing.expectEqual(@as(u64, 5000), tree.sort.?.size);
}

test "sizes are correctly propagated up through all parent nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const fileSizes = [_]u64{ 100, 200, 300, 400, 500, 600, 700 };
    for (fileSizes, 0..) |size, index| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{index});
        const content = try std.fmt.allocPrint(allocator, "content {d}", .{index});
        tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, name, content, size));
    }
    try std.testing.expectEqual(@as(u64, 2800), tree.sort.?.size);

    try merkle_tree.deleteItem(allocator, &tree, "file2.txt");
    try std.testing.expect((merkle_tree.findItemInTree(tree.sort, "file2.txt")) == null);
    try std.testing.expectEqual(@as(u64, 2800 - 300), tree.sort.?.size);
}

test "totalSize in metadata correctly reflects all deletions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTestTree(allocator);
    try merkle_tree.deleteItem(allocator, &tree, "file1.txt");
    try std.testing.expectEqual(@as(u64, 14000), tree.sort.?.size);
    try merkle_tree.deleteItem(allocator, &tree, "file3.txt");
    try std.testing.expectEqual(@as(u64, 11000), tree.sort.?.size);
    try merkle_tree.deleteItem(allocator, &tree, "file5.txt");
    try std.testing.expectEqual(@as(u64, 6000), tree.sort.?.size);
}

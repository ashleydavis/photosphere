//
// Size calculation with file addition (port of src/test/sizeAddition.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;

test "leaf node should have size equal to file length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fileSize: u64 = 1024;
    const emptyTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const tree = try merkle_tree.addItem(allocator, &emptyTree, try merkle_verify.createSha256HashedItem(allocator, "test.txt", "test content", fileSize));
    try std.testing.expectEqual(fileSize, tree.sort.?.size);
}

test "parent node should have size equal to sum of children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "file1.txt", "content 1", 500));
    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "file2.txt", "content 2", 1000));

    try std.testing.expectEqual(@as(u64, 1500), tree.sort.?.size);
    try std.testing.expectEqual(@as(u64, 500), tree.sort.?.left.?.size);
    try std.testing.expectEqual(@as(u64, 1000), tree.sort.?.right.?.size);
}

test "sizes are propagated correctly in a multi-level tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const sizes = [_]u64{ 100, 200, 300, 400, 500, 600, 700 };
    for (sizes, 0..) |size, index| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{index});
        const content = try std.fmt.allocPrint(allocator, "content {d}", .{index});
        tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, name, content, size));
    }

    try std.testing.expectEqual(@as(u64, 2800), tree.sort.?.size);
    try std.testing.expectEqual(@as(u64, 1500), tree.sort.?.left.?.size);
    try std.testing.expectEqual(@as(u64, 1300), tree.sort.?.right.?.size);
}

test "size is updated when adding files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    try std.testing.expect(tree.sort == null);

    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "file1.txt", "content 1", 1000));
    try std.testing.expectEqual(@as(u64, 1000), tree.sort.?.size);

    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "file2.txt", "content 2", 2000));
    try std.testing.expectEqual(@as(u64, 3000), tree.sort.?.size);

    tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, "file3.txt", "content 3", 3000));
    try std.testing.expectEqual(@as(u64, 6000), tree.sort.?.size);
}

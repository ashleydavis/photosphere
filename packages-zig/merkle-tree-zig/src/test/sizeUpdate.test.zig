//
// Size calculation with file updates (port of src/test/sizeUpdate.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const createSha256HashedItem = merkle_verify.createSha256HashedItem;

test "updating file size updates node size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "test.txt", "initial content", 1000));
    try std.testing.expectEqual(@as(u64, 1000), tree.sort.?.size);

    const updated = try merkle_tree.updateItem(&tree, try createSha256HashedItem(allocator, "test.txt", "updated content", 2000));
    try std.testing.expect(updated);
    try std.testing.expectEqual(@as(u64, 2000), (merkle_tree.findItemInTree(tree.sort, "test.txt")).?.size);
    try std.testing.expectEqual(@as(u64, 2000), tree.sort.?.size);
}

test "updating file propagates size changes up the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "file1.txt", "content 1", 1000));
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "file2.txt", "content 2", 2000));
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "file3.txt", "content 3", 3000));
    try std.testing.expectEqual(@as(u64, 6000), tree.sort.?.size);

    _ = try merkle_tree.updateItem(&tree, try createSha256HashedItem(allocator, "file2.txt", "updated content 2", 5000));
    try std.testing.expectEqual(@as(u64, 5000), (merkle_tree.findItemInTree(tree.sort, "file2.txt")).?.size);
    try std.testing.expectEqual(@as(u64, 9000), tree.sort.?.size);
}

test "updating file to smaller size properly reduces tree size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "file1.txt", "content 1", 1000));
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "file2.txt", "content 2", 2000));
    tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, "file3.txt", "content 3", 3000));
    try std.testing.expectEqual(@as(u64, 6000), tree.sort.?.size);

    _ = try merkle_tree.updateItem(&tree, try createSha256HashedItem(allocator, "file3.txt", "smaller content", 1500));
    try std.testing.expectEqual(@as(u64, 4500), tree.sort.?.size);
}

test "size is correctly maintained in a complex tree with multiple updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    const initialSizes = [_]u64{ 100, 200, 300, 400, 500, 600, 700 };
    for (initialSizes, 0..) |size, index| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{index});
        const content = try std.fmt.allocPrint(allocator, "content {d}", .{index});
        tree = try merkle_tree.addItem(allocator, &tree, try createSha256HashedItem(allocator, name, content, size));
    }
    try std.testing.expectEqual(@as(u64, 2800), tree.sort.?.size);

    _ = try merkle_tree.updateItem(&tree, try createSha256HashedItem(allocator, "file1.txt", "updated content 1", 250)); // +50
    _ = try merkle_tree.updateItem(&tree, try createSha256HashedItem(allocator, "file3.txt", "updated content 3", 350)); // -50
    _ = try merkle_tree.updateItem(&tree, try createSha256HashedItem(allocator, "file5.txt", "updated content 5", 800)); // +200

    try std.testing.expectEqual(@as(u64, 2800 + 50 - 50 + 200), tree.sort.?.size);
    try std.testing.expectEqual(@as(u64, 250), (merkle_tree.findItemInTree(tree.sort, "file1.txt")).?.size);
    try std.testing.expectEqual(@as(u64, 350), (merkle_tree.findItemInTree(tree.sort, "file3.txt")).?.size);
    try std.testing.expectEqual(@as(u64, 800), (merkle_tree.findItemInTree(tree.sort, "file5.txt")).?.size);
}

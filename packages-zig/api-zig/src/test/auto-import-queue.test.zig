const std = @import("std");
const api_zig = @import("api-zig");
const AutoImportQueue = api_zig.auto_import_queue.AutoImportQueue;
const IMediaItem = api_zig.media_source.IMediaItem;

//
// Makes a media item with the given source id. The other fields do not matter here, which is the
// point: this class decides order, nothing else.
//
fn mediaItem(allocator: std.mem.Allocator, sourceId: []const u8) !IMediaItem {
    return .{
        .sourceId = sourceId,
        .filePath = try std.fmt.allocPrint(allocator, "/photos/{s}", .{sourceId}),
        .displayName = sourceId,
        .contentType = "image/jpeg",
        .size = 1000,
        .createdAt = 1767225600000, // 2026-01-01T00:00:00.000Z
    };
}

//
// Makes a list of media items named item-0, item-1 and so on.
//
fn mediaItems(allocator: std.mem.Allocator, count: usize) ![]const IMediaItem {
    var items: std.ArrayList(IMediaItem) = .empty;
    for (0..count) |index| {
        try items.append(allocator, try mediaItem(allocator, try std.fmt.allocPrint(allocator, "item-{d}", .{index})));
    }

    return items.items;
}

//
// Takes items from the queue until it gives nothing back, and returns their ids.
//
// The limit is a backstop: a queue that never ran dry would otherwise hang the test.
//
fn drain(allocator: std.mem.Allocator, queue: *AutoImportQueue) ![]const []const u8 {
    const limit = 10000;
    var released: std.ArrayList([]const u8) = .empty;
    while (released.items.len < limit) {
        const item = queue.nextItem() orelse {
            return released.items;
        };
        try released.append(allocator, item.sourceId);
    }

    return released.items;
}

//
// Asserts that two lists of ids are equal (TypeScript: `toEqual`).
//
fn expectIds(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedId, actualId| {
        try std.testing.expectEqualStrings(expectedId, actualId);
    }
}

test "nothing is released from an empty queue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var queue = AutoImportQueue.init(arena.allocator());

    try std.testing.expect(queue.nextItem() == null);
}

test "everything offered comes straight out, with nothing held back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The whole point of removing the rate limit: a library offered to the queue is available
    // as fast as the import can take it, rather than at a fixed number a minute.
    var queue = AutoImportQueue.init(allocator);
    _ = try queue.addItems(try mediaItems(allocator, 500));

    try std.testing.expectEqual(@as(usize, 500), (try drain(allocator, &queue)).len);
}

test "items come out in the order they were offered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var queue = AutoImportQueue.init(allocator);
    _ = try queue.addItems(try mediaItems(allocator, 3));

    try expectIds(&.{ "item-0", "item-1", "item-2" }, try drain(allocator, &queue));
}

test "a photo offered later is still released, behind what was already waiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A photo taken during an import: it goes to the back of what is queued, and because items
    // come out one at a time it is never behind more than the one being imported now.
    var queue = AutoImportQueue.init(allocator);
    _ = try queue.addItems(try mediaItems(allocator, 2));
    _ = try queue.addItems(&.{try mediaItem(allocator, "just-taken.jpg")});

    try expectIds(&.{ "item-0", "item-1", "just-taken.jpg" }, try drain(allocator, &queue));
}

test "an item already queued is not queued a second time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Every run reads the source from the beginning, so the same items are offered over and
    // over. Without this a library would be imported once per page fetch.
    var queue = AutoImportQueue.init(allocator);

    try std.testing.expectEqual(@as(usize, 3), try queue.addItems(try mediaItems(allocator, 3)));
    try std.testing.expectEqual(@as(usize, 0), try queue.addItems(try mediaItems(allocator, 3)));
    try expectIds(&.{ "item-0", "item-1", "item-2" }, try drain(allocator, &queue));
}

test "an item is not queued again after it has been released" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var queue = AutoImportQueue.init(allocator);
    _ = try queue.addItems(&.{try mediaItem(allocator, "photo.jpg")});
    _ = queue.nextItem();

    try std.testing.expectEqual(@as(usize, 0), try queue.addItems(&.{try mediaItem(allocator, "photo.jpg")}));
    try std.testing.expect(queue.nextItem() == null);
}

test "what is waiting is reported until it has all been released" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var queue = AutoImportQueue.init(allocator);
    try std.testing.expectEqual(false, queue.hasPending());
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());

    _ = try queue.addItems(try mediaItems(allocator, 2));
    try std.testing.expectEqual(true, queue.hasPending());
    try std.testing.expectEqual(@as(usize, 2), queue.pendingCount());

    _ = queue.nextItem();
    try std.testing.expectEqual(@as(usize, 1), queue.pendingCount());

    _ = queue.nextItem();
    try std.testing.expectEqual(false, queue.hasPending());
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());
}

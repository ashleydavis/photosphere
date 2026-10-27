const std = @import("std");
const utils = @import("utils-zig");
const batchGenerator = utils.batch_generator.batchGenerator;

//
// An iterator over the items of an array.
//
const ArrayIterator = struct {
    // The items yielded.
    items: []const u32,

    // The index of the next item to yield.
    index: usize = 0,

    //
    // Returns the next item, or null when every item has been yielded.
    //
    pub fn next(self: *ArrayIterator, _: utils.log.ILog) !?u32 {
        if (self.index >= self.items.len) {
            return null;
        }
        const item = self.items[self.index];
        self.index += 1;
        return item;
    }
};

//
// Helper to collect all batches from batchGenerator into an array.
//
fn collectBatches(log: utils.log.ILog, allocator: std.mem.Allocator, items: []const u32, batchSize: usize) ![]const []u32 {
    var source: ArrayIterator = .{ .items = items };
    var generator = batchGenerator(u32, allocator, &source, batchSize);
    var batches: std.ArrayList([]u32) = .empty;
    while (try generator.next(log)) |batch| {
        try batches.append(allocator, batch);
    }
    return batches.items;
}

//
// Checks that the batches are the expected ones.
//
fn expectBatches(expected: []const []const u32, actual: []const []u32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedBatch, actualBatch| {
        try std.testing.expectEqualSlices(u32, expectedBatch, actualBatch);
    }
}

test "yields nothing for an empty source" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(log, arena.allocator(), &.{}, 3);
    try expectBatches(&.{}, batches);
}

test "yields a single full batch when count equals batch size" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(log, arena.allocator(), &.{ 1, 2, 3 }, 3);
    try expectBatches(&.{&.{ 1, 2, 3 }}, batches);
}

test "yields multiple full batches" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(log, arena.allocator(), &.{ 1, 2, 3, 4, 5, 6 }, 3);
    try expectBatches(&.{ &.{ 1, 2, 3 }, &.{ 4, 5, 6 } }, batches);
}

test "yields a partial final batch when count is not a multiple of batch size" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(log, arena.allocator(), &.{ 1, 2, 3, 4, 5 }, 3);
    try expectBatches(&.{ &.{ 1, 2, 3 }, &.{ 4, 5 } }, batches);
}

test "yields one batch per item when batch size is 1" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(log, arena.allocator(), &.{ 1, 2, 3 }, 1);
    try expectBatches(&.{ &.{1}, &.{2}, &.{3} }, batches);
}

test "yields a single batch when batch size exceeds item count" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(log, arena.allocator(), &.{ 1, 2, 3 }, 100);
    try expectBatches(&.{&.{ 1, 2, 3 }}, batches);
}

//
// A source of one item that keeps the pointer of the log its `next` is given.
//
const LogKeepingSource = struct {
    // The pointer of the log `next` was last given, or null before it is called.
    given: ?*anyopaque = null,

    // Whether the one item has been yielded.
    yielded: bool = false,

    //
    // Keeps the log and yields one item.
    //
    pub fn next(self: *LogKeepingSource, log: utils.log.ILog) !?u32 {
        self.given = log.ptr;
        if (self.yielded) {
            return null;
        }
        self.yielded = true;
        return 1;
    }
};

test "next gives the source the log it is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source: LogKeepingSource = .{};
    const batch_log = utils.mute_log.MuteLog.init();
    var generator = batchGenerator(u32, arena.allocator(), &source, 10);
    _ = try generator.next(batch_log);
    try std.testing.expect(source.given == @as(?*anyopaque, batch_log.ptr));
}

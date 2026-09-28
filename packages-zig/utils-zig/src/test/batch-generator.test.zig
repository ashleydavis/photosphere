const std = @import("std");
const utils = @import("utils-zig");
const batchGenerator = utils.batch_generator.batchGenerator;

//
// An iterator over the items of an array (TypeScript: the fromArray async generator).
//
const ArrayIterator = struct {
    // The items yielded.
    items: []const u32,

    // The index of the next item to yield.
    index: usize = 0,

    //
    // Returns the next item, or null when every item has been yielded.
    //
    pub fn next(self: *ArrayIterator) !?u32 {
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
fn collectBatches(allocator: std.mem.Allocator, items: []const u32, batchSize: usize) ![]const []u32 {
    var source: ArrayIterator = .{ .items = items };
    var generator = batchGenerator(u32, allocator, &source, batchSize);
    var batches: std.ArrayList([]u32) = .empty;
    while (try generator.next()) |batch| {
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(arena.allocator(), &.{}, 3);
    try expectBatches(&.{}, batches);
}

test "yields a single full batch when count equals batch size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(arena.allocator(), &.{ 1, 2, 3 }, 3);
    try expectBatches(&.{&.{ 1, 2, 3 }}, batches);
}

test "yields multiple full batches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(arena.allocator(), &.{ 1, 2, 3, 4, 5, 6 }, 3);
    try expectBatches(&.{ &.{ 1, 2, 3 }, &.{ 4, 5, 6 } }, batches);
}

test "yields a partial final batch when count is not a multiple of batch size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(arena.allocator(), &.{ 1, 2, 3, 4, 5 }, 3);
    try expectBatches(&.{ &.{ 1, 2, 3 }, &.{ 4, 5 } }, batches);
}

test "yields one batch per item when batch size is 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(arena.allocator(), &.{ 1, 2, 3 }, 1);
    try expectBatches(&.{ &.{1}, &.{2}, &.{3} }, batches);
}

test "yields a single batch when batch size exceeds item count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batches = try collectBatches(arena.allocator(), &.{ 1, 2, 3 }, 100);
    try expectBatches(&.{&.{ 1, 2, 3 }}, batches);
}

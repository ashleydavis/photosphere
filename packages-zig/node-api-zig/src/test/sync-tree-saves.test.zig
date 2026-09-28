//
// Tests for the periodic save of the target's merkle tree during a push (port of
// src/test/lib/sync-tree-saves.test.ts).
//
// It exists so an interrupted push does not start again from nothing, and it is meant to happen every
// hundred files. Zero divides by a hundred exactly, so a push that copied nothing saved the whole
// tree after every leaf it looked at instead. Measured on a Pixel 6 pushing to an S3 origin holding
// 8,481 photos, one pass reported:
//
//   {"filesCopied":0,"leavesVisited":99,"copyFileMs":11,"treeSaveMs":2751699,"elapsedMs":2753394}
//
// 46 minutes, of which 11 milliseconds was the copying and all the rest was writing a megabyte of
// merkle tree back, once per leaf, to record that nothing had changed.
//

const std = @import("std");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const SpyStorage = sync_helpers.SpyStorage;
const pushFiles = node_api.sync.pushFiles;
const throughTheDatabases = node_api.sync.throughTheDatabases;

//
// The id of the test databases.
//
const dbId = "6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";

//
// Names count files from a pattern: `<prefix><index><suffix>`, the index padded to three digits when asked
// (TypeScript: `Array.from({ length }, (_, index) => ...)`).
//
fn namesFrom(allocator: std.mem.Allocator, count: usize, prefix: []const u8, suffix: []const u8, padded: bool) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, count);
    for (names, 0..) |*name, index| {
        name.* = if (padded)
            try std.fmt.allocPrint(allocator, "{s}{d:0>3}{s}", .{ prefix, index, suffix })
        else
            try std.fmt.allocPrint(allocator, "{s}{d}{s}", .{ prefix, index, suffix });
    }
    return names;
}

//
// A push that only copies, into a target that counts its tree writes (TypeScript: countTreeWrites).
//
fn pushCountingTreeWrites(allocator: std.mem.Allocator, io: std.Io, source: *MemoryStorage, targetStore: *MemoryStorage) !*SpyStorage {
    const target = try allocator.create(SpyStorage);
    target.* = .{ .allocator = allocator, .inner = targetStore.asStorage() };
    try pushFiles(allocator, io, source.asStorage(), target.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage()), throughTheDatabases(source.asStorage(), target.storage()));
    return target;
}

//
// A pass that put nothing in the tree leaves it exactly as it was loaded, so writing it back
// sends a megabyte to say so. On a Pixel 6 pushing to an origin holding 8,481 photos that write
// took twenty-nine seconds of a thirty-one second pass, every five minutes, on the same
// connection the import was trying to use.
//
test "a push that copies nothing does not write the tree back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const shared = try namesFrom(allocator, 3, "asset/shared-", ".jpg", false);

    // The target holds everything the source does and more, so the trees differ (the push is not
    // skipped) and yet there is nothing for the push to copy.
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, shared), &.{});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, try sync_helpers.filesNamed(allocator, try std.mem.concat(allocator, []const u8, &.{ shared, &.{"asset/only-at-the-target.jpg"} })), &.{});

    const counted = try pushCountingTreeWrites(allocator, io, &source, &target);

    try std.testing.expectEqual(@as(u32, 0), counted.treeWrites);
}

//
// The save is meant to happen every hundred files, and it is reached once per leaf, so a count
// resting on a multiple of a hundred saved the whole tree again for every leaf walked and matched
// after it. That is the same megabyte per leaf the zero case was, needing only a hundred copies
// in front of it.
//
test "a run of leaves that copy nothing after the hundredth file does not write the tree again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    // A hundred files to copy, named so they sort first, and then a long run of leaves the push
    // walks and copies nothing for because their assets are deleted. That is the count resting on
    // a hundred while leaf after leaf goes by, which is what a real library does: a Pixel 6
    // pushing to an origin it shares most of its photos with walked 479 leaves and copied 98.
    // (Zig: the TypeScript test's deleted ids are `z-000.jpg` and so on, which its stand-in bson database accepts; a
    // real BsonDatabase only takes ids that are hex, so these are hex ids that sort after `a-`.)
    const toCopy = try namesFrom(allocator, 100, "asset/a-", ".jpg", true);
    const deleted = try namesFrom(allocator, 50, "fe000000-0000-0000-0000-000000000", "", true);
    const deletedPaths = try namesFrom(allocator, 50, "asset/fe000000-0000-0000-0000-000000000", "", true);

    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, try std.mem.concat(allocator, []const u8, &.{ toCopy, deletedPaths })), deleted);
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, &.{}, &.{});

    const counted = try pushCountingTreeWrites(allocator, io, &source, &target);

    // The hundredth file's save, and the one at the end of the push.
    try std.testing.expectEqual(@as(u32, 2), counted.treeWrites);
}

test "a push that copies files still saves the tree, so an interrupted one does not start again from nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const fileNames = try namesFrom(allocator, 5, "asset/new-", ".jpg", false);
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, fileNames), &.{});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, &.{}, &.{});

    const counted = try pushCountingTreeWrites(allocator, io, &source, &target);

    try std.testing.expect(counted.treeWrites >= 1);
    for (fileNames) |fileName| {
        try std.testing.expect(try target.asStorage().fileExists(allocator, io, fileName));
    }
}

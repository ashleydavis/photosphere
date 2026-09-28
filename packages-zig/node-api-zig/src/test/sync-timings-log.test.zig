//
// Tests for how often a push says where its time went (port of src/test/lib/sync-timings-log.test.ts).
//
// It is meant to be every twenty files, and zero divides by twenty exactly, so a pass that copied
// nothing said it on every leaf it walked instead. On a Pixel 6 pushing to an origin holding 8,481
// photos that was one line per leaf, thousands of them saying the same thing, and the line that
// mattered (the copy that had failed) was somewhere in the middle of them.
//
// Saying it once at the end covers the pass that copies nothing, which is exactly the pass whose
// time needs explaining: the one that spent forty-six minutes and moved no bytes.
//

const std = @import("std");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const pushFiles = node_api.sync.pushFiles;
const throughTheDatabases = node_api.sync.throughTheDatabases;

//
// The id of the test databases.
//
const dbId = "5b2c3d4e-6f7a-4b8c-9d0e-1f2a3b4c5d6e";

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
// Deleted asset ids, sorted after the files to copy.
// (Zig: the TypeScript test's ids are `z-000.jpg` and so on, which its stand-in bson database accepts; a real
// BsonDatabase only takes ids that are hex, so these are hex ids that sort after `a-`.)
//
fn deletedAssetIds(allocator: std.mem.Allocator, count: usize) ![]const []const u8 {
    return namesFrom(allocator, count, "fe000000-0000-0000-0000-000000000", "", true);
}

//
// The file names of assets.
//
fn assetPaths(allocator: std.mem.Allocator, assetIds: []const []const u8) ![]const []const u8 {
    const paths = try allocator.alloc([]const u8, assetIds.len);
    for (assetIds, 0..) |assetId, index| {
        paths[index] = try std.fmt.allocPrint(allocator, "asset/{s}", .{assetId});
    }
    return paths;
}

//
// Joins two lists of names (TypeScript: `concat`).
//
fn concat(allocator: std.mem.Allocator, first: []const []const u8, second: []const []const u8) ![]const []const u8 {
    return std.mem.concat(allocator, []const u8, &.{ first, second });
}

//
// The leaves a push walks and does not copy are what the counter sat at zero through, and on a
// real library they are nearly all of them: an origin holding 8,481 photos was missing a handful.
//
test "the leaves a push walks without copying say nothing, and the end says it once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const fileNames = try namesFrom(allocator, 40, "asset/same-", ".jpg", false);
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, fileNames), &.{});

    // Every file but the last, so most leaves are walked and matched before anything is copied.
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, try sync_helpers.filesNamed(allocator, fileNames[0 .. fileNames.len - 1]), &.{});

    try pushFiles(allocator, io, source.asStorage(), target.asStorage(), try sync_helpers.makeBsonDatabase(allocator, target.asStorage()), throughTheDatabases(source.asStorage(), target.asStorage()));

    const timingLines = try capture.linesStartingWith(allocator, "Sync timings:");
    try std.testing.expectEqual(@as(usize, 1), timingLines.len);
    try std.testing.expect(std.mem.indexOf(u8, timingLines[0], "\"filesCopied\":1") != null);
}

//
// The line is meant to come every twenty files, and it is reached once per leaf, so a count
// resting on a multiple of twenty said the same thing again for every leaf walked and matched
// after it. On a Pixel 6 that was five identical lines in a row with the count stuck at sixty.
//
test "a run of leaves that copy nothing after the twentieth file says nothing more" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    // Twenty files to copy, named so they sort first, and then a long run of leaves the push
    // walks and copies nothing for because their assets are deleted. That is the count resting on
    // twenty while leaf after leaf goes by, which is what a real library does: a Pixel 6 pushing
    // to an origin it shares most of its photos with walked 479 leaves and copied 98.
    const toCopy = try namesFrom(allocator, 20, "asset/a-", ".jpg", true);
    const deleted = try deletedAssetIds(allocator, 50);

    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, try concat(allocator, toCopy, try assetPaths(allocator, deleted))), deleted);
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, &.{}, &.{});

    try pushFiles(allocator, io, source.asStorage(), target.asStorage(), try sync_helpers.makeBsonDatabase(allocator, target.asStorage()), throughTheDatabases(source.asStorage(), target.asStorage()));

    // The twentieth file's line, and the one at the end of the push.
    try std.testing.expectEqual(@as(usize, 2), (try capture.linesStartingWith(allocator, "Sync timings:")).len);
}

test "a push that copies files says it while it works and again at the end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const fileNames = try namesFrom(allocator, 45, "asset/new-", ".jpg", false);
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, try sync_helpers.filesNamed(allocator, fileNames), &.{});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, &.{}, &.{});

    try pushFiles(allocator, io, source.asStorage(), target.asStorage(), try sync_helpers.makeBsonDatabase(allocator, target.asStorage()), throughTheDatabases(source.asStorage(), target.asStorage()));

    // Twenty and forty files in, then the one at the end.
    const timingLines = try capture.linesStartingWith(allocator, "Sync timings:");
    try std.testing.expectEqual(@as(usize, 3), timingLines.len);
    try std.testing.expect(std.mem.indexOf(u8, timingLines[timingLines.len - 1], "\"filesCopied\":45") != null);
}

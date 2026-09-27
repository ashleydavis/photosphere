const std = @import("std");
const api_zig = @import("api-zig");
const utils = @import("utils-zig");
const media_source = api_zig.media_source;
const IMediaItem = media_source.IMediaItem;
const IMediaSource = media_source.IMediaSource;
const IMediaSourceListPage = media_source.IMediaSourceListPage;
const MediaSourceDeleteError = media_source.MediaSourceDeleteError;
const runSourceCleanup = api_zig.source_cleanup.runSourceCleanup;
const errors = utils.errors;

const io = std.testing.io;

//
// A media source that records the delete requests it was given and answers however the test says.
// This is a test double for the source interface, not for anything under test: the code under test
// is the selection and the batching.
//
const RecordingMediaSource = struct {
    // Allocates the recorded requests.
    allocator: std.mem.Allocator,

    // Each batch of source ids it was asked to delete, in order.
    deleteRequests: std.ArrayList([]const []const u8) = .empty,

    // Ids it refuses, reported through MediaSourceDeleteError.
    refusedSourceIds: []const []const u8 = &.{},

    // Ids whose batch throws something other than a delete error, standing in for a source that
    // failed in a way that says nothing about which items went.
    unexplainedFailureSourceIds: []const []const u8 = &.{},

    //
    // Gets the IMediaSource interface of this source.
    //
    fn asMediaSource(self: *RecordingMediaSource) IMediaSource {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IMediaSource functions of this source.
    //
    const vtable: IMediaSource.VTable = .{
        .listPage = listPage,
        .openItem = openItem,
        .closeItem = closeItem,
        .deleteItems = deleteItems,
    };

    //
    // Lists nothing.
    //
    fn listPage(ptr: *anyopaque, allocator: std.mem.Allocator, listIo: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        _ = ptr;
        _ = allocator;
        _ = listIo;
        _ = cursor;
        _ = pageSize;
        return .{
            .items = &.{},
            .nextCursor = null,
        };
    }

    //
    // Hands back the item's own path.
    //
    fn openItem(ptr: *anyopaque, allocator: std.mem.Allocator, openIo: std.Io, item: IMediaItem) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = openIo;
        return item.filePath;
    }

    //
    // Nothing to release.
    //
    fn closeItem(ptr: *anyopaque, allocator: std.mem.Allocator, closeIo: std.Io, item: IMediaItem) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = closeIo;
        _ = item;
    }

    //
    // Records the request and answers as configured.
    //
    fn deleteItems(ptr: *anyopaque, allocator: std.mem.Allocator, deleteIo: std.Io, sourceIds: []const []const u8) anyerror!void {
        _ = allocator;
        _ = deleteIo;
        const self: *RecordingMediaSource = @ptrCast(@alignCast(ptr));
        try self.deleteRequests.append(self.allocator, try self.allocator.dupe([]const u8, sourceIds));

        for (sourceIds) |sourceId| {
            if (contains(self.unexplainedFailureSourceIds, sourceId)) {
                return errors.throwError("The photo library is unavailable.", .{});
            }
        }

        var refused: std.ArrayList([]const u8) = .empty;
        for (sourceIds) |sourceId| {
            if (contains(self.refusedSourceIds, sourceId)) {
                try refused.append(self.allocator, sourceId);
            }
        }
        if (refused.items.len > 0) {
            return MediaSourceDeleteError.throw(refused.items, "Refused.", .{});
        }
    }
};

//
// True when the list holds the id.
//
fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) {
            return true;
        }
    }
    return false;
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

//
// Asserts that the delete requests were the expected batches, in order.
//
fn expectRequests(expected: []const []const []const u8, actual: []const []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedBatch, actualBatch| {
        try expectIds(expectedBatch, actualBatch);
    }
}

// Not ported: the selectConfirmedForCleanup tests (selectConfirmedForCleanup is not used by psi add).

test "deletes everything in one request when it fits in a batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{ .allocator = allocator };

    const result = try runSourceCleanup(allocator, io, source.asMediaSource(), &.{ "a", "b", "c" }, 50);

    try expectRequests(&.{&.{ "a", "b", "c" }}, source.deleteRequests.items);
    try expectIds(&.{ "a", "b", "c" }, result.deletedSourceIds);
    try expectIds(&.{}, result.failedSourceIds);
}

test "splits the ids into batches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{ .allocator = allocator };

    const result = try runSourceCleanup(allocator, io, source.asMediaSource(), &.{ "a", "b", "c", "d", "e" }, 2);

    try expectRequests(&.{ &.{ "a", "b" }, &.{ "c", "d" }, &.{"e"} }, source.deleteRequests.items);
    try expectIds(&.{ "a", "b", "c", "d", "e" }, result.deletedSourceIds);
}

test "asks for nothing when there is nothing to delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{ .allocator = allocator };

    const result = try runSourceCleanup(allocator, io, source.asMediaSource(), &.{}, 50);

    try expectRequests(&.{}, source.deleteRequests.items);
    try expectIds(&.{}, result.deletedSourceIds);
}

test "reports the ids the source refused and keeps the rest as deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{
        .allocator = allocator,
        .refusedSourceIds = &.{"b"},
    };

    const result = try runSourceCleanup(allocator, io, source.asMediaSource(), &.{ "a", "b", "c" }, 50);

    try expectIds(&.{ "a", "c" }, result.deletedSourceIds);
    try expectIds(&.{"b"}, result.failedSourceIds);
}

test "a batch that fails without saying what happened counts as none deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{
        .allocator = allocator,
        .unexplainedFailureSourceIds = &.{"b"},
    };

    const result = try runSourceCleanup(allocator, io, source.asMediaSource(), &.{ "a", "b", "c" }, 50);

    try expectIds(&.{}, result.deletedSourceIds);
    try expectIds(&.{ "a", "b", "c" }, result.failedSourceIds);
}

test "a refused batch does not stop the batches after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{
        .allocator = allocator,
        .refusedSourceIds = &.{"a"},
    };

    const result = try runSourceCleanup(allocator, io, source.asMediaSource(), &.{ "a", "b", "c", "d" }, 2);

    try expectRequests(&.{ &.{ "a", "b" }, &.{ "c", "d" } }, source.deleteRequests.items);
    try expectIds(&.{ "b", "c", "d" }, result.deletedSourceIds);
    try expectIds(&.{"a"}, result.failedSourceIds);
}

test "a batch size below one is refused rather than looping forever" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: RecordingMediaSource = .{ .allocator = allocator };

    try std.testing.expectError(error.Thrown, runSourceCleanup(allocator, io, source.asMediaSource(), &.{"a"}, 0));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "batch size") != null);
}

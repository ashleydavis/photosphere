const std = @import("std");
const node_utils = @import("node-utils-zig");
const path = node_utils.path;

//
// Path segments and what Bun's path.posix.join and path.win32.join return for them (see fixtures/generate.ts).
//
const JoinCase = struct {
    // The segments passed to join.
    segments: []const []const u8,

    // What path.posix.join returns.
    posix: []const u8,

    // What path.win32.join returns.
    win32: []const u8,
};

//
// Loads the path.join cases.
//
fn loadJoinCases(allocator: std.mem.Allocator) ![]const JoinCase {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/test/fixtures/path-join.json", allocator, .unlimited);
    return std.json.parseFromSliceLeaky([]const JoinCase, allocator, bytes, .{});
}

test "path.posix.join matches Node for every case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (try loadJoinCases(allocator)) |joinCase| {
        errdefer std.debug.print("segments={f}\n", .{std.json.fmt(joinCase.segments, .{})});
        try std.testing.expectEqualStrings(joinCase.posix, try path.posix.join(allocator, joinCase.segments));
    }
}

test "path.win32.join matches Node for every case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (try loadJoinCases(allocator)) |joinCase| {
        errdefer std.debug.print("segments={f}\n", .{std.json.fmt(joinCase.segments, .{})});
        try std.testing.expectEqualStrings(joinCase.win32, try path.win32.join(allocator, joinCase.segments));
    }
}

test "path.join uses the rules of the platform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expected = if (@import("builtin").os.tag == .windows) "a\\b\\c" else "a/b/c";
    try std.testing.expectEqualStrings(expected, try path.join(allocator, &.{ "a/b", "c" }));
}

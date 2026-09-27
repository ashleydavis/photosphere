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

//
// A path and what Node's path.posix and path.win32 functions return for it (Node's own documentation and
// test/parallel/test-path-dirname.js, test-path-basename.js and test-path-extname.js).
//
const NameCase = struct {
    // The path.
    path: []const u8,

    // What the function returns.
    expected: []const u8,
};

test "path.posix.dirname matches Node" {
    const cases = [_]NameCase{
        .{ .path = "/a/b/", .expected = "/a" },
        .{ .path = "/a/b", .expected = "/a" },
        .{ .path = "/a", .expected = "/" },
        .{ .path = "", .expected = "." },
        .{ .path = "/", .expected = "/" },
        .{ .path = "////", .expected = "/" },
        .{ .path = "//a", .expected = "//" },
        .{ .path = "foo", .expected = "." },
        .{ .path = "/foo/bar/baz/asdf/quux", .expected = "/foo/bar/baz/asdf" },
        .{ .path = "photos/one.jpg", .expected = "photos" },
    };
    for (cases) |nameCase| {
        try std.testing.expectEqualStrings(nameCase.expected, path.posix.dirname(nameCase.path));
    }
}

test "path.win32.dirname matches Node" {
    const cases = [_]NameCase{
        .{ .path = "c:\\", .expected = "c:\\" },
        .{ .path = "c:\\foo", .expected = "c:\\" },
        .{ .path = "c:\\foo\\", .expected = "c:\\" },
        .{ .path = "c:\\foo\\bar", .expected = "c:\\foo" },
        .{ .path = "c:\\foo\\bar\\baz", .expected = "c:\\foo\\bar" },
        .{ .path = "\\", .expected = "\\" },
        .{ .path = "\\foo", .expected = "\\" },
        .{ .path = "c:", .expected = "c:" },
        .{ .path = "c:foo", .expected = "c:" },
        .{ .path = "\\\\unc\\share", .expected = "\\\\unc\\share" },
        .{ .path = "\\\\unc\\share\\foo", .expected = "\\\\unc\\share\\" },
        .{ .path = "/a/b/", .expected = "/a" },
        .{ .path = "", .expected = "." },
        .{ .path = "foo", .expected = "." },
    };
    for (cases) |nameCase| {
        try std.testing.expectEqualStrings(nameCase.expected, path.win32.dirname(nameCase.path));
    }
}

test "path.posix.basename matches Node" {
    const cases = [_]NameCase{
        .{ .path = "/dir/basename.ext", .expected = "basename.ext" },
        .{ .path = "/basename.ext", .expected = "basename.ext" },
        .{ .path = "basename.ext", .expected = "basename.ext" },
        .{ .path = "basename.ext/", .expected = "basename.ext" },
        .{ .path = "basename.ext//", .expected = "basename.ext" },
        .{ .path = "aaa/bbb", .expected = "bbb" },
        .{ .path = "/aaa/b", .expected = "b" },
        .{ .path = "a", .expected = "a" },
        .{ .path = "", .expected = "" },
        .{ .path = "/", .expected = "" },
        .{ .path = "\\dir\\basename.ext", .expected = "\\dir\\basename.ext" },
    };
    for (cases) |nameCase| {
        try std.testing.expectEqualStrings(nameCase.expected, path.posix.basename(nameCase.path));
    }
}

test "path.win32.basename matches Node" {
    const cases = [_]NameCase{
        .{ .path = "\\dir\\basename.ext", .expected = "basename.ext" },
        .{ .path = "\\basename.ext", .expected = "basename.ext" },
        .{ .path = "basename.ext\\", .expected = "basename.ext" },
        .{ .path = "basename.ext\\\\", .expected = "basename.ext" },
        .{ .path = "foo", .expected = "foo" },
        .{ .path = "aaa\\bbb", .expected = "bbb" },
        .{ .path = "C:", .expected = "" },
        .{ .path = "C:.", .expected = "." },
        .{ .path = "C:\\", .expected = "" },
        .{ .path = "C:\\dir\\base.ext", .expected = "base.ext" },
        .{ .path = "C:basename.ext", .expected = "basename.ext" },
        .{ .path = "/dir/basename.ext", .expected = "basename.ext" },
    };
    for (cases) |nameCase| {
        try std.testing.expectEqualStrings(nameCase.expected, path.win32.basename(nameCase.path));
    }
}

test "path.posix.extname matches Node" {
    const cases = [_]NameCase{
        .{ .path = "", .expected = "" },
        .{ .path = "/path/to/file", .expected = "" },
        .{ .path = "/path/to/file.ext", .expected = ".ext" },
        .{ .path = "/path.to/file.ext", .expected = ".ext" },
        .{ .path = "/path.to/file", .expected = "" },
        .{ .path = "/path.to/.file", .expected = "" },
        .{ .path = "/path.to/.file.ext", .expected = ".ext" },
        .{ .path = "/path/to/f.ext", .expected = ".ext" },
        .{ .path = "/path/to/..ext", .expected = ".ext" },
        .{ .path = "/path/to/..", .expected = "" },
        .{ .path = "file", .expected = "" },
        .{ .path = "file.ext", .expected = ".ext" },
        .{ .path = ".file", .expected = "" },
        .{ .path = ".file.ext", .expected = ".ext" },
        .{ .path = "/file", .expected = "" },
        .{ .path = "file.ext.ext", .expected = ".ext" },
        .{ .path = "file.", .expected = "." },
        .{ .path = ".", .expected = "" },
        .{ .path = "..", .expected = "" },
        .{ .path = "...", .expected = "." },
        .{ .path = "file.ext/", .expected = ".ext" },
        .{ .path = "file\\.ext", .expected = ".ext" },
    };
    for (cases) |nameCase| {
        try std.testing.expectEqualStrings(nameCase.expected, path.posix.extname(nameCase.path));
    }
}

test "path.win32.extname matches Node" {
    const cases = [_]NameCase{
        .{ .path = "C:\\path\\to\\file.ext", .expected = ".ext" },
        .{ .path = "file.ext\\", .expected = ".ext" },
        .{ .path = "file\\", .expected = "" },
        .{ .path = "file.\\\\", .expected = "." },
        .{ .path = ".\\", .expected = "" },
        .{ .path = "..\\", .expected = "" },
        .{ .path = "file\\.ext", .expected = "" },
    };
    for (cases) |nameCase| {
        try std.testing.expectEqualStrings(nameCase.expected, path.win32.extname(nameCase.path));
    }
}

test "path.dirname, path.basename and path.extname use the rules of the platform" {
    const isWindows = @import("builtin").os.tag == .windows;
    try std.testing.expectEqualStrings(if (isWindows) "a" else ".", path.dirname("a\\b.jpg"));
    try std.testing.expectEqualStrings(if (isWindows) "b.jpg" else "a\\b.jpg", path.basename("a\\b.jpg"));
    try std.testing.expectEqualStrings(".jpg", path.extname("a/b.jpg"));
}

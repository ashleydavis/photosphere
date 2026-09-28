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

test "path.win32.isAbsolute matches Node" {
    // Node's test/parallel/test-path-isabsolute.js.
    try std.testing.expect(path.win32.isAbsolute("/"));
    try std.testing.expect(path.win32.isAbsolute("//"));
    try std.testing.expect(path.win32.isAbsolute("//server"));
    try std.testing.expect(path.win32.isAbsolute("//server/file"));
    try std.testing.expect(path.win32.isAbsolute("\\\\server\\file"));
    try std.testing.expect(path.win32.isAbsolute("\\\\server"));
    try std.testing.expect(path.win32.isAbsolute("\\\\"));
    try std.testing.expect(!path.win32.isAbsolute("c"));
    try std.testing.expect(!path.win32.isAbsolute("c:"));
    try std.testing.expect(path.win32.isAbsolute("c:\\"));
    try std.testing.expect(path.win32.isAbsolute("c:/"));
    try std.testing.expect(path.win32.isAbsolute("c://"));
    try std.testing.expect(path.win32.isAbsolute("C:/Users/"));
    try std.testing.expect(path.win32.isAbsolute("C:\\Users\\"));
    try std.testing.expect(!path.win32.isAbsolute("C:cwd/another"));
    try std.testing.expect(!path.win32.isAbsolute("C:cwd\\another"));
    try std.testing.expect(!path.win32.isAbsolute("directory/directory"));
    try std.testing.expect(!path.win32.isAbsolute("directory\\directory"));
    try std.testing.expect(!path.win32.isAbsolute(""));
}

test "path.posix.isAbsolute matches Node" {
    // Node's test/parallel/test-path-isabsolute.js.
    try std.testing.expect(path.posix.isAbsolute("/home/foo"));
    try std.testing.expect(path.posix.isAbsolute("/home/foo/.."));
    try std.testing.expect(!path.posix.isAbsolute("bar/"));
    try std.testing.expect(!path.posix.isAbsolute("./baz"));
    try std.testing.expect(!path.posix.isAbsolute(""));
}

test "path.isAbsolute uses the rules of the platform" {
    const isWindows = @import("builtin").os.tag == .windows;
    try std.testing.expect(path.isAbsolute("/a"));
    try std.testing.expectEqual(isWindows, path.isAbsolute("c:\\a"));
}

//
// A path and what Bun's path.posix.normalize and path.win32.normalize return for it.
//
const INormalizeCase = struct {
    // The path.
    path: []const u8,

    // What path.posix.normalize returns.
    posix: []const u8,

    // What path.win32.normalize returns.
    win32: []const u8,
};

test "path.posix.normalize and path.win32.normalize match Node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]INormalizeCase{
        .{ .path = "", .posix = ".", .win32 = "." },
        .{ .path = "abc/..", .posix = ".", .win32 = "." },
        .{ .path = "abc/../..", .posix = "..", .win32 = ".." },
        .{ .path = "../../a", .posix = "../../a", .win32 = "..\\..\\a" },
        .{ .path = "a/../../b", .posix = "../b", .win32 = "..\\b" },
        .{ .path = "../a/..", .posix = "..", .win32 = ".." },
        .{ .path = "/a/../..", .posix = "/", .win32 = "\\" },
        .{ .path = "a/b/../../..", .posix = "..", .win32 = ".." },
        .{ .path = "./", .posix = "./", .win32 = ".\\" },
        .{ .path = "a//b/./c/", .posix = "a/b/c/", .win32 = "a\\b\\c\\" },
        .{ .path = "C:a\\..\\..\\b", .posix = "C:a\\..\\..\\b", .win32 = "C:..\\b" },
        .{ .path = "\\\\server\\share\\..", .posix = "\\\\server\\share\\..", .win32 = "\\\\server\\share\\" },
        .{ .path = "C:\\..\\x", .posix = "C:\\..\\x", .win32 = "C:\\x" },
        .{ .path = "C:", .posix = "C:", .win32 = "C:." },
        .{ .path = "\\", .posix = "\\", .win32 = "\\" },
        .{ .path = "c:/x/../y", .posix = "c:/y", .win32 = "c:\\y" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.path});
        try std.testing.expectEqualStrings(case.posix, try path.posix.normalize(allocator, case.path));
        try std.testing.expectEqualStrings(case.win32, try path.win32.normalize(allocator, case.path));
    }
}

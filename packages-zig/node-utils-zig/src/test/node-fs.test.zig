const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const node_fs = node_utils.node_fs;
const errors = utils.errors;

//
// Creates a unique temp directory under the package's .zig-cache directory.
//
fn makeTempDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const dirPath = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/photosphere-node-fs-test-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
    try std.Io.Dir.cwd().createDirPath(io, dirPath);
    return dirPath;
}

//
// Expects an action to throw the given message (the messages are what Bun's fs throws for the same cases).
//
fn expectThrown(expected: []const u8, result: anytype) !void {
    if (result) |_| {
        return error.TestExpectedError;
    }
    else |err| {
        try std.testing.expectEqual(error.Thrown, err);
        try std.testing.expectEqualStrings(expected, errors.lastErrorMessage());
    }
}

test "readFile reads a file, and throws the messages Node's readFile throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try makeTempDir(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const filePath = try std.fs.path.join(allocator, &.{ root, "file.txt" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filePath, .data = "content" });
    try std.testing.expectEqualStrings("content", try node_fs.readFile(allocator, io, filePath));

    const missing = try std.fs.path.join(allocator, &.{ root, "missing.txt" });
    try expectThrown(try std.fmt.allocPrint(allocator, "ENOENT: no such file or directory, open '{s}'", .{missing}), node_fs.readFile(allocator, io, missing));
    try expectThrown("EISDIR: illegal operation on a directory, read", node_fs.readFile(allocator, io, root));
    const underFile = try std.fs.path.join(allocator, &.{ filePath, "x" });
    try expectThrown(try std.fmt.allocPrint(allocator, "ENOTDIR: not a directory, open '{s}'", .{underFile}), node_fs.readFile(allocator, io, underFile));
}

test "writeFile writes a file, and throws the messages Node's writeFile throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try makeTempDir(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const filePath = try std.fs.path.join(allocator, &.{ root, "file.json" });
    try node_fs.writeFile(io, filePath, "{}");
    try std.testing.expectEqualStrings("{}", try node_fs.readFile(allocator, io, filePath));

    const underMissing = try std.fs.path.join(allocator, &.{ root, "nodir", "x.json" });
    try expectThrown(try std.fmt.allocPrint(allocator, "ENOENT: no such file or directory, open '{s}'", .{underMissing}), node_fs.writeFile(io, underMissing, "a"));
    try expectThrown(try std.fmt.allocPrint(allocator, "EISDIR: illegal operation on a directory, open '{s}'", .{root}), node_fs.writeFile(io, root, "a"));
}

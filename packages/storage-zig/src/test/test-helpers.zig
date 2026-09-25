const std = @import("std");

//
// Helpers shared by the test files (imported by path, so each test binary gets its own copy).
//

//
// Creates an empty, unique temporary directory under the package's .zig-cache and returns its absolute path.
//
pub fn makeTempDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    var randomBytes: [8]u8 = undefined;
    io.random(&randomBytes);
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    const tempDir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp-tests/{s}-{s}", .{ currentPath, name, &std.fmt.bytesToHex(randomBytes, .lower) });
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, tempDir) catch {};
    try cwd.createDirPath(io, tempDir);
    return tempDir;
}

//
// Deletes a temporary directory created by makeTempDir.
//
pub fn removeTempDir(io: std.Io, tempDir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, tempDir) catch {};
}

//
// Writes a file (creating its directory).
//
pub fn writeFile(io: std.Io, filePath: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(filePath)) |dirPath| {
        try cwd.createDirPath(io, dirPath);
    }
    try cwd.writeFile(io, .{ .sub_path = filePath, .data = data });
}

//
// Reads everything from a reader into memory.
//
pub fn readAll(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, .unlimited);
}

//
// Creates deterministic test data: byte i is (i * 31 + 7) mod 256.
//
pub fn makeData(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, size);
    for (buffer, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% 7);
    }
    return buffer;
}

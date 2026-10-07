const std = @import("std");
const fixture_dirs = @import("fixture-dirs.zig");

//
// Temporary directories for the tests: creating, filling and removing them.
//

//
// Creates an empty, unique temporary directory under the package's .zig-cache and returns its absolute path.
//
pub fn makeTempDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    var randomBytes: [8]u8 = undefined;
    io.random(&randomBytes);
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    // Joined with the platform separator, as createTestTempDir's path.join does.
    const tempDir = try std.fs.path.join(allocator, &.{ currentPath, ".zig-cache", "tmp-tests", try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, &std.fmt.bytesToHex(randomBytes, .lower) }) });
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
// Copies a directory tree.
//
pub fn copyDirectory(allocator: std.mem.Allocator, io: std.Io, sourcePath: []const u8, destPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, destPath);
    var sourceDir = try cwd.openDir(io, sourcePath, .{ .iterate = true });
    defer sourceDir.close(io);
    var walker = try sourceDir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const targetPath = try std.fs.path.join(allocator, &.{ destPath, entry.path });
        switch (entry.kind) {
            .directory => try cwd.createDirPath(io, targetPath),
            .file => {
                const sourceFile = try std.fs.path.join(allocator, &.{ sourcePath, entry.path });
                const data = try cwd.readFileAlloc(io, sourceFile, allocator, .unlimited);
                if (std.fs.path.dirname(targetPath)) |parent| {
                    try cwd.createDirPath(io, parent);
                }
                try cwd.writeFile(io, .{ .sub_path = targetPath, .data = data });
            },
            else => {},
        }
    }
}

//
// Copies one of the checked in test databases (test/dbs/<name>) to a new temporary directory.
//
pub fn copyTestDatabase(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const tempDir = try makeTempDir(allocator, io, name);
    const databaseDir = try std.fmt.allocPrint(allocator, "{s}/db", .{tempDir});
    try copyDirectory(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ fixture_dirs.TEST_DBS_DIR, name }), databaseDir);
    return databaseDir;
}

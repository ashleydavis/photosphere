const std = @import("std");
const storage_zig = @import("storage-zig");
const IStorage = storage_zig.storage.IStorage;

//
// Reading, writing and checking files, and opening storage on a directory, for the tests.
//

//
// Creates a FileStorage rooted at a directory (the storage `createStorage(directory)` returns for a local path).
//
pub fn directoryStorage(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !IStorage {
    const created = try storage_zig.storage_factory.createStorage(allocator, io, directory, null, null);
    return created.storage;
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
// Reads a file.
//
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
}

//
// Returns true when a file exists.
//
pub fn fileExists(io: std.Io, filePath: []const u8) bool {
    std.Io.Dir.cwd().access(io, filePath, .{}) catch {
        return false;
    };
    return true;
}

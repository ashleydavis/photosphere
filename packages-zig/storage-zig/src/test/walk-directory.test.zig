const std = @import("std");
const storage_zig = @import("storage-zig");
const helpers = @import("test-helpers.zig");

const FileStorage = storage_zig.file_storage.FileStorage;
const StoragePrefixWrapper = storage_zig.storage_prefix_wrapper.StoragePrefixWrapper;
const walk_directory = storage_zig.walk_directory;

//
// Matches /^\.db(\/|$)/ (the pattern tree.ts passes).
//
fn matchesDbDirectory(fullPath: []const u8) bool {
    return std.mem.eql(u8, fullPath, ".db") or std.mem.startsWith(u8, fullPath, ".db/");
}

//
// Walks a directory and returns the file names in order.
//
fn walkAll(allocator: std.mem.Allocator, storage: storage_zig.storage.IStorage, dirPath: []const u8, ignorePatterns: []const walk_directory.IgnorePattern) ![]const []const u8 {
    var walker = try walk_directory.walkDirectory(allocator, std.testing.io, storage, dirPath, ignorePatterns);
    var fileNames: std.ArrayList([]const u8) = .empty;
    while (try walker.next()) |orderedFile| {
        try fileNames.append(allocator, orderedFile.fileName);
    }
    return fileNames.items;
}

test "walkDirectory yields the files of a directory before the files of its subdirectories, in sorted order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try helpers.makeTempDir(allocator, io, "walk-directory");
    defer helpers.removeTempDir(io, tempDir);
    const files = [_][]const u8{ "b.txt", "a.txt", "asset/10", "asset/2", "asset/deep/x", "display/1", ".db/tree.dat", ".db/bson/db.dat", "node_modules/m", ".git/HEAD", "sub/.DS_Store" };
    for (files) |file| {
        try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tempDir, file }), "x");
    }
    var fileStorage = FileStorage.init("fs:");
    var wrapper = try StoragePrefixWrapper.init(allocator, fileStorage.storage(), tempDir);

    const withDefaults = try walkAll(allocator, wrapper.storage(), "", &walk_directory.default_ignore_patterns);
    const expectedWithDefaults = [_][]const u8{ "a.txt", "b.txt", ".db/tree.dat", ".db/bson/db.dat", "asset/2", "asset/10", "asset/deep/x", "display/1" };
    try std.testing.expectEqual(expectedWithDefaults.len, withDefaults.len);
    for (expectedWithDefaults, withDefaults) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }

    const withoutDb = try walkAll(allocator, wrapper.storage(), "", &.{ matchesDbDirectory, walk_directory.matchesGit, walk_directory.matchesNodeModules });
    const expectedWithoutDb = [_][]const u8{ "a.txt", "b.txt", "asset/2", "asset/10", "asset/deep/x", "display/1", "sub/.DS_Store" };
    try std.testing.expectEqual(expectedWithoutDb.len, withoutDb.len);
    for (expectedWithoutDb, withoutDb) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }

    const bsonOnly = try walkAll(allocator, wrapper.storage(), ".db/bson", &.{});
    try std.testing.expectEqual(@as(usize, 1), bsonOnly.len);
    try std.testing.expectEqualStrings(".db/bson/db.dat", bsonOnly[0]);
}

test "walkDirectory yields nothing for a missing directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fileStorage = FileStorage.init("fs:");
    const fileNames = try walkAll(allocator, fileStorage.storage(), "/definitely/missing/directory", &walk_directory.default_ignore_patterns);
    try std.testing.expectEqual(@as(usize, 0), fileNames.len);
}

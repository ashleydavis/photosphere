const test_files = @import("test-files.zig");
const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");

const FileStorage = storage_zig.file_storage.FileStorage;
const StoragePrefixWrapper = storage_zig.storage_prefix_wrapper.StoragePrefixWrapper;
const walk_directory = storage_zig.walk_directory;
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");

//
// Matches /^\.db(\/|$)/ (the pattern the merkle tree passes).
//
fn matchesDbDirectory(fullPath: []const u8) bool {
    return std.mem.eql(u8, fullPath, ".db") or std.mem.startsWith(u8, fullPath, ".db/");
}

//
// Walks a directory and returns the file names in order.
//
fn walkAll(log: ILog, allocator: std.mem.Allocator, storage: storage_zig.storage.IStorage, dirPath: []const u8, ignorePatterns: []const walk_directory.IgnorePattern) ![]const []const u8 {
    return walkAllOn(allocator, std.testing.io, log, storage, dirPath, ignorePatterns);
}

//
// Walks a directory on the given Io and returns the file names in order.
//
fn walkAllOn(allocator: std.mem.Allocator, io: std.Io, log: ILog, storage: storage_zig.storage.IStorage, dirPath: []const u8, ignorePatterns: []const walk_directory.IgnorePattern) ![]const []const u8 {
    var walker = try walk_directory.walkDirectory(allocator, io, storage, dirPath, ignorePatterns);
    var fileNames: std.ArrayList([]const u8) = .empty;
    while (try walker.next(log)) |orderedFile| {
        try fileNames.append(allocator, orderedFile.fileName);
    }
    return fileNames.items;
}

test "walkDirectory yields the files of a directory before the files of its subdirectories, in sorted order" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "walk-directory");
    defer test_files.removeTempDir(io, tempDir);
    const files = [_][]const u8{ "b.txt", "a.txt", "asset/10", "asset/2", "asset/deep/x", "display/1", ".db/tree.dat", ".db/bson/db.dat", "node_modules/m", ".git/HEAD", "sub/.DS_Store" };
    for (files) |file| {
        try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ tempDir, file }), "x");
    }
    var fileStorage = FileStorage.init("fs:");
    var wrapper = try StoragePrefixWrapper.init(allocator, fileStorage.storage(), tempDir);

    const withDefaults = try walkAll(log, allocator, wrapper.storage(), "", &walk_directory.default_ignore_patterns);
    const expectedWithDefaults = [_][]const u8{ "a.txt", "b.txt", ".db/tree.dat", ".db/bson/db.dat", "asset/2", "asset/10", "asset/deep/x", "display/1" };
    try std.testing.expectEqual(expectedWithDefaults.len, withDefaults.len);
    for (expectedWithDefaults, withDefaults) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }

    const withoutDb = try walkAll(log, allocator, wrapper.storage(), "", &.{ matchesDbDirectory, walk_directory.matchesGit, walk_directory.matchesNodeModules });
    const expectedWithoutDb = [_][]const u8{ "a.txt", "b.txt", "asset/2", "asset/10", "asset/deep/x", "display/1", "sub/.DS_Store" };
    try std.testing.expectEqual(expectedWithoutDb.len, withoutDb.len);
    for (expectedWithoutDb, withoutDb) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }

    const bsonOnly = try walkAll(log, allocator, wrapper.storage(), ".db/bson", &.{});
    try std.testing.expectEqual(@as(usize, 1), bsonOnly.len);
    try std.testing.expectEqualStrings(".db/bson/db.dat", bsonOnly[0]);
}

test "walkDirectory yields nothing for a missing directory" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fileStorage = FileStorage.init("fs:");
    const fileNames = try walkAll(log, allocator, fileStorage.storage(), "/definitely/missing/directory", &walk_directory.default_ignore_patterns);
    try std.testing.expectEqual(@as(usize, 0), fileNames.len);
}

//
// Counts the listings made by the storage below, for the empty continuation token test.
//
var emptyTokenListingCount: usize = 0;

//
// A listFiles that answers one file with an empty continuation token the first time and fails after that.
//
fn listFilesWithEmptyToken(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!storage_zig.storage.IListResult {
    _ = ptr;
    _ = allocator;
    _ = io;
    _ = path;
    _ = max;
    _ = next;
    emptyTokenListingCount += 1;
    if (emptyTokenListingCount > 1) {
        return error.ListedAgainAfterAnEmptyToken;
    }
    return .{
        .names = &.{"only-file"},
        .next = "",
    };
}

//
// A listDirs that answers no directories with an empty continuation token.
//
fn listDirsWithEmptyToken(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!storage_zig.storage.IListResult {
    _ = ptr;
    _ = allocator;
    _ = io;
    _ = path;
    _ = max;
    _ = next;
    return .{
        .names = &.{},
        .next = "",
    };
}

//
// An empty continuation token ends the listing loop, like a missing one.
//
test "walkDirectory stops listing on an empty continuation token" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = @import("recording-storage.zig").RecordingStorage.init(allocator);
    var vtable = storage_zig.storage.implement(@import("recording-storage.zig").RecordingStorage).*;
    vtable.listFiles = listFilesWithEmptyToken;
    vtable.listDirs = listDirsWithEmptyToken;
    const storage: storage_zig.storage.IStorage = .{
        .ptr = &recording,
        .vtable = &vtable,
        .location = "rec:",
    };
    emptyTokenListingCount = 0;
    const fileNames = try walkAll(log, allocator, storage, "dir", &.{});
    try std.testing.expectEqual(@as(usize, 1), fileNames.len);
    try std.testing.expectEqualStrings("dir/only-file", fileNames[0]);
    try std.testing.expectEqual(@as(usize, 1), emptyTokenListingCount);
}

//
// How many listings have been answered, so a second page can be told from the first.
//
var pageListingsAnswered: usize = 0;

//
// A listFiles that answers one file per page, with a continuation token until the last page, and a listDirs that
// answers nothing.
//
fn pagedListFiles(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!storage_zig.storage.IListResult {
    _ = ptr;
    _ = allocator;
    _ = io;
    _ = path;
    _ = max;
    pageListingsAnswered += 1;
    if (next) |token| {
        try std.testing.expectEqualStrings("page-2", token);
        return .{
            .names = &.{"second-page"},
            .next = null,
        };
    }
    return .{
        .names = &.{"first-page"},
        .next = "page-2",
    };
}

//
// A listDirs that answers no directories.
//
fn noDirsListDirs(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!storage_zig.storage.IListResult {
    _ = ptr;
    _ = allocator;
    _ = io;
    _ = path;
    _ = max;
    _ = next;
    return .{
        .names = &.{},
        .next = null,
    };
}

//
// A listing that runs over more than one page is followed to the end: the next batch is asked for until the
// answer has no token.
//
test "walkDirectory follows a listing across pages" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = @import("recording-storage.zig").RecordingStorage.init(allocator);
    var vtable = storage_zig.storage.implement(@import("recording-storage.zig").RecordingStorage).*;
    vtable.listFiles = pagedListFiles;
    vtable.listDirs = noDirsListDirs;
    const storage: storage_zig.storage.IStorage = .{
        .ptr = &recording,
        .vtable = &vtable,
        .location = "rec:",
    };
    pageListingsAnswered = 0;
    const fileNames = try walkAll(log, allocator, storage, "dir", &.{});
    try std.testing.expectEqual(@as(usize, 2), fileNames.len);
    try std.testing.expectEqualStrings("dir/first-page", fileNames[0]);
    try std.testing.expectEqualStrings("dir/second-page", fileNames[1]);
    try std.testing.expectEqual(@as(usize, 2), pageListingsAnswered);
}

//
// A page of names that all match an ignore pattern is skipped without being yielded, and the walk goes on to the
// next page rather than ending.
//
test "walkDirectory skips an ignored name and carries on to the next page" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = @import("recording-storage.zig").RecordingStorage.init(allocator);
    var vtable = storage_zig.storage.implement(@import("recording-storage.zig").RecordingStorage).*;
    vtable.listFiles = struct {
        fn listFiles(ptr: *anyopaque, list_allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!storage_zig.storage.IListResult {
            _ = ptr;
            _ = list_allocator;
            _ = io;
            _ = path;
            _ = max;
            if (next) |token| {
                try std.testing.expectEqualStrings("page-2", token);
                return .{
                    .names = &.{"kept"},
                    .next = null,
                };
            }
            return .{
                .names = &.{"node_modules"},
                .next = "page-2",
            };
        }
    }.listFiles;
    vtable.listDirs = noDirsListDirs;
    const storage: storage_zig.storage.IStorage = .{
        .ptr = &recording,
        .vtable = &vtable,
        .location = "rec:",
    };
    const fileNames = try walkAll(log, allocator, storage, "dir", &walk_directory.default_ignore_patterns);
    try std.testing.expectEqual(@as(usize, 1), fileNames.len);
    try std.testing.expectEqualStrings("dir/kept", fileNames[0]);
}

//
// A listing that keeps failing is retried and then given up on, rather than walking on as if it were empty.
//
test "walkDirectory gives up when the listing keeps failing" {
    const log = utils.mute_log.MuteLog.init();
    var backoff_time: virtual_time_io.VirtualTimeIo = undefined;
    backoff_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.backoff);
    defer backoff_time.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = @import("recording-storage.zig").RecordingStorage.init(allocator);
    var vtable = storage_zig.storage.implement(@import("recording-storage.zig").RecordingStorage).*;
    vtable.listFiles = struct {
        fn listFiles(ptr: *anyopaque, list_allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!storage_zig.storage.IListResult {
            _ = ptr;
            _ = list_allocator;
            _ = io;
            _ = path;
            _ = max;
            _ = next;
            return error.ListingFailed;
        }
    }.listFiles;
    const storage: storage_zig.storage.IStorage = .{
        .ptr = &recording,
        .vtable = &vtable,
        .location = "rec:",
    };

    // Keep retry's final error, which it writes straight to the console, out of the test output.
    var captured: std.Io.Writer.Allocating = .init(allocator);
    utils.console.setCapture(null, &captured.writer);
    defer utils.console.setCapture(null, null);

    // The retry gives up on the third attempt and throws a WrappedError naming what it was listing, as
    // retry's errorContext asks it to.
    try std.testing.expectError(error.Thrown, walkAllOn(allocator, backoff_time.io(), log, storage, "dir", &.{}));
    try std.testing.expectEqualStrings("WrappedError", utils.errors.lastErrorName());
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "Failed to list the files in dir") != null);
}

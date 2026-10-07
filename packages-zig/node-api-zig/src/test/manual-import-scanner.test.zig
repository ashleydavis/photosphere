const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const string_lists = @import("string-lists.zig");
const ManualImportScanner = node_api.manual_import_scanner.ManualImportScanner;
const IScannedImportFile = node_api.import_scanner.IScannedImportFile;
const ScannerState = node_api.file_scanner.ScannerState;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const path = node_utils.path;

//
// Gathers what a scanner pushes (TypeScript: the `async result => { pushed.push(result); }` arrow function).
//
const Pushed = struct {
    // Allocates the copies.
    allocator: std.mem.Allocator,

    // What was pushed.
    files: std.ArrayList(IScannedImportFile) = .empty,

    //
    // Records one file.
    //
    fn visit(context: ?*anyopaque, result: IScannedImportFile) anyerror!void {
        const self: *Pushed = @ptrCast(@alignCast(context.?));
        var copy = result;
        copy.filePath = try self.allocator.dupe(u8, result.filePath);
        copy.logicalPath = try self.allocator.dupe(u8, result.logicalPath);
        try self.files.append(self.allocator, copy);
    }
};

//
// Nothing watching progress here.
//
fn ignoreProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, state: *const ScannerState) void {
    _ = context;
    _ = currentlyScanning;
    _ = state;
}

//
// Runs a scanner over the given paths and returns what it pushed.
//
fn scanFiles(allocator: std.mem.Allocator, paths: []const []const u8, sessionTempDir: []const u8) ![]IScannedImportFile {
    var generator: RandomUuidGenerator = .{};
    var scanner = ManualImportScanner.init(paths, .{
        .ignorePatterns = &.{".db"},
    }, sessionTempDir, generator.uuidGenerator());
    var pushed: Pushed = .{
        .allocator = allocator,
    };
    try scanner.importScanner().scan(allocator, std.testing.io, .{
        .context = &pushed,
        .function = Pushed.visit,
    }, .{
        .context = null,
        .function = ignoreProgress,
    });
    return pushed.files.items;
}

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const ScannerTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The folder of photos.
    photosDir: []const u8,

    //
    // Makes the directories.
    //
    fn init(self: *ScannerTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.tempDir = try temp_dirs.makeTempDir(allocator, std.testing.io, "manual-import-scanner");
        self.photosDir = try path.join(allocator, &.{ self.tempDir, "photos" });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, self.photosDir);
    }

    //
    // Removes the directories.
    //
    fn deinit(self: *ScannerTest) void {
        temp_dirs.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Writes a file the scanner will recognise as media.
    //
    fn writePhoto(self: *ScannerTest, fileName: []const u8, contents: []const u8) ![]const u8 {
        const filePath = try path.join(self.arena.allocator(), &.{ self.photosDir, fileName });
        try test_files.writeFile(std.testing.io, filePath, contents);
        return filePath;
    }
};

test "pushes every file the scan finds and then returns" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "one");
    _ = try context.writePhoto("b.jpg", "two");

    const pushed = try scanFiles(allocator, &.{context.photosDir}, context.tempDir);

    const names = try allocator.alloc([]const u8, pushed.len);
    for (pushed, 0..) |file, index| {
        names[index] = path.basename(file.filePath);
    }
    string_lists.sortStrings(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a.jpg", names[0]);
    try std.testing.expectEqualStrings("b.jpg", names[1]);
}

test "returns without pushing anything when there is nothing to import" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();

    const pushed = try scanFiles(context.arena.allocator(), &.{context.photosDir}, context.tempDir);

    try std.testing.expectEqual(@as(usize, 0), pushed.len);
}

test "returns without pushing anything when given no paths at all" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();

    const pushed = try scanFiles(context.arena.allocator(), &.{}, context.tempDir);

    try std.testing.expectEqual(@as(usize, 0), pushed.len);
}

test "gives every file the size and modified time it actually has" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.writePhoto("a.jpg", "one");
    const fileStat = try std.Io.Dir.cwd().statFile(std.testing.io, filePath, .{});

    const pushed = try scanFiles(context.arena.allocator(), &.{context.photosDir}, context.tempDir);

    try std.testing.expectEqual(fileStat.size, pushed[0].fileStat.length);
    try std.testing.expectEqual(@as(i64, @intCast(@divFloor(fileStat.mtime.nanoseconds, std.time.ns_per_ms))), pushed[0].fileStat.lastModified);
}

test "identifies a file the user picked by nothing but its own path" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // A file the user asked to import is a file: its path is what it is, and there is nothing
    // else to file its hash under. Only a photo library item needs an identity of its own.
    _ = try context.writePhoto("a.jpg", "one");

    const pushed = try scanFiles(context.arena.allocator(), &.{context.photosDir}, context.tempDir);

    try std.testing.expect(pushed[0].cacheIdentity == null);
}

test "has nothing to release, because it materialised nothing" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.writePhoto("a.jpg", "one");
    var generator: RandomUuidGenerator = .{};
    var scanner = ManualImportScanner.init(&.{context.photosDir}, .{
        .ignorePatterns = &.{".db"},
    }, context.tempDir, generator.uuidGenerator());

    try scanner.importScanner().release(context.arena.allocator(), std.testing.io, filePath);

    // The file the user asked to import is still there. Releasing it must never mean deleting it.
    try std.testing.expect(test_files.fileExists(std.testing.io, filePath));
}

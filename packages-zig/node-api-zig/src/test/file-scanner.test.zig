const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const string_lists = @import("string-lists.zig");
const zip_fixture = @import("zip-fixture.zig");
const buildZip = zip_fixture.buildZip;
const file_scanner = node_api.file_scanner;
const scanPath = file_scanner.scanPath;
const scanPaths = file_scanner.scanPaths;
const FileScannedResult = file_scanner.FileScannedResult;
const ScannerOptions = file_scanner.ScannerOptions;
const ScannerState = file_scanner.ScannerState;
const constructLogicalPath = file_scanner.constructLogicalPath;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const path = node_utils.path;

//
// The ignore patterns every test scans with, unless it says otherwise.
// (Zig: a pattern is the text the TypeScript regular expression matches anywhere in a name.)
//
const defaultScannerOptions: ScannerOptions = .{
    .ignorePatterns = &.{ "node_modules", ".git", ".DS_Store", ".db" },
};

// Helper function to create a minimal valid PNG file
// PNG signature + minimal IHDR chunk
const MINIMAL_PNG = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature (8 bytes)
    0x00, 0x00, 0x00, 0x0D, // Length: 13
    0x49, 0x48, 0x44, 0x52, // Type: IHDR
    0x00, 0x00, 0x00, 0x01, // Width: 1
    0x00, 0x00, 0x00, 0x01, // Height: 1
    0x08, 0x02, 0x00, 0x00, 0x00, // Bit depth, color type, compression, filter, interlace
    0x90, 0x77, 0x53, 0xDE, // CRC
    0x00, 0x00, 0x00, 0x00, // Length: 0
    0x49, 0x45, 0x4E, 0x44, // Type: IEND
    0xAE, 0x42, 0x60, 0x82, // CRC
};

// Helper function to create a minimal valid JPEG file
const MINIMAL_JPEG = [_]u8{
    0xFF, 0xD8, // SOI (Start of Image)
    0xFF, 0xE0, // APP0 marker
    0x00, 0x10, // Length
    0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, // JFIF identifier
    0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // Version and units
    0xFF, 0xD9, // EOI (End of Image)
};

// Helper function to create a minimal valid MP4 file
const MINIMAL_MP4 = [_]u8{
    0x00, 0x00, 0x00, 0x20, // Box size
    0x66, 0x74, 0x79, 0x70, // 'ftyp'
    0x69, 0x73, 0x6F, 0x6D, // Major brand: 'isom'
    0x00, 0x00, 0x02, 0x00, // Minor version
    0x69, 0x73, 0x6F, 0x6D, // Compatible brand: 'isom'
    0x69, 0x73, 0x6F, 0x32, // Compatible brand: 'iso2'
    0x61, 0x76, 0x63, 0x31, // Compatible brand: 'avc1'
    0x6D, 0x70, 0x34, 0x31, // Compatible brand: 'mp41'
    0x00, 0x00, 0x00, 0x08, // Box size
    0x6D, 0x64, 0x61, 0x74, // 'mdat'
};

//
// Gathers what a scan finds (TypeScript: the `async (result) => { scannedFiles.push(result); }` arrow function).
//
const Scanned = struct {
    // Allocates the copies.
    allocator: std.mem.Allocator,

    // What was found.
    files: std.ArrayList(FileScannedResult) = .empty,

    //
    // Records one file.
    //
    fn visit(context: ?*anyopaque, result: FileScannedResult) anyerror!void {
        const self: *Scanned = @ptrCast(@alignCast(context.?));
        var copy = result;
        copy.filePath = try self.allocator.dupe(u8, result.filePath);
        copy.logicalPath = try self.allocator.dupe(u8, result.logicalPath);
        copy.contentType = try self.allocator.dupe(u8, result.contentType);
        try self.files.append(self.allocator, copy);
    }

    //
    // The base names of the files found.
    //
    fn baseNames(self: *Scanned) ![][]const u8 {
        const names = try self.allocator.alloc([]const u8, self.files.items.len);
        for (self.files.items, 0..) |file, index| {
            names[index] = path.basename(file.filePath);
        }
        return names;
    }

    //
    // Whether one of the files found has a path or logical path containing the text.
    //
    fn anyContains(self: *Scanned, text: []const u8, logical: bool) bool {
        for (self.files.items) |file| {
            const value = if (logical) file.logicalPath else file.filePath;
            if (std.mem.indexOf(u8, value, text) != null) {
                return true;
            }
        }
        return false;
    }
};

//
// Records the progress callbacks of a scan.
//
const Progress = struct {
    // Allocates the copies.
    allocator: std.mem.Allocator,

    // The non-empty paths reported.
    updates: std.ArrayList([]const u8) = .empty,

    // The last path reported (TypeScript: currentPath).
    currentPath: ?[]const u8 = null,

    // Whether any path was reported, empty or not.
    reported: bool = false,

    // The number of files ignored when last reported.
    numFilesIgnored: u64 = 0,

    // The number of files failed when last reported.
    numFilesFailed: u64 = 0,

    // The currently scanning path of the state when last reported.
    stateCurrentlyScanning: ?[]const u8 = null,

    //
    // Records one report.
    //
    fn record(context: ?*anyopaque, currentlyScanning: ?[]const u8, state: *const ScannerState) void {
        const self: *Progress = @ptrCast(@alignCast(context.?));
        self.reported = true;
        self.currentPath = if (currentlyScanning) |scanning| (self.allocator.dupe(u8, scanning) catch null) else null;
        if (currentlyScanning) |scanning| {
            if (scanning.len > 0) {
                self.updates.append(self.allocator, self.allocator.dupe(u8, scanning) catch "") catch {};
            }
        }
        self.numFilesIgnored = state.numFilesIgnored;
        self.numFilesFailed = state.numFilesFailed;
        self.stateCurrentlyScanning = if (state.currentlyScanning) |scanning| (self.allocator.dupe(u8, scanning) catch null) else null;
    }
};

//
// The state each test starts from (TypeScript: the beforeEach and afterEach of the describe block).
//
const ScannerTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // A directory of this test's own.
    testDir: []const u8,

    // Where a scan extracts zip entries.
    sessionTempDir: []const u8,

    // Names extracted files.
    generator: RandomUuidGenerator,

    //
    // Makes the directories.
    //
    fn init(self: *ScannerTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try test_environment.setupEnvironment(io);
        self.testDir = try temp_dirs.makeTempDir(allocator, io, "file-scanner-test");
        self.sessionTempDir = try temp_dirs.makeTempDir(allocator, io, "file-scanner-session");
        self.generator = .{};
    }

    //
    // Clean up test directory.
    //
    fn deinit(self: *ScannerTest) void {
        temp_dirs.removeTempDir(std.testing.io, self.testDir);
        temp_dirs.removeTempDir(std.testing.io, self.sessionTempDir);
        self.arena.deinit();
    }

    //
    // Writes a file under the test directory and returns its path.
    //
    fn write(self: *ScannerTest, relativePath: []const u8, data: []const u8) ![]const u8 {
        const filePath = try path.join(self.arena.allocator(), &.{ self.testDir, relativePath });
        try test_files.writeFile(std.testing.io, filePath, data);
        return filePath;
    }

    //
    // Makes a directory under the test directory and returns its path.
    //
    fn makeDir(self: *ScannerTest, relativePath: []const u8) ![]const u8 {
        const dirPath = try path.join(self.arena.allocator(), &.{ self.testDir, relativePath });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dirPath);
        return dirPath;
    }

    //
    // Scans one path.
    //
    fn scan(self: *ScannerTest, filePath: []const u8, options: ScannerOptions, recorder: ?*Progress) !Scanned {
        var scanned: Scanned = .{
            .allocator = self.arena.allocator(),
        };
        try scanPath(self.arena.allocator(), std.testing.io, filePath, .{
            .context = &scanned,
            .function = Scanned.visit,
        }, if (recorder) |progressRecorder| .{
            .context = progressRecorder,
            .function = Progress.record,
        } else null, options, self.sessionTempDir, self.generator.uuidGenerator());
        return scanned;
    }

    //
    // Scans several paths.
    //
    fn scanMany(self: *ScannerTest, paths: []const []const u8) !Scanned {
        var scanned: Scanned = .{
            .allocator = self.arena.allocator(),
        };
        try scanPaths(self.arena.allocator(), std.testing.io, paths, .{
            .context = &scanned,
            .function = Scanned.visit,
        }, null, defaultScannerOptions, self.sessionTempDir, self.generator.uuidGenerator());
        return scanned;
    }

    //
    // Makes a Progress recorder.
    //
    fn progress(self: *ScannerTest) Progress {
        return .{
            .allocator = self.arena.allocator(),
        };
    }

    //
    // `path.relative(process.cwd(), absolutePath)` for a path under the working directory.
    //
    fn relativeToCwd(self: *ScannerTest, absolutePath: []const u8) ![]const u8 {
        const currentPath = try std.process.currentPathAlloc(std.testing.io, self.arena.allocator());
        try std.testing.expect(std.mem.startsWith(u8, absolutePath, currentPath));
        return absolutePath[currentPath.len + 1 ..];
    }
};

//
// Checks that a list of strings contains one.
//
fn expectContains(strings: []const []const u8, expected: []const u8) !void {
    for (strings) |string| {
        if (std.mem.eql(u8, string, expected)) {
            return;
        }
    }
    return error.TestExpectedContains;
}

//
// Checks that a list of strings does not contain one.
//
fn expectNotContains(strings: []const []const u8, unexpected: []const u8) !void {
    for (strings) |string| {
        if (std.mem.eql(u8, string, unexpected)) {
            return error.TestUnexpectedContains;
        }
    }
}

test "should scan a single PNG file" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.png", &MINIMAL_PNG);

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings(filePath, scanned.files.items[0].filePath);
    try std.testing.expectEqualStrings("image/png", scanned.files.items[0].contentType);
    try std.testing.expect(scanned.files.items[0].fileStat.length > 0);
    try std.testing.expectEqualStrings(filePath, scanned.files.items[0].logicalPath); // logicalPath equals filePath for non-zip files
}

test "should scan a single JPEG file" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.jpg", &MINIMAL_JPEG);

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings(filePath, scanned.files.items[0].filePath);
    try std.testing.expectEqualStrings("image/jpeg", scanned.files.items[0].contentType);
}

test "should scan a single MP4 file" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.mp4", &MINIMAL_MP4);

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings(filePath, scanned.files.items[0].filePath);
    try std.testing.expectEqualStrings("video/mp4", scanned.files.items[0].contentType);
}

test "should ignore file with unknown content type" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.unknown", "some content");

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should ignore SVG files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.svg", "<svg></svg>");

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should ignore TypeScript files (video/mp2t)" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.ts", "export const test = 1;");

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should handle non-existent file gracefully" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try path.join(context.arena.allocator(), &.{ context.testDir, "nonexistent.png" });

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should include file metadata" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.png", &MINIMAL_PNG);

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(u64, MINIMAL_PNG.len), scanned.files.items[0].fileStat.length);
    try std.testing.expect(scanned.files.items[0].fileStat.lastModified > 0);
    try std.testing.expectEqualStrings("image/png", scanned.files.items[0].fileStat.contentType.?);
}

test "a modified time before 1970 is truncated to whole milliseconds like a JavaScript Date" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const io = std.testing.io;
    const filePath = try context.write("old.png", &MINIMAL_PNG);
    // Half a millisecond past -1001ms. Bun reports mtimeMs -1000.5 and mtime.getTime() -1000.
    const oldTime: std.Io.Timestamp = .{ .nanoseconds = -1000500000 };
    const photoFile = try std.Io.Dir.cwd().openFile(io, filePath, .{ .mode = .write_only });
    defer photoFile.close(io);
    try photoFile.setTimestamps(io, .{
        .access_timestamp = .{ .new = oldTime },
        .modify_timestamp = .{ .new = oldTime },
    });

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(i64, -1000), scanned.files.items[0].fileStat.lastModified);
}

test "should scan directory with multiple image files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("images/image1.png", &MINIMAL_PNG);
    _ = try context.write("images/image2.jpg", &MINIMAL_JPEG);
    _ = try context.write("images/image3.png", &MINIMAL_PNG);

    var scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expect(scanned.files.items.len >= 3);
    const fileNames = try scanned.baseNames();
    try expectContains(fileNames, "image1.png");
    try expectContains(fileNames, "image2.jpg");
    try expectContains(fileNames, "image3.png");
}

test "should scan nested directories" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("level1/level2/nested.png", &MINIMAL_PNG);
    _ = try context.write("root.png", &MINIMAL_PNG);

    var scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expect(scanned.files.items.len >= 2);
    try std.testing.expect(scanned.anyContains("nested.png", false));
    try std.testing.expect(scanned.anyContains("root.png", false));
}

test "should ignore files matching ignore patterns" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("data/image.png", &MINIMAL_PNG);
    _ = try context.write("data/data.db", "database content");

    var scanned = try context.scan(context.testDir, .{
        .ignorePatterns = &.{".db"},
    }, null);

    const fileNames = try scanned.baseNames();
    try expectContains(fileNames, "image.png");
    try expectNotContains(fileNames, "data.db");
}

test "should ignore node_modules by default" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("node_modules/package.png", &MINIMAL_PNG);
    _ = try context.write("root.png", &MINIMAL_PNG);

    var scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expect(scanned.anyContains("root.png", false));
    try std.testing.expect(!scanned.anyContains("node_modules", false));
}

test "should ignore .git directory by default" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write(".git/config.png", &MINIMAL_PNG);
    _ = try context.write("root.png", &MINIMAL_PNG);

    var scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expect(scanned.anyContains("root.png", false));
    try std.testing.expect(!scanned.anyContains(".git", false));
}

test "should yield files in alphanumeric order" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // Create files in non-alphabetical order
    _ = try context.write("ordered/z.png", &MINIMAL_PNG);
    _ = try context.write("ordered/a.png", &MINIMAL_PNG);
    _ = try context.write("ordered/m.png", &MINIMAL_PNG);

    var scanned = try context.scan(try path.join(context.arena.allocator(), &.{ context.testDir, "ordered" }), defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 3), scanned.files.items.len);
    const fileNames = try scanned.baseNames();
    try std.testing.expectEqualStrings("a.png", fileNames[0]);
    try std.testing.expectEqualStrings("m.png", fileNames[1]);
    try std.testing.expectEqualStrings("z.png", fileNames[2]);
}

test "should scan zip file containing images" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const zipPath = try context.write("images.zip", try buildZip(allocator, &.{
        .{
            .name = "image1.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "image2.jpg",
            .data = &MINIMAL_JPEG,
        },
        .{
            .name = "readme.txt",
            .data = "This is a readme",
        },
    }));

    var scanned = try context.scan(zipPath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 2), scanned.files.items.len); // Only images, not readme.txt
    // Files from zips are extracted to temp files, so check logicalPath instead
    try std.testing.expect(scanned.anyContains("image1.png", true));
    try std.testing.expect(scanned.anyContains("image2.jpg", true));
    try std.testing.expect(!scanned.anyContains("readme.txt", true));

    // All files should have logicalPath set
    for (scanned.files.items) |file| {
        try std.testing.expect(std.mem.indexOf(u8, file.logicalPath, zipPath) != null);
    }
}

test "should scan nested zip files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // Create inner zip
    const innerZipBuffer = try buildZip(allocator, &.{.{
        .name = "inner.png",
        .data = &MINIMAL_PNG,
    }});

    // Create outer zip containing inner zip
    const zipPath = try context.write("nested.zip", try buildZip(allocator, &.{
        .{
            .name = "outer.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "nested.zip",
            .data = innerZipBuffer,
        },
    }));

    var scanned = try context.scan(zipPath, defaultScannerOptions, null);

    // The outer.png should always be found
    try std.testing.expect(scanned.files.items.len >= 1);
    // Files from zips are extracted to temp files, so check logicalPath instead
    try std.testing.expect(scanned.anyContains("outer.png", true));

    // If nested zip extraction works, inner.png should also be found
    if (scanned.files.items.len >= 2) {
        try std.testing.expect(scanned.anyContains("inner.png", true));
        for (scanned.files.items) |file| {
            try std.testing.expect(std.mem.indexOf(u8, file.logicalPath, zipPath) != null);
        }
    }
}

test "should handle deeply nested zip files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // Create level 3 zip
    const level3Buffer = try buildZip(allocator, &.{.{
        .name = "level3.png",
        .data = &MINIMAL_PNG,
    }});

    // Create level 2 zip containing level 3
    const level2Buffer = try buildZip(allocator, &.{
        .{
            .name = "level2.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "level3.zip",
            .data = level3Buffer,
        },
    });

    // Create level 1 zip containing level 2
    const zipPath = try context.write("deep.zip", try buildZip(allocator, &.{
        .{
            .name = "level1.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "level2.zip",
            .data = level2Buffer,
        },
    }));

    var scanned = try context.scan(zipPath, defaultScannerOptions, null);

    // At minimum, level1.png should be found
    try std.testing.expect(scanned.files.items.len >= 1);
    try std.testing.expect(scanned.anyContains("level1.png", true));

    // If nested zip extraction works, other levels should also be found
    if (scanned.files.items.len >= 3) {
        try std.testing.expect(scanned.anyContains("level2.png", true));
        try std.testing.expect(scanned.anyContains("level3.png", true));
    }
}

test "should handle invalid zip file gracefully" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // The scan logs the failure; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    // (Zig: TypeScript reads the scanner's state object after the scan, through the reference the progress
    // callback was handed. A Zig scan's state is gone when it returns, so the zip sits in a folder with a photo
    // after it, and the progress reported for the photo carries the count.)
    _ = try context.write("invalid.zip", "This is not a valid zip file");
    _ = try context.write("z.png", &MINIMAL_PNG);
    var progress = context.progress();

    const scanned = try context.scan(context.testDir, defaultScannerOptions, &progress);

    // Nothing came out of the zip; the photo after it is the only file found.
    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings("z.png", std.fs.path.basename(scanned.files.items[0].filePath));
    try std.testing.expectEqual(@as(u64, 1), progress.numFilesFailed);
}

test "should ignore non-media files in zip" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const zipPath = try context.write("mixed.zip", try buildZip(allocator, &.{
        .{
            .name = "image.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "document.pdf",
            .data = "PDF content",
        },
        .{
            .name = "script.js",
            .data = "console.log(\"test\");",
        },
    }));

    const scanned = try context.scan(zipPath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    // Files from zips are extracted to temp files, so check logicalPath instead
    try std.testing.expect(std.mem.indexOf(u8, scanned.files.items[0].logicalPath, "image.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, scanned.files.items[0].logicalPath, zipPath) != null);
}

test "should preserve relative paths within zip" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const zipPath = try context.write("structured.zip", try buildZip(allocator, &.{
        .{
            .name = "folder1/image1.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "folder2/image2.png",
            .data = &MINIMAL_PNG,
        },
        .{
            .name = "root.png",
            .data = &MINIMAL_PNG,
        },
    }));

    var scanned = try context.scan(zipPath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 3), scanned.files.items.len);
    // Files from zips are extracted to temp files, so check logicalPath instead
    try std.testing.expect(scanned.anyContains("folder1/image1.png", true));
    try std.testing.expect(scanned.anyContains("folder2/image2.png", true));
    try std.testing.expect(scanned.anyContains("root.png", true));
}

test "scans a zip whose entries are compressed" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // (Zig: not in the TypeScript tests. The checked in test archive is compressed with DEFLATE, the method the
    // zips a camera or a phone writes use, so the scan inflates each entry.)
    const zipPath = try context.write("test-archive.zip", try test_files.readFile(allocator, std.testing.io, "../test/multiple-files/test-archive.zip"));

    const scanned = try context.scan(zipPath, defaultScannerOptions, null);

    try std.testing.expect(scanned.files.items.len > 0);
    for (scanned.files.items) |file| {
        const extracted = try test_files.readFile(allocator, std.testing.io, file.filePath);
        try std.testing.expectEqual(@as(u64, extracted.len), file.fileStat.length);
        try std.testing.expect(extracted.len > 0);
    }
}

test "should scan multiple file paths" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const file1 = try context.write("file1.png", &MINIMAL_PNG);
    const file2 = try context.write("file2.jpg", &MINIMAL_JPEG);

    var scanned = try context.scanMany(&.{ file1, file2 });

    try std.testing.expectEqual(@as(usize, 2), scanned.files.items.len);
    const fileNames = try scanned.baseNames();
    try expectContains(fileNames, "file1.png");
    try expectContains(fileNames, "file2.jpg");
}

test "should scan multiple directories" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const dir1 = try context.makeDir("dir1");
    const dir2 = try context.makeDir("dir2");
    _ = try context.write("dir1/image1.png", &MINIMAL_PNG);
    _ = try context.write("dir2/image2.png", &MINIMAL_PNG);

    const scanned = try context.scanMany(&.{ dir1, dir2 });

    try std.testing.expectEqual(@as(usize, 2), scanned.files.items.len);
}

test "should scan mix of files and directories" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const file1 = try context.write("file1.png", &MINIMAL_PNG);
    const dir1 = try context.makeDir("dir1");
    _ = try context.write("dir1/image1.png", &MINIMAL_PNG);

    const scanned = try context.scanMany(&.{ file1, dir1 });

    try std.testing.expectEqual(@as(usize, 2), scanned.files.items.len);
}

test "should handle non-existent paths gracefully" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const file1 = try context.write("file1.png", &MINIMAL_PNG);
    const nonexistent = try path.join(context.arena.allocator(), &.{ context.testDir, "nonexistent.png" });

    const scanned = try context.scanMany(&.{ file1, nonexistent });

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings(file1, scanned.files.items[0].filePath);
}

test "scanPath with relative file path yields absolute filePath in callback" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const absoluteFilePath = try context.write("rel-file.png", &MINIMAL_PNG);

    const relativePath = try context.relativeToCwd(absoluteFilePath);
    try std.testing.expect(!std.mem.eql(u8, relativePath, absoluteFilePath));
    try std.testing.expect(!std.fs.path.isAbsolute(relativePath));

    const scanned = try context.scan(relativePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expect(std.fs.path.isAbsolute(scanned.files.items[0].filePath));
    try std.testing.expectEqualStrings(absoluteFilePath, scanned.files.items[0].filePath);
    try std.testing.expectEqualStrings(scanned.files.items[0].filePath, scanned.files.items[0].logicalPath);
}

test "scanPath with relative directory path yields absolute filePaths in callback" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const subDir = try context.makeDir("subdir");
    _ = try context.write("subdir/image.png", &MINIMAL_PNG);

    const relativePath = try context.relativeToCwd(subDir);
    try std.testing.expect(!std.fs.path.isAbsolute(relativePath));

    const scanned = try context.scan(relativePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expect(std.fs.path.isAbsolute(scanned.files.items[0].filePath));
    try std.testing.expectEqualStrings(try path.join(context.arena.allocator(), &.{ subDir, "image.png" }), scanned.files.items[0].filePath);
}

test "scanPaths with relative paths yields absolute filePaths in callbacks" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const file1 = try context.write("r1.png", &MINIMAL_PNG);
    const file2 = try context.write("r2.jpg", &MINIMAL_JPEG);

    const rel1 = try context.relativeToCwd(file1);
    const rel2 = try context.relativeToCwd(file2);
    try std.testing.expect(!std.fs.path.isAbsolute(rel1));
    try std.testing.expect(!std.fs.path.isAbsolute(rel2));

    const scanned = try context.scanMany(&.{ rel1, rel2 });

    try std.testing.expectEqual(@as(usize, 2), scanned.files.items.len);
    const resolved = try context.arena.allocator().alloc([]const u8, 2);
    for (scanned.files.items, 0..) |file, index| {
        try std.testing.expect(std.fs.path.isAbsolute(file.filePath));
        resolved[index] = file.filePath;
    }
    string_lists.sortStrings(resolved);
    try std.testing.expectEqualStrings(file1, resolved[0]);
    try std.testing.expectEqualStrings(file2, resolved[1]);
}

test "should call progress callback when scanning directory" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("subdir/image.png", &MINIMAL_PNG);
    var progress = context.progress();

    _ = try context.scan(context.testDir, defaultScannerOptions, &progress);

    try std.testing.expect(progress.updates.items.len > 0);
}

test "should call progress callback when scanning zip file" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const zipPath = try context.write("test.zip", try buildZip(allocator, &.{.{
        .name = "image.png",
        .data = &MINIMAL_PNG,
    }}));
    var progress = context.progress();

    _ = try context.scan(zipPath, defaultScannerOptions, &progress);

    try std.testing.expect(progress.updates.items.len > 0);
    var found = false;
    for (progress.updates.items) |update| {
        if (std.mem.indexOf(u8, update, "test.zip") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "a zip name cut through a character outside the Basic Multilingual Plane is reported with U+FFFD" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // 49 letters and an emoji, which is two UTF-16 code units, so `substring(0, 50)` keeps only its high
    // surrogate, and JavaScript writes a lone surrogate out as U+FFFD.
    const rootName = "a" ** 49 ++ "\u{1F600}.zip";
    const zipPath = try context.write(rootName, try buildZip(allocator, &.{.{
        .name = "image.png",
        .data = &MINIMAL_PNG,
    }}));
    var progress = context.progress();

    _ = try context.scan(zipPath, defaultScannerOptions, &progress);

    try std.testing.expectEqualStrings("a" ** 49 ++ "\u{FFFD}", progress.updates.items[0]);
}

test "should track ignored files count" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // (Zig: a photo after the ignored file, so a progress report comes after it; see "should handle invalid zip
    // file gracefully".)
    _ = try context.write("file1.png", &MINIMAL_PNG);
    _ = try context.write("file2.unknown", "content");
    _ = try context.write("file3.png", &MINIMAL_PNG);
    var progress = context.progress();

    _ = try context.scan(context.testDir, defaultScannerOptions, &progress);

    try std.testing.expect(progress.numFilesIgnored > 0);
}

test "should track failed files count" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // The scan logs the failure; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    // (Zig: see "should handle invalid zip file gracefully".)
    _ = try context.write("invalid.zip", "not a zip");
    _ = try context.write("z.png", &MINIMAL_PNG);
    var progress = context.progress();

    _ = try context.scan(context.testDir, defaultScannerOptions, &progress);

    try std.testing.expectEqual(@as(u64, 1), progress.numFilesFailed);
}

test "should track currently scanning path through progress callback" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("subdir/image.png", &MINIMAL_PNG);
    var progress = context.progress();

    _ = try context.scan(context.testDir, defaultScannerOptions, &progress);

    // Should have been set during scanning
    try std.testing.expect(progress.currentPath != null);
    try std.testing.expect(progress.reported);
    try std.testing.expect(progress.stateCurrentlyScanning != null);
}

test "should include image files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.png", &MINIMAL_PNG);

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expect(std.mem.startsWith(u8, scanned.files.items[0].contentType, "image/"));
}

test "should include video files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.mp4", &MINIMAL_MP4);

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expect(std.mem.startsWith(u8, scanned.files.items[0].contentType, "video/"));
}

test "should exclude SVG files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.svg", "<svg></svg>");

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should exclude PSD files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("test.psd", "PSD content");

    const scanned = try context.scan(filePath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should handle empty directory" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();

    const scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should handle empty zip file" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const zipPath = try context.write("empty.zip", try buildZip(context.arena.allocator(), &.{}));

    const scanned = try context.scan(zipPath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

test "should handle zip file with only directories" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const zipPath = try context.write("dirs-only.zip", try buildZip(context.arena.allocator(), &.{.{
        .name = "subfolder/",
    }}));

    const scanned = try context.scan(zipPath, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 0), scanned.files.items.len);
}

//
// Replaces the file with a directory of the same name, a moment after the scan has started.
//
fn replaceFileWithDirectory(filePath: []const u8) void {
    const io = std.testing.io;
    utils.sleep.sleep(io, 10) catch {};
    std.Io.Dir.cwd().deleteFile(io, filePath) catch {};
    std.Io.Dir.cwd().createDirPath(io, filePath) catch {};
}

test "should handle file that becomes directory during scan" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // This is a theoretical edge case - in practice, this shouldn't happen
    // But we test that the scanner handles it gracefully
    const filePath = try context.write("test.png", &MINIMAL_PNG);

    // Start scanning, then delete file and create directory with same name
    const changer = try std.Thread.spawn(.{}, replaceFileWithDirectory, .{filePath});
    const scanned = try context.scan(context.testDir, defaultScannerOptions, null);
    changer.join();

    // Should have handled gracefully
    try std.testing.expect(scanned.files.items.len >= 0);
}

test "should handle very long file paths" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var deepPath: []const u8 = "";
    var level: usize = 0;
    while (level < 10) : (level += 1) {
        deepPath = if (deepPath.len == 0) try std.fmt.allocPrint(allocator, "level{d}", .{level}) else try std.fmt.allocPrint(allocator, "{s}/level{d}", .{ deepPath, level });
    }
    const filePath = try context.write(try std.fmt.allocPrint(allocator, "{s}/image.png", .{deepPath}), &MINIMAL_PNG);

    const scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings(filePath, scanned.files.items[0].filePath);
}

test "should handle files with special characters in names" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.write("image with spaces.png", &MINIMAL_PNG);

    const scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqualStrings(filePath, scanned.files.items[0].filePath);
}

test "should respect custom ignore patterns" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("custom/image.png", &MINIMAL_PNG);
    _ = try context.write("custom/temp.tmp", &MINIMAL_PNG);
    _ = try context.write("custom/backup.bak", &MINIMAL_PNG);

    var scanned = try context.scan(context.testDir, .{
        .ignorePatterns = &.{ ".tmp", ".bak" },
    }, null);

    const fileNames = try scanned.baseNames();
    try expectContains(fileNames, "image.png");
    try expectNotContains(fileNames, "temp.tmp");
    try expectNotContains(fileNames, "backup.bak");
}

test "should use default ignore patterns when none provided" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("default/image.png", &MINIMAL_PNG);
    _ = try context.write("node_modules/package.png", &MINIMAL_PNG);

    var scanned = try context.scan(context.testDir, defaultScannerOptions, null);

    try std.testing.expect(scanned.anyContains("image.png", false));
    try std.testing.expect(!scanned.anyContains("node_modules", false));
}

test "should construct path for file directly in root zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try constructLogicalPath(arena.allocator(), &.{"/path/to/root.zip"}, "image.png");
    try std.testing.expectEqualStrings("/path/to/root.zip/image.png", result);
}

test "should construct path for file in nested zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try constructLogicalPath(arena.allocator(), &.{ "/path/to/root.zip", "nested.zip" }, "image.png");
    try std.testing.expectEqualStrings("/path/to/root.zip/nested.zip/image.png", result);
}

test "should construct path for file in deeply nested zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try constructLogicalPath(arena.allocator(), &.{ "/path/to/root.zip", "parent1.zip", "parent2.zip", "parent3.zip" }, "image.png");
    try std.testing.expectEqualStrings("/path/to/root.zip/parent1.zip/parent2.zip/parent3.zip/image.png", result);
}

test "should handle nested zip names with paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try constructLogicalPath(arena.allocator(), &.{ "/path/to/root.zip", "folder/nested.zip", "subfolder/deep.zip" }, "image.png");
    try std.testing.expectEqualStrings("/path/to/root.zip/folder/nested.zip/subfolder/deep.zip/image.png", result);
}

test "should handle file names with paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try constructLogicalPath(arena.allocator(), &.{ "/path/to/root.zip", "nested.zip" }, "folder/subfolder/image.png");
    try std.testing.expectEqualStrings("/path/to/root.zip/nested.zip/folder/subfolder/image.png", result);
}

test "should handle Windows-style paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try constructLogicalPath(arena.allocator(), &.{ "C:\\path\\to\\root.zip", "nested.zip" }, "image.png");
    try std.testing.expectEqualStrings("C:\\path\\to\\root.zip/nested.zip/image.png", result);
}

test "counts empty files and empty nested zips in a zip as failed" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // The scan logs the skipped files; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    const allocator = context.arena.allocator();
    // (A file after the zip, so the progress reported for it includes the zip's counts.)
    _ = try context.write("z.png", &MINIMAL_PNG);
    _ = try context.write("with-empty.zip", try buildZip(allocator, &.{
        .{
            .name = "empty.png",
            .data = "",
        },
        .{
            .name = "inner.zip",
            .data = "",
        },
        .{
            .name = "image.png",
            .data = &MINIMAL_PNG,
        },
    }));
    var progress = context.progress();

    var scanned = try context.scan(context.testDir, defaultScannerOptions, &progress);

    try std.testing.expectEqual(@as(usize, 2), scanned.files.items.len);
    try std.testing.expect(scanned.anyContains("image.png", true));
    try std.testing.expectEqual(@as(u64, 2), progress.numFilesFailed);
}

test "should ignore FastBid sheet files" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    _ = try context.write("sheet.fbs", "not an image");
    _ = try context.write("z.png", &MINIMAL_PNG);
    var progress = context.progress();

    const scanned = try context.scan(context.testDir, defaultScannerOptions, &progress);

    try std.testing.expectEqual(@as(usize, 1), scanned.files.items.len);
    try std.testing.expectEqual(@as(u64, 1), progress.numFilesIgnored);
}

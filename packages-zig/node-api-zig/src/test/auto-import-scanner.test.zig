const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const auto_import_scanner = node_api.auto_import_scanner;
const AutoImportScanner = auto_import_scanner.AutoImportScanner;
const IAutoImportScannerDeps = auto_import_scanner.IAutoImportScannerDeps;
const IAutoImportScannerProgress = auto_import_scanner.IAutoImportScannerProgress;
const AutoImportQueue = api.auto_import_queue.AutoImportQueue;
const IMediaItem = node_api.media_source.IMediaItem;
const IMediaSource = node_api.media_source.IMediaSource;
const IMediaSourceListPage = node_api.media_source.IMediaSourceListPage;
const IScannedImportFile = node_api.import_scanner.IScannedImportFile;
const ScannerState = node_api.file_scanner.ScannerState;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const path = node_utils.path;

//
// These are the old auto-import loop's tests, moved onto the scanner that replaced it. The loop
// decided what to import and handed batches to a separate import task; the scanner decides the same
// things and pushes files at the one import task that now feeds on it.
//

//
// One page of a scripted listing, and the cursor that asks for it.
//
const IScriptedPage = struct {
    // The cursor that asks for the page ("" for the first page).
    cursor: []const u8,

    // The page.
    page: IMediaSourceListPage,
};

//
// A media source that answers from a script, so the scanner can be tested with no photo library.
//
// The files it "exports" are real, because the scanner puts every item through the same file scan a
// manual import uses, and that reads the file.
//
const FakeMediaSource = struct {
    // Allocates the recorded ids.
    allocator: std.mem.Allocator,

    // The item ids that were exported.
    exportedIds: std.ArrayList([]const u8) = .empty,

    // The item ids that were released.
    releasedIds: std.ArrayList([]const u8) = .empty,

    // The pages the source answers with, replaceable so a test can make a photo appear part way
    // through a run.
    pages: []const IScriptedPage,

    // Where the exported copies are written.
    exportDir: []const u8,

    //
    // Gets the IMediaSource interface of this source.
    //
    fn mediaSource(self: *FakeMediaSource) IMediaSource {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IMediaSource functions of this source.
    //
    const vtable: IMediaSource.VTable = .{
        .listPage = listPage,
        .openItem = openItem,
        .closeItem = closeItem,
        .deleteItems = deleteItems,
    };

    //
    // Answers the page scripted for the cursor, or an empty last page.
    //
    fn listPage(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        _ = allocator;
        _ = io;
        _ = pageSize;
        const self: *FakeMediaSource = @ptrCast(@alignCast(ptr));
        for (self.pages) |scripted| {
            if (std.mem.eql(u8, scripted.cursor, cursor orelse "")) {
                return scripted.page;
            }
        }
        return .{
            .items = &.{},
            .nextCursor = null,
        };
    }

    //
    // Writes a copy of the item and returns its path.
    //
    fn openItem(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        const self: *FakeMediaSource = @ptrCast(@alignCast(ptr));
        try self.exportedIds.append(self.allocator, item.sourceId);
        const exportedPath = try path.join(allocator, &.{ self.exportDir, try std.fmt.allocPrint(allocator, "{s}.jpg", .{item.sourceId}) });
        try helpers.writeFile(io, exportedPath, try std.fmt.allocPrint(allocator, "contents of {s}", .{item.sourceId}));
        return exportedPath;
    }

    //
    // Records the release.
    //
    fn closeItem(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        _ = allocator;
        _ = io;
        const self: *FakeMediaSource = @ptrCast(@alignCast(ptr));
        try self.releasedIds.append(self.allocator, item.sourceId);
    }

    //
    // The scanner has nothing to do with deleting.
    //
    fn deleteItems(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = sourceIds;
        return utils.errors.throwError("The scanner has nothing to do with deleting.", .{});
    }
};

//
// One item the source offers.
//
fn makeItem(comptime sourceId: []const u8, createdAtMs: i64) IMediaItem {
    return .{
        .sourceId = sourceId,
        .filePath = "",
        .displayName = sourceId ++ ".jpg",
        .contentType = "image/jpeg",
        .size = 1024,
        .createdAt = createdAtMs,
    };
}

//
// The moment every test's clock starts at.
//
const TEST_START_MS = 1700000000000;

//
// What a test overrides in the deps, and what the hooks recorded (TypeScript: the overrides object and the
// variables its arrow functions close over).
//
const Hooks = struct {
    // Allocates what the hooks record.
    allocator: std.mem.Allocator,

    // Recognise every item as already imported.
    recogniseAll: bool = false,

    // Recognise only this item as already imported.
    recogniseOnly: ?[]const u8 = null,

    // The skippedAsAlreadyImported of every progress report.
    progressReports: std.ArrayList(u64) = .empty,

    // The sets of source ids onLibraryWalked was given.
    walkedLibraries: std.ArrayList([]const []const u8) = .empty,

    // How often the scanner slept.
    ticks: u64 = 0,

    //
    // Never cancelled.
    //
    fn isCancelled(context: ?*anyopaque) bool {
        _ = context;
        return false;
    }

    //
    // Counts the tick instead of waiting.
    //
    fn sleep(context: ?*anyopaque, io: std.Io, milliseconds: u64) anyerror!void {
        _ = io;
        _ = milliseconds;
        const self: *Hooks = @ptrCast(@alignCast(context.?));
        self.ticks += 1;
    }

    //
    // Recognises what the test asked it to.
    //
    fn alreadyImportedContentHash(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!?[]const u8 {
        _ = allocator;
        _ = io;
        const self: *Hooks = @ptrCast(@alignCast(context.?));
        if (self.recogniseAll) {
            return "some-hash";
        }
        if (self.recogniseOnly) |only| {
            if (std.mem.eql(u8, item.sourceId, only)) {
                return "hash-of-already-in";
            }
        }
        return null;
    }

    //
    // Records the library.
    //
    fn onLibraryWalked(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, liveSourceIds: []const []const u8) anyerror!void {
        _ = allocator;
        _ = io;
        const self: *Hooks = @ptrCast(@alignCast(context.?));
        try self.walkedLibraries.append(self.allocator, try self.allocator.dupe([]const u8, liveSourceIds));
    }

    //
    // Records the progress.
    //
    fn onProgress(context: ?*anyopaque, progress: IAutoImportScannerProgress) void {
        const self: *Hooks = @ptrCast(@alignCast(context.?));
        self.progressReports.append(self.allocator, progress.skippedAsAlreadyImported) catch {};
    }

    //
    // Quiet.
    //
    fn logInfo(context: ?*anyopaque, message: []const u8) void {
        _ = context;
        _ = message;
    }
};

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const ScannerTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // Names extracted files.
    generator: RandomUuidGenerator,

    // The hooks of the test.
    hooks: Hooks,

    //
    // Makes the directory.
    //
    fn init(self: *ScannerTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tempDir = try helpers.makeTempDir(self.arena.allocator(), std.testing.io, "auto-import-scanner");
        self.generator = .{};
        self.hooks = .{
            .allocator = self.arena.allocator(),
        };
    }

    //
    // Removes the directory.
    //
    fn deinit(self: *ScannerTest) void {
        helpers.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // A source offering the given pages.
    //
    fn sourceWithPages(self: *ScannerTest, pages: []const IScriptedPage) FakeMediaSource {
        return .{
            .allocator = self.arena.allocator(),
            .pages = pages,
            .exportDir = self.tempDir,
        };
    }

    //
    // The deps a test starts from: a single pass over the given source, recognising nothing as
    // already imported, with each hook overridable through `hooks`.
    //
    fn makeDeps(self: *ScannerTest, source: *FakeMediaSource, queue: *AutoImportQueue) IAutoImportScannerDeps {
        // Nothing here cancels a scan. The scanner ends its own run once it has read the source to
        // the end, and a test that hangs is a test proving it no longer does.
        return .{
            .source = source.mediaSource(),
            .queue = queue,
            .isCancelled = .{
                .context = &self.hooks,
                .function = Hooks.isCancelled,
            },
            .sleep = .{
                .context = &self.hooks,
                .function = Hooks.sleep,
            },
            .sessionTempDir = self.tempDir,
            .uuidGenerator = self.generator.uuidGenerator(),
            .alreadyImportedContentHash = .{
                .context = &self.hooks,
                .function = Hooks.alreadyImportedContentHash,
            },
            .onLibraryWalked = .{
                .context = &self.hooks,
                .function = Hooks.onLibraryWalked,
            },
            .onProgress = .{
                .context = &self.hooks,
                .function = Hooks.onProgress,
            },
            .logInfo = .{
                .context = &self.hooks,
                .function = Hooks.logInfo,
            },
        };
    }

    //
    // Makes a scanner over a source with a fresh queue.
    //
    fn makeScanner(self: *ScannerTest, source: *FakeMediaSource) !AutoImportScanner {
        const allocator = self.arena.allocator();
        const queue = try allocator.create(AutoImportQueue);
        queue.* = AutoImportQueue.init(allocator);
        return AutoImportScanner.init(allocator, self.makeDeps(source, queue));
    }
};

//
// Gathers what a scan pushes.
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
// Runs a scan to completion and returns the files it pushed.
//
fn runScan(allocator: std.mem.Allocator, scanner: *AutoImportScanner) ![]IScannedImportFile {
    var pushed: Pushed = .{
        .allocator = allocator,
    };
    try scanner.scan(allocator, std.testing.io, .{
        .context = &pushed,
        .function = Pushed.visit,
    }, .{
        .context = null,
        .function = ignoreProgress,
    });
    return pushed.files.items;
}

//
// Checks a list of strings.
//
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedString, actualString| {
        try std.testing.expectEqualStrings(expectedString, actualString);
    }
}

test "a single pass pushes the whole library and returns" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{
        .{
            .cursor = "",
            .page = .{
                .items = &.{ makeItem("one", 1), makeItem("two", 2) },
                .nextCursor = "10",
            },
        },
        .{
            .cursor = "10",
            .page = .{
                .items = &.{makeItem("three", 3)},
                .nextCursor = null,
            },
        },
    });

    var scanner = try context.makeScanner(&source);
    const pushed = try runScan(allocator, &scanner);

    try expectStrings(&.{ "one", "two", "three" }, source.exportedIds.items);
    try std.testing.expectEqual(@as(usize, 3), pushed.len);
}

test "tells the import what each pushed file really is" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // The exported copy has a path and a modified time that were both minted by the copy, so the
    // identity is what the import files the hash under.
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{makeItem("one", 1)},
            .nextCursor = null,
        },
    }});

    var scanner = try context.makeScanner(&source);
    const pushed = try runScan(allocator, &scanner);

    const identity = pushed[0].cacheIdentity.?;
    try std.testing.expectEqualStrings("one", identity.key);
    try std.testing.expectEqual(@as(u64, 1024), identity.length);
    try std.testing.expectEqual(@as(i64, 1), identity.lastModified);
}

test "an item already in the database is never opened and never pushed" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // The whole point of asking before opening: on a phone, opening an item copies the entire
    // photo out of the library, and hashing it reads that copy back.
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{ makeItem("already-in", 1), makeItem("new-one", 2) },
            .nextCursor = null,
        },
    }});
    context.hooks.recogniseOnly = "already-in";

    var scanner = try context.makeScanner(&source);
    const pushed = try runScan(allocator, &scanner);

    try expectStrings(&.{"new-one"}, source.exportedIds.items);
    try std.testing.expectEqual(@as(usize, 1), pushed.len);
    try std.testing.expectEqualStrings("new-one.jpg", path.basename(pushed[0].filePath));
}

test "nothing is opened at all when the whole library is already in the database" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{ makeItem("one", 1), makeItem("two", 2) },
            .nextCursor = null,
        },
    }});
    context.hooks.recogniseAll = true;

    var scanner = try context.makeScanner(&source);
    const pushed = try runScan(allocator, &scanner);

    try std.testing.expectEqual(@as(usize, 0), source.exportedIds.items.len);
    try std.testing.expectEqual(@as(usize, 0), pushed.len);
}

test "counts what it recognised as already imported, so the progress can say so" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{ makeItem("one", 1), makeItem("two", 2) },
            .nextCursor = null,
        },
    }});
    context.hooks.recogniseAll = true;

    var scanner = try context.makeScanner(&source);
    _ = try runScan(allocator, &scanner);

    const reports = context.hooks.progressReports.items;
    try std.testing.expectEqual(@as(u64, 2), reports[reports.len - 1]);
}

test "releasing a pushed file releases the copy the source made for it" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{makeItem("one", 1)},
            .nextCursor = null,
        },
    }});
    var scanner = try context.makeScanner(&source);

    const pushed = try runScan(allocator, &scanner);
    try scanner.release(allocator, std.testing.io, pushed[0].filePath);

    try expectStrings(&.{"one"}, source.releasedIds.items);
}

test "releasing the same file twice releases the source item once" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{makeItem("one", 1)},
            .nextCursor = null,
        },
    }});
    var scanner = try context.makeScanner(&source);

    const pushed = try runScan(allocator, &scanner);
    try scanner.release(allocator, std.testing.io, pushed[0].filePath);
    try scanner.release(allocator, std.testing.io, pushed[0].filePath);

    try expectStrings(&.{"one"}, source.releasedIds.items);
}

test "releasing something it never pushed does nothing" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{makeItem("one", 1)},
            .nextCursor = null,
        },
    }});
    var scanner = try context.makeScanner(&source);

    try scanner.release(allocator, std.testing.io, "/somewhere/else.jpg");

    try std.testing.expectEqual(@as(usize, 0), source.releasedIds.items.len);
}

test "reports the whole library once the run has read all of it" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{
        .{
            .cursor = "",
            .page = .{
                .items = &.{ makeItem("one", 1), makeItem("two", 2) },
                .nextCursor = "10",
            },
        },
        .{
            .cursor = "10",
            .page = .{
                .items = &.{makeItem("three", 3)},
                .nextCursor = null,
            },
        },
    });

    var scanner = try context.makeScanner(&source);
    _ = try runScan(allocator, &scanner);

    try std.testing.expectEqual(@as(usize, 1), context.hooks.walkedLibraries.items.len);
    const walked = try allocator.dupe([]const u8, context.hooks.walkedLibraries.items[0]);
    helpers.sortStrings(walked);
    try expectStrings(&.{ "one", "three", "two" }, walked);
}

test "a scan returns once the library has run dry, rather than waiting for more" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{makeItem("one", 1)},
            .nextCursor = null,
        },
    }});

    // Nothing cancels this scan. If it did not end by itself the test would hang here, which is
    // the point: the app is what starts the next run, a short while after this one ends.
    var scanner = try context.makeScanner(&source);
    _ = try runScan(allocator, &scanner);

    try expectStrings(&.{"one"}, source.exportedIds.items);
}

test "a photo that arrives after the run has ended is taken in by the next run" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.sourceWithPages(&.{.{
        .cursor = "",
        .page = .{
            .items = &.{makeItem("existing", 1)},
            .nextCursor = null,
        },
    }});

    var scanner = try context.makeScanner(&source);
    _ = try runScan(allocator, &scanner);
    try expectStrings(&.{"existing"}, source.exportedIds.items);

    // A photo is taken after that run finished. Nothing is watching for it: the next run is what
    // finds it, reading the listing from the beginning again.
    source.pages = &.{.{
        .cursor = "",
        .page = .{
            .items = &.{ makeItem("existing", 1), makeItem("just-taken", TEST_START_MS + 3600000) },
            .nextCursor = null,
        },
    }};

    var nextRun = try context.makeScanner(&source);
    _ = try runScan(allocator, &nextRun);

    var found = false;
    for (source.exportedIds.items) |sourceId| {
        if (std.mem.eql(u8, sourceId, "just-taken")) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

//
// A photo library item is not a file until the scanner copies it out, and that copy is made
// during the import, so nothing the copy carries describes the photo. A photo with no EXIF takes
// its date from its file, so a copy's timestamp here dates every such photo to the import.
//

//
// `Date.parse("2024-06-15T09:30:00.000Z")`.
//
const CAPTURED_AT_MS: i64 = 1718443800000;

//
// Runs a scan over one library item captured at CAPTURED_AT_MS (or at the given time) and returns what it pushed.
//
fn scanOneLibraryItem(context: *ScannerTest, capturedAtMs: i64) ![]IScannedImportFile {
    const allocator = context.arena.allocator();
    const pages = try allocator.alloc(IScriptedPage, 1);
    const items = try allocator.alloc(IMediaItem, 1);
    items[0] = makeItem("one", capturedAtMs);
    pages[0] = .{
        .cursor = "",
        .page = .{
            .items = items,
            .nextCursor = null,
        },
    };
    const source = try allocator.create(FakeMediaSource);
    source.* = context.sourceWithPages(pages);
    var scanner = try context.makeScanner(source);
    return runScan(allocator, &scanner);
}

test "carries the library's date, not the copy's" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();

    const pushed = try scanOneLibraryItem(&context, CAPTURED_AT_MS);

    try std.testing.expectEqual(CAPTURED_AT_MS, pushed[0].fileStat.lastModified);
}

test "is not the moment the copy was made" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // The failure this guards against: every photo without EXIF filed under the day it was
    // imported, because the copy made during the import is what was measured.
    const startedScanningAtMs = std.Io.Clock.real.now(std.testing.io).toMilliseconds();

    const pushed = try scanOneLibraryItem(&context, CAPTURED_AT_MS);

    try std.testing.expect(pushed[0].fileStat.lastModified < startedScanningAtMs);
}

test "carries the library's size, not the copy's" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // The fake writes a short string as the copy, nothing like the 1024 bytes the library
    // reports for the item.
    const pushed = try scanOneLibraryItem(&context, 1);

    try std.testing.expectEqual(@as(u64, 1024), pushed[0].fileStat.length);
}

test "keeps the content type the scan worked out" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // Only the size and the date come from the library. What the file turned out to be is
    // still what reading it said, because that is read from the bytes themselves.
    const pushed = try scanOneLibraryItem(&context, 1);

    try std.testing.expectEqualStrings("image/jpeg", pushed[0].fileStat.contentType.?);
}

test "agrees with the cache identity" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // They describe the same photo from the same two values, so a change to one that is not
    // made to the other is the bug that was here.
    const pushed = try scanOneLibraryItem(&context, CAPTURED_AT_MS);

    try std.testing.expectEqual(pushed[0].cacheIdentity.?.length, pushed[0].fileStat.length);
    try std.testing.expectEqual(pushed[0].cacheIdentity.?.lastModified, pushed[0].fileStat.lastModified);
}

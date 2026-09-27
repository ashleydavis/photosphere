const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const file_scanner = @import("file-scanner.zig");
const import_scanner = @import("import-scanner.zig");
const media_source = @import("media-source.zig");
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const AutoImportQueue = api.auto_import_queue.AutoImportQueue;
const IFileCacheIdentity = api.import_assets_types.IFileCacheIdentity;
const IMediaItem = media_source.IMediaItem;
const IMediaSource = media_source.IMediaSource;
const IMediaSourceListPage = media_source.IMediaSourceListPage;
const ScanProgressCallback = file_scanner.ScanProgressCallback;
const FileScannedResult = file_scanner.FileScannedResult;
const IFileStat = file_scanner.IFileStat;
const scanPath = file_scanner.scanPath;
const IImportScanner = import_scanner.IImportScanner;
const IScannedImportFile = import_scanner.IScannedImportFile;
const VisitImportFile = import_scanner.VisitImportFile;

//
// The scanner for automatic import: it reads somewhere media arrives and pushes what it finds.
//
// This is everything the old `auto-import` task's loop did, moved behind IImportScanner so that one
// long-lived `import-assets` task serves automatic import as well as manual. Before this there were
// two tasks: a loop that decided what to import, and an `import-assets` task started and torn down
// for every handful of photos it decided on. Everything `import-assets` amortises over a run (the
// scan, the write lock, loading and saving the hash cache) was being paid per handful.
//
// What is platform-specific stays behind IMediaSource, so this same scanner runs over a watched
// folder on the desktop and over the device photo library on a phone.
//

//
// How often the scanner wakes up to release whatever the pacing allows. Short enough that a photo
// the user has just taken appears promptly, long enough that an idle scanner costs nothing.
//
pub const AUTO_IMPORT_TICK_MS = 250;

//
// How many items are fetched from the source at a time. Only decides how often the source is asked,
// not how quickly what it returns is imported.
//
pub const SOURCE_PAGE_SIZE = 50;

//
// What the scanner is doing, reported so the user interface can show it.
//
pub const IAutoImportScannerProgress = struct {
    // The item most recently pushed to the import.
    currentItem: ?[]const u8,

    // How many items the scanner recognised as already imported and did not push.
    skippedAsAlreadyImported: u64,

    // Total milliseconds spent copying items out of the source.
    exportMs: i64,

    // True when there is nothing left to push: the whole library has been walked and both lanes are
    // empty. This is when the import writes out what it has learnt, because it is the moment that
    // costs nothing and the moment after which nothing further may happen for hours.
    caughtUp: bool,
};

//
// `() => boolean`: true once the caller wants the scan to stop. (Zig: a closure.)
//
pub const IsCancelledFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque) bool,
};

//
// `(milliseconds: number) => Promise<void>`: waits for the given number of milliseconds. (Zig: a closure.)
//
pub const SleepFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque, io: std.Io, milliseconds: u64) anyerror!void,
};

//
// `(item: IMediaItem) => Promise<string | undefined>`: the content hash of an item already in the database.
// (Zig: a closure; the hash is allocated with the allocator.)
//
pub const AlreadyImportedContentHashFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!?[]const u8,
};

//
// `(liveSourceIds: Set<string>) => Promise<void>`: reports every source id the library holds.
// (Zig: a closure; the set is a slice of the ids in the order they were added.)
//
pub const OnLibraryWalkedFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, liveSourceIds: []const []const u8) anyerror!void,
};

//
// `(progress: IAutoImportScannerProgress) => void`: reports what the scanner is doing. (Zig: a closure.)
//
pub const OnAutoImportProgressFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque, progress: IAutoImportScannerProgress) void,
};

//
// `(message: string) => void`: says something worth reading in the log. (Zig: a closure.)
//
pub const LogInfoFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque, message: []const u8) void,
};

//
// Everything the scanner needs from the platform driving it.
//
// Everything with a side effect is passed in rather than reached for, which is what lets the whole
// scanner be tested without a filesystem, a photo library or a clock, and lets the pacing be walked
// forward without waiting for real time to pass.
//
pub const IAutoImportScannerDeps = struct {
    // Where media arrives, already built for the configured sources.
    source: IMediaSource,

    // The items this run has been offered and not yet handed to the import.
    queue: *AutoImportQueue,

    // True once the caller wants the scan to stop.
    isCancelled: IsCancelledFn,

    // Waits for the given number of milliseconds. Injected so a test does not wait for real time.
    sleep: SleepFn,

    // Where a zip's contents are extracted to, and where the source materialises its copies.
    sessionTempDir: []const u8,

    // Names the temporary files extracted from a zip.
    uuidGenerator: IUuidGenerator,

    // Answers whether an item is already in the database, without opening it: its content hash when
    // it is, undefined when it is not or when nothing is known about it.
    //
    // This is what stops the scanner paying for a photo that has already been imported. Opening an
    // item on a phone copies the whole photo out of the library into the sandbox, and hashing it
    // reads that copy back, so a library that is already imported would otherwise cost a full copy
    // and a full hash per photo on every run.
    alreadyImportedContentHash: AlreadyImportedContentHashFn,

    // Reports every source id the library holds, after a walk that read the whole listing.
    //
    // Called only when the walk reached the end, so what it
    // reports really is the whole library rather than the part of it read so far. The platform uses
    // it to drop what it recorded about photos that have since left the device.
    onLibraryWalked: OnLibraryWalkedFn,

    // Reports what the scanner is doing, so the user interface can show it.
    onProgress: OnAutoImportProgressFn,

    // Says something worth reading in the log.
    logInfo: LogInfoFn,
};

//
// What the callback pushItem passes to scanPath needs (TypeScript: the variables the `async result => { ... }`
// arrow function closes over).
//
const PushedItemScan = struct {
    // The scanner the item belongs to.
    scanner: *AutoImportScanner,

    // The item being pushed.
    item: IMediaItem,

    // Whether this item was already a file before the import looked at it.
    isAlreadyAFile: bool,

    // The import's per-file callback.
    visitFile: VisitImportFile,

    // Set once the scan has pushed a file.
    pushed: bool,

    //
    // The body of the arrow function.
    //
    fn visit(context: ?*anyopaque, result: FileScannedResult) anyerror!void {
        const self: *PushedItemScan = @ptrCast(@alignCast(context.?));
        const item = self.item;
        self.pushed = true;
        const exportedEntry = try self.scanner.itemsByExportedPath.getOrPut(self.scanner.allocator, result.filePath);
        if (!exportedEntry.found_existing) {
            exportedEntry.key_ptr.* = try self.scanner.allocator.dupe(u8, result.filePath);
        }
        exportedEntry.value_ptr.* = item;

        // What this file really is, so the import files its hash under something that
        // outlives the temporary copy. See IFileCacheIdentity.
        //
        // For an item that was already a file, the file's own size and modified time are
        // what to record: they are what every later listing of that folder will report, and
        // the listing this item came from can be a moment out of date. A file still being
        // copied into a watched folder is listed at whatever size it had reached, and an
        // entry recorded against that never matches the finished file again.
        //
        // For a photo library item there is no file until the copy, and the copy's own size
        // and time describe the copy rather than the photo, so the library's values are the
        // only ones that mean anything.
        const cacheIdentity: IFileCacheIdentity = .{
            .key = item.sourceId,
            .length = if (self.isAlreadyAFile) result.fileStat.length else item.size,
            .lastModified = if (self.isAlreadyAFile) result.fileStat.lastModified else item.createdAt,
        };

        // The same correction applied to the stat the rest of the import reads.
        //
        // Everything downstream takes fileStat as describing the photo that was imported,
        // and for a library item it does not: the copy was made moments ago, so its size and
        // date are the copy's. A photo with no date of its own falls back to its file date,
        // and with the copy's stat that made it the date of the import, so every photo
        // without EXIF was recorded as taken on the day it was imported however old it was.
        const fileStat: IFileStat = if (self.isAlreadyAFile)
            result.fileStat
        else
            .{
                .contentType = result.fileStat.contentType,
                .length = item.size,
                .lastModified = item.createdAt,
            };

        var scannedFile = IScannedImportFile.fromScanned(result, cacheIdentity);
        scannedFile.fileStat = fileStat;
        try self.visitFile.call(scannedFile);
    }
};

//
// Pushes photos at the import as they arrive, and as the pacing allows.
//
pub const AutoImportScanner = struct {
    //
    // Allocates what the scanner keeps for the run. (No TypeScript counterpart.)
    //
    allocator: std.mem.Allocator,

    //
    // Everything the scanner needs from the platform driving it.
    //
    deps: IAutoImportScannerDeps,

    //
    // Every source id this run has seen, gathered page by page so the platform can drop what it
    // recorded about photos that have since left the device.
    //
    liveSourceIds: std.StringArrayHashMapUnmanaged(void),

    //
    // The cursor the next page of the source listing starts at, and whether the listing has already
    // ended. The run carries these itself: nothing outside it ever sees them, because every run
    // reads the source from the beginning.
    //
    nextPageCursor: ?[]const u8,

    //
    // True once a page has come back with no page after it.
    //
    listingFinished: bool,

    //
    // Whether the whole library has already been reported to onLibraryWalked in this run.
    //
    hasReportedFullLibrary: bool,

    //
    // The item most recently pushed to the import, for the user interface to name.
    //
    currentItem: ?[]const u8,

    //
    // How many items were recognised as already imported and never opened.
    //
    skippedAsAlreadyImported: u64,

    // Total milliseconds spent copying items out of the source, summed over every item copied.
    exportMs: i64,

    //
    // The source item each pushed file came from, so the copy can be released once the import has
    // finished with it. Keyed by the path the import knows the file by.
    //
    itemsByExportedPath: std.StringHashMapUnmanaged(IMediaItem),

    //
    // Creates the scanner (TypeScript: the constructor).
    //
    pub fn init(allocator: std.mem.Allocator, deps: IAutoImportScannerDeps) AutoImportScanner {
        return .{
            .allocator = allocator,
            .deps = deps,
            .liveSourceIds = .empty,
            .nextPageCursor = null,
            .listingFinished = false,
            .hasReportedFullLibrary = false,
            .currentItem = null,
            .skippedAsAlreadyImported = 0,
            .exportMs = 0,
            .itemsByExportedPath = .empty,
        };
    }

    //
    // Gets the IImportScanner interface for this scanner (the scanner must not move while it is used).
    //
    pub fn importScanner(self: *AutoImportScanner) IImportScanner {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IImportScanner functions of this scanner.
    //
    const vtable: IImportScanner.VTable = .{
        .scan = scanErased,
        .release = releaseErased,
    };

    //
    // IImportScanner.scan for this implementation.
    //
    fn scanErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, visitFile: VisitImportFile, onProgress: ScanProgressCallback) anyerror!void {
        const self: *AutoImportScanner = @ptrCast(@alignCast(ptr));
        return self.scan(allocator, io, visitFile, onProgress);
    }

    //
    // IImportScanner.release for this implementation.
    //
    fn releaseErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        const self: *AutoImportScanner = @ptrCast(@alignCast(ptr));
        return self.release(allocator, io, filePath);
    }

    //
    // `deps.isCancelled()`. (No TypeScript counterpart.)
    //
    fn isCancelled(self: *AutoImportScanner) bool {
        return self.deps.isCancelled.function(self.deps.isCancelled.context);
    }

    //
    // Pushes photos until the source has been read to the end, then returns.
    //
    // One pass and no more. A photo that arrives after this run has read past it is found by the
    // next run, which the app starts a short while after this one ends. Nothing here watches the
    // filesystem or holds a timer: re-reading the source from the start is what finds new photos.
    //
    pub fn scan(self: *AutoImportScanner, allocator: std.mem.Allocator, io: std.Io, visitFile: VisitImportFile, onProgress: ScanProgressCallback) !void {
        const deps = self.deps;

        while (!self.isCancelled() and !self.hasNothingLeftToPush()) {
            if (self.queueNeedsAPage()) {
                try self.fetchAPage(allocator, io);
            }

            const item = deps.queue.nextItem();
            if (item) |nextItem| {
                try self.pushItem(allocator, io, nextItem, visitFile, onProgress);
            }

            // Reported on every tick, not only when something was released. It is what the panel
            // shows, and the import writes out what it has learnt on the back of it.
            deps.onProgress.function(deps.onProgress.context, self.progress());

            if (self.isCancelled()) {
                break;
            }

            if (item == null) {
                // Nothing was released, so wait rather than spinning. A tick after an item was
                // released would only slow the import down, since the next one is ready to go.
                try deps.sleep.function(deps.sleep.context, io, AUTO_IMPORT_TICK_MS);
            }
        }

        // Said once more on the way out, because the loop stops the moment there is nothing left and
        // the import has to hear that it is caught up before the run ends.
        deps.onProgress.function(deps.onProgress.context, self.progress());
    }

    //
    // Releases the temporary copy the source materialised for one file.
    //
    // A photo library item is not a file: it had to be copied into the app's sandbox to be read at
    // all, and this is what deletes that copy. Called by the import once it has finished with the
    // file, whatever it made of it.
    //
    pub fn release(self: *AutoImportScanner, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        const removed = self.itemsByExportedPath.fetchRemove(filePath) orelse {
            // Not one of ours, or already released. Releasing twice would ask the source to delete
            // a copy that is not there, and a scan whose files are all released is the normal end.
            return;
        };

        try self.deps.source.closeItem(allocator, io, removed.value);
    }

    //
    // What the scanner is doing, for the user interface.
    //
    fn progress(self: *AutoImportScanner) IAutoImportScannerProgress {
        return .{
            .currentItem = self.currentItem,
            .skippedAsAlreadyImported = self.skippedAsAlreadyImported,
            .exportMs = self.exportMs,
            .caughtUp = self.hasNothingLeftToPush(),
        };
    }

    //
    // Hands one item to the import: asks whether it is already there, copies it out of the source if
    // it is not, and pushes it through the same file scan a manual import uses.
    //
    fn pushItem(self: *AutoImportScanner, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem, visitFile: VisitImportFile, onProgress: ScanProgressCallback) !void {
        const deps = self.deps;

        self.currentItem = item.displayName;

        // Asked before the item is opened, which is the whole point: opening it on a phone copies
        // the entire photo out of the library, and that copy is what this avoids.
        const importedContentHash = try deps.alreadyImportedContentHash.function(deps.alreadyImportedContentHash.context, allocator, io, item);
        if (importedContentHash != null) {
            self.skippedAsAlreadyImported += 1;
            return;
        }

        // Timed because on a phone this copies the whole photo out of the library into the app's
        // sandbox before anything can read it, and how much of an import that accounts for has never
        // been established.
        const exportStartedAt = std.Io.Clock.real.now(io).toMilliseconds();
        const exportedPath = try deps.source.openItem(allocator, io, item);
        self.exportMs += std.Io.Clock.real.now(io).toMilliseconds() - exportStartedAt;

        // Whether this item was already a file before the import looked at it. A folder source says
        // so by naming the file; a photo library item has no path at all until it is copied out.
        const isAlreadyAFile = item.filePath.len > 0;

        // Put through the same scan a manual import uses rather than described by hand, so the
        // content type check, the stat and the zip handling are the one implementation. A source
        // that exported nothing readable simply produces no file and nothing is pushed.
        var pushedItemScan: PushedItemScan = .{
            .scanner = self,
            .item = item,
            .isAlreadyAFile = isAlreadyAFile,
            .visitFile = visitFile,
            .pushed = false,
        };
        try scanPath(
            allocator,
            io,
            exportedPath,
            .{
                .context = &pushedItemScan,
                .function = PushedItemScan.visit,
            },
            onProgress,
            .{
                .ignorePatterns = &.{".db"},
            },
            deps.sessionTempDir,
            deps.uuidGenerator,
        );

        if (!pushedItemScan.pushed) {
            // The scan ignored it, so nothing will ever call release for it.
            try deps.source.closeItem(allocator, io, item);
        }
    }

    //
    // Reads one page of the source listing.
    //
    fn listSourcePage(self: *AutoImportScanner, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8) !IMediaSourceListPage {
        return self.deps.source.listPage(allocator, io, cursor, SOURCE_PAGE_SIZE);
    }

    //
    // Whether the queue has run dry and there is another page of the library to fetch.
    //
    fn queueNeedsAPage(self: *AutoImportScanner) bool {
        return !self.listingFinished and !self.deps.queue.hasPending();
    }

    //
    // Fetches the next page of the existing library into the queue.
    //
    fn fetchAPage(self: *AutoImportScanner, allocator: std.mem.Allocator, io: std.Io) !void {
        const deps = self.deps;
        const page = try self.listSourcePage(allocator, io, self.nextPageCursor);
        self.nextPageCursor = page.nextCursor;
        self.listingFinished = page.nextCursor == null;
        const accepted = try deps.queue.addItems(page.items);
        deps.logInfo.function(deps.logInfo.context, try std.fmt.allocPrint(allocator, "Automatic import found {d} item(s) in the source, {d} of them new.", .{ page.items.len, accepted }));

        for (page.items) |item| {
            const liveEntry = try self.liveSourceIds.getOrPut(self.allocator, item.sourceId);
            if (!liveEntry.found_existing) {
                liveEntry.key_ptr.* = try self.allocator.dupe(u8, item.sourceId);
            }
        }

        // Every run reads the listing from the beginning, so reaching the end means this run has seen
        // the whole library and can say what is still on the device.
        if (page.nextCursor == null and !self.hasReportedFullLibrary) {
            self.hasReportedFullLibrary = true;
            try deps.onLibraryWalked.function(deps.onLibraryWalked.context, allocator, io, self.liveSourceIds.keys());
        }
    }

    //
    // True when there is nothing left to push: the library has been walked and the queue is empty.
    //
    fn hasNothingLeftToPush(self: *AutoImportScanner) bool {
        return self.listingFinished and !self.deps.queue.hasPending();
    }
};

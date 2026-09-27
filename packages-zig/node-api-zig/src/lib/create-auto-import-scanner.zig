const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const bdb = @import("bdb-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const auto_import_scanner = @import("auto-import-scanner.zig");
const folder_media_source = @import("folder-media-source.zig");
const hash_cache = @import("hash-cache.zig");
const media_source = @import("media-source.zig");
const media_source_registry = @import("media-source-registry.zig");
const errors = utils.errors;
const log = &utils.log.log;
const sleep = utils.sleep.sleep;
const swallowError = utils.swallow_error.swallowError;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const IFolderAutoImportSource = api.auto_import_settings.IFolderAutoImportSource;
const normaliseAutoImportSettings = api.auto_import_settings.normaliseAutoImportSettings;
const AutoImportQueue = api.auto_import_queue.AutoImportQueue;
const IBsonCollection = bdb.collection.IBsonCollection;
const IStorage = storage_zig.storage.IStorage;
const ITaskContext = task_queue_zig.types.ITaskContext;
const AutoImportScanner = auto_import_scanner.AutoImportScanner;
const IAutoImportScannerProgress = auto_import_scanner.IAutoImportScannerProgress;
const OnAutoImportProgressFn = auto_import_scanner.OnAutoImportProgressFn;
const FolderMediaSource = folder_media_source.FolderMediaSource;
const HashCache = hash_cache.HashCache;
const IMediaItem = media_source.IMediaItem;
const IMediaSource = media_source.IMediaSource;
const buildMediaSource = media_source_registry.buildMediaSource;
const registerMediaSourceBuilder = media_source_registry.registerMediaSourceBuilder;
const IMediaSourceBuildOptions = media_source_registry.IMediaSourceBuildOptions;

//
// Builds the scanner that feeds an automatic import, and everything it needs from the database.
//
// This is the part of automatic import that needs storage, a database and a task context. The
// decisions are in AutoImportScanner, kept apart so they can be tested with no filesystem, no photo
// library and no clock.
//
// It used to be a task of its own (`auto-import`), which ran a loop and started a separate
// `import-assets` task for every handful of photos the loop released. One import task fed by a
// scanner replaced both, which is what stopped the scan, the write lock and the hash cache being
// paid for per handful.
//

//
// Builds a FolderMediaSource over the folder sources (TypeScript: the arrow function registered for "folder").
//
pub fn buildFolderMediaSource(allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource {
    const folders = try allocator.alloc(IFolderAutoImportSource, sources.len);
    for (sources, 0..) |source, index| {
        folders[index] = source.folder;
    }
    const folderMediaSource = try allocator.create(FolderMediaSource);
    folderMediaSource.* = FolderMediaSource.init(allocator, folders, options.sessionTempDir, options.uuidGenerator);
    return folderMediaSource.mediaSource();
}

//
// Folders are the source kind node-api can serve, so it registers the builder for them. The mobile
// worker registers its own builder for the device photo library, and the scanner knows about
// neither.
// (Zig: TypeScript does this when the module is loaded; Zig calls this from initTaskHandlers, which is where
// TypeScript loads this module.)
//
pub fn registerFolderMediaSourceBuilder() !void {
    try registerMediaSourceBuilder("folder", buildFolderMediaSource);
}

//
// Everything the factory needs to build a scanner.
// (Zig: IImportOptions is the raw JSON the import was queued with, which is what normaliseAutoImportSettings reads.)
//
pub const ICreateAutoImportScannerOptions = struct {
    // How the import runs (TypeScript: the IImportOptions fields spread into these options).
    importOptions: std.json.Value,

    // The database's storage, for reading the merkle tree and the saved backfill position.
    storage: IStorage,

    // The database's asset records, for the one question the hash cache cannot answer on its own:
    // whether a file that has been hashed before is in this database.
    metadataCollection: *IBsonCollection,

    // The import's hash cache, already loaded. Shared with the import rather than loaded again,
    // because loading it reads and decodes the whole file.
    localHashCache: *HashCache,

    // Where the media source materialises its temporary copies.
    sessionTempDir: []const u8,

    // The task this scanner runs inside, for cancellation and the clock.
    context: ITaskContext,

    // Reports what the scanner is doing, so the user interface can show it.
    onProgress: OnAutoImportProgressFn,
};

//
// The state the scanner's callbacks share (TypeScript: the variables createAutoImportScanner's inner
// functions close over).
//
const AutoImportScannerCallbacks = struct {
    // The options the scanner was built with.
    options: ICreateAutoImportScannerOptions,

    // How many asset ids this run has recorded in the cache, so the cache is saved every so often
    // rather than only at the end: a run that is killed part way still keeps most of what it learnt.
    cacheEntriesRecorded: u64,

    //
    // Answers whether an item is already in this database, without opening it.
    //
    // Three states, in the order they are cheapest to answer:
    //
    //  - An asset id recorded against the item means it is in the database. Nothing is read at all.
    //    A hard delete of that asset would make this wrong until the cache is cleared, which is a
    //    cost the user can undo with `psi hash-cache clear` and which no import path can produce:
    //    deleting an asset in Photosphere is a flag on the record, and the record and its hash stay.
    //  - A hash but no asset id means the item was hashed by an earlier run that did not get as far
    //    as recording where it landed. The database is asked for that hash, exactly as the import
    //    does, and the answer is recorded so it is not asked twice.
    //  - Nothing at all, or an entry whose size or created time no longer matches, means the item
    //    has to be opened, copied and hashed the long way. A photo library may reuse the id of a
    //    deleted item, so all three parts have to agree before an entry is believed.
    //
    fn alreadyImportedContentHash(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!?[]const u8 {
        const self: *AutoImportScannerCallbacks = @ptrCast(@alignCast(context.?));
        const options = self.options;
        const cacheEntry = try options.localHashCache.getHash(allocator, item.sourceId) orelse {
            return null;
        };

        if (cacheEntry.length != item.size or cacheEntry.lastModified != item.createdAt) {
            return null;
        }

        if (cacheEntry.assetId != null) {
            return try std.fmt.allocPrint(allocator, "{x}", .{cacheEntry.hash});
        }

        const contentHash = try std.fmt.allocPrint(allocator, "{x}", .{cacheEntry.hash});
        const hashIndex = try options.metadataCollection.sortIndex("hash", .asc);
        const existingRecords = try hashIndex.findByValue(io, .{ .string = contentHash }, null);
        if (existingRecords.len == 0) {
            return null;
        }

        const existingId = existingRecords[0].get("_id") orelse {
            return errors.throwError("Sort index record has no _id", .{});
        };
        _ = try options.localHashCache.setAssetId(item.sourceId, existingId.string);
        self.cacheEntriesRecorded += 1;
        if (self.cacheEntriesRecorded % 100 == 0) {
            var saveOperation: SaveHashCacheOperation = .{
                .cache = options.localHashCache,
            };
            _ = swallowError(io, &saveOperation);
        }

        return contentHash;
    }

    //
    // Drops what the cache knows about photos that are no longer on the device.
    //
    // Only entries filed under a source id are considered, and only those the walk did not see. A
    // file path that is not in the photo library is not a dead entry, it is a manual import, and
    // sweeping those would throw away the desktop's whole cache the first time automatic import
    // walked a folder.
    //
    fn onLibraryWalked(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, liveSourceIds: []const []const u8) anyerror!void {
        const self: *AutoImportScannerCallbacks = @ptrCast(@alignCast(context.?));
        const removed = try self.options.localHashCache.removeSourceEntriesNotIn(liveSourceIds);
        if (removed > 0) {
            log.info(try std.fmt.allocPrint(allocator, "Automatic import dropped {d} hash cache entry/entries for items no longer in the source.", .{removed}));
            var saveOperation: SaveHashCacheOperation = .{
                .cache = self.options.localHashCache,
            };
            _ = swallowError(io, &saveOperation);
        }
    }

    //
    // `() => options.context.isCancelled()`.
    //
    fn isCancelled(context: ?*anyopaque) bool {
        const self: *AutoImportScannerCallbacks = @ptrCast(@alignCast(context.?));
        return self.options.context.isCancelled();
    }

    //
    // `milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))`.
    //
    fn sleepFor(context: ?*anyopaque, io: std.Io, milliseconds: u64) anyerror!void {
        _ = context;
        try sleep(io, milliseconds);
    }

    //
    // `message => log.info(message)`.
    //
    fn logInfo(context: ?*anyopaque, message: []const u8) void {
        _ = context;
        log.info(message);
    }
};

//
// `() => options.localHashCache.save()`. (No TypeScript counterpart: the arrow function passed to swallowError.)
//
pub const SaveHashCacheOperation = struct {
    // The cache to save.
    cache: *HashCache,

    //
    // Saves the cache.
    //
    pub fn run(self: *SaveHashCacheOperation, io: std.Io) !void {
        try self.cache.save(io);
    }
};

//
// Builds the scanner for one automatic import.
// (Zig: the scanner and its state are allocated with the allocator.)
//
pub fn createAutoImportScanner(allocator: std.mem.Allocator, options: ICreateAutoImportScannerOptions) !*AutoImportScanner {
    const settings = try normaliseAutoImportSettings(allocator, options.importOptions);
    if (settings.sources.len == 0) {
        return errors.throwError("Automatic import was started with no sources configured. Nothing would be imported.", .{});
    }

    // Every run reads the source from the beginning. Nothing is carried over from the last one, so
    // a photo that arrived since is found, and one already imported costs a hash cache lookup.
    const queue = try allocator.create(AutoImportQueue);
    queue.* = AutoImportQueue.init(allocator);

    const source = try buildMediaSource(allocator, settings.sources, .{
        .sessionTempDir = options.sessionTempDir,
        .uuidGenerator = options.context.uuidGenerator,
    });

    const callbacks = try allocator.create(AutoImportScannerCallbacks);
    callbacks.* = .{
        .options = options,
        .cacheEntriesRecorded = 0,
    };

    const scanner = try allocator.create(AutoImportScanner);
    scanner.* = AutoImportScanner.init(allocator, .{
        .source = source,
        .queue = queue,
        .isCancelled = .{
            .context = callbacks,
            .function = AutoImportScannerCallbacks.isCancelled,
        },
        .sleep = .{
            .context = callbacks,
            .function = AutoImportScannerCallbacks.sleepFor,
        },
        .sessionTempDir = options.sessionTempDir,
        .uuidGenerator = options.context.uuidGenerator,
        .alreadyImportedContentHash = .{
            .context = callbacks,
            .function = AutoImportScannerCallbacks.alreadyImportedContentHash,
        },
        .onLibraryWalked = .{
            .context = callbacks,
            .function = AutoImportScannerCallbacks.onLibraryWalked,
        },
        .onProgress = options.onProgress,
        .logInfo = .{
            .context = callbacks,
            .function = AutoImportScannerCallbacks.logInfo,
        },
    });
    return scanner;
}

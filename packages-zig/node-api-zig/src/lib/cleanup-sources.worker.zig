const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const task_queue_zig = @import("task-queue-zig");
const resolve_storage_credentials = @import("resolve-storage-credentials.zig");
const hash_cache = @import("hash-cache.zig");
const media_source = @import("media-source.zig");
const media_source_registry = @import("media-source-registry.zig");
const create_auto_import_scanner = @import("create-auto-import-scanner.zig");
const errors = utils.errors;
const log = &utils.log.log;
const swallowError = utils.swallow_error.swallowError;
const path = node_utils.path;
const ensureDir = node_utils.fs.ensureDir;
const remove = node_utils.fs.remove;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const normaliseAutoImportSettings = api.auto_import_settings.normaliseAutoImportSettings;
const runSourceCleanup = api.source_cleanup.runSourceCleanup;
const createStorage = storage_zig.storage_factory.createStorage;
const loadEncryptionKeysFromPem = @import("encryption-zig").key_utils.loadEncryptionKeysFromPem;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const ITaskContext = task_queue_zig.types.ITaskContext;
const resolveStorageCredentials = resolve_storage_credentials.resolveStorageCredentials;
const getHashCacheDir = hash_cache.getHashCacheDir;
const HashCache = hash_cache.HashCache;
const IMediaItem = media_source.IMediaItem;
const buildMediaSource = media_source_registry.buildMediaSource;

//
// Deleting the photos a device still holds that the database already has.
//
// This used to happen inside automatic import, on whatever one batch had just confirmed. That tied
// the number of deletions per request to the size of an import batch, and on a phone every request
// raises a system confirmation dialog, so the user was asked once per handful of photos. It is now
// its own operation, run when the user asks for it: one walk, one set of dialogs, at a moment they
// chose.
//
// It answers its own question rather than being told what to delete. For each item the device still
// holds it asks the hash cache what that photo hashes to, and the database whether it holds that
// hash. Nothing is deleted on the strength of an import having reported success: the database
// saying it holds the content is the only thing that counts.
//
// What it cannot see: a photo imported on another device and synced into this database. This device
// never hashed it, so the cache has no entry for it, and finding out would mean copying and hashing
// every photo in the library, which is the cost automatic import exists to avoid. Such a photo is
// left on the device.
//

//
// How many source files are deleted per request.
//
// Batched because Android and iOS both put a system confirmation in front of deleting media the app
// does not own, and one dialog per photo would be unusable. Whether one request can carry every
// pending item, and what the real ceiling is on each platform, has not been established: this is
// the number that was already here.
//
pub const SOURCE_CLEANUP_BATCH_SIZE = 50;

//
// How many items are read from the source per page while looking for what to delete.
//
pub const CLEANUP_PAGE_SIZE = 50;

//
// Folders are the source kind node-api can serve. Registered here as well as by the import scanner
// because this task can run on its own, before an import has been started in this process.
// (Zig: TypeScript does this when the module is loaded; Zig calls this from initTaskHandlers, which is where
// TypeScript loads this module.)
//
pub fn registerFolderMediaSourceBuilder() !void {
    try media_source_registry.registerMediaSourceBuilder("folder", create_auto_import_scanner.buildFolderMediaSource);
}

//
// Payload for the cleanup-sources task.
// (The settings are kept as the raw JSON they were queued as, because the sources in them are told apart by their
// "type" field, which std.json cannot parse into a tagged union; normaliseAutoImportSettings reads them.)
//
pub const ICleanupSourcesData = struct {
    // Identifies the database to check against, and its optional encryption key.
    storageDescriptor: IDatabaseDescriptor,

    // Where to look for photos to delete: the same sources automatic import watches.
    settings: std.json.Value,

    // When true, nothing is deleted and the result says what would have been. This is what the
    // button uses to show a count before the user commits to anything.
    dryRun: bool,
};

//
// What a cleanup run did.
//
pub const ICleanupSourcesResult = struct {
    // How many items the source was asked about.
    considered: u64,

    // The source ids that are in the database and can go.
    deletableSourceIds: []const []const u8,

    // The source ids that were actually deleted. Empty for a dry run.
    deletedSourceIds: []const []const u8,

    // The source ids the device refused or failed to delete.
    failedSourceIds: []const []const u8,
};

//
// `() => remove(sessionTempDir)` passed to swallowError. (No TypeScript counterpart: the arrow function.)
//
const RemoveSessionTempDirOperation = struct {
    // The directory to remove.
    dirPath: []const u8,

    //
    // Removes the directory.
    //
    pub fn run(self: *RemoveSessionTempDirOperation, io: std.Io) !void {
        try remove(io, self.dirPath);
    }
};

//
// Whether the database holds the photo this item is, going by what this device recorded when it
// hashed it. All three parts of the entry have to agree, because a photo library may reuse the
// id of an item that has been deleted, and deleting the wrong photo is not recoverable.
// (TypeScript: the inner isInTheDatabase function.)
//
fn isInTheDatabase(allocator: std.mem.Allocator, io: std.Io, localHashCache: *HashCache, metadataCollection: *IBsonCollection, item: IMediaItem) !bool {
    const cacheEntry = try localHashCache.getHash(allocator, item.sourceId) orelse {
        return false;
    };

    if (cacheEntry.length != item.size or cacheEntry.lastModified != item.createdAt) {
        return false;
    }

    // Asked of the database itself even when an asset id is recorded, because this deletes the
    // user's only copy of a photo. An id in the cache is good enough to skip an import; it is
    // not good enough to delete anything.
    const hashIndex = try metadataCollection.sortIndex("hash", .asc);
    const existingRecords = try hashIndex.findByValue(io, .{ .string = try std.fmt.allocPrint(allocator, "{x}", .{cacheEntry.hash}) }, null);
    return existingRecords.len > 0;
}

//
// Deletes the photos the device still holds that the database already has.
// (Zig: the task data and output are JSON values holding ICleanupSourcesData and ICleanupSourcesResult.)
//
pub fn cleanupSourcesHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(ICleanupSourcesData, allocator, taskData, .{ .ignore_unknown_fields = true });
    const settings = try normaliseAutoImportSettings(allocator, data.settings);
    if (settings.sources.len == 0) {
        return errors.throwError("Cleanup was asked to run with no sources configured. There is nowhere to look.", .{});
    }

    const sessionTempDir = try path.join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere", try context.uuidGenerator.generate(allocator, io) });
    try ensureDir(io, sessionTempDir);

    const credentials = try resolveStorageCredentials(allocator, io, data.storageDescriptor.databasePath, data.storageDescriptor.encryptionKey, null);
    const loadedKeys = try loadEncryptionKeysFromPem(allocator, credentials.encryptionKeyPems);
    const created = try createStorage(allocator, io, data.storageDescriptor.databasePath, credentials.s3Config, loadedKeys.options);
    const bsonDatabase = try BsonDatabase.init(allocator, created.storage, ".db/bson", context.uuidGenerator, context.timestampProvider);
    const metadataCollection = try bsonDatabase.collection("metadata");

    var localHashCache = try HashCache.init(try getHashCacheDir(allocator, data.storageDescriptor.databasePath), true);
    defer localHashCache.deinit();
    _ = try localHashCache.load(io);

    const source = try buildMediaSource(allocator, settings.sources, .{
        .sessionTempDir = sessionTempDir,
        .uuidGenerator = context.uuidGenerator,
    });

    defer {
        var removeOperation: RemoveSessionTempDirOperation = .{
            .dirPath = sessionTempDir,
        };
        _ = swallowError(io, &removeOperation);
    }

    var deletableSourceIds: std.ArrayList([]const u8) = .empty;
    var considered: u64 = 0;
    var cursor: ?[]const u8 = null;

    while (true) {
        const page = try source.listPage(allocator, io, cursor, CLEANUP_PAGE_SIZE);
        for (page.items) |item| {
            considered += 1;
            if (try isInTheDatabase(allocator, io, &localHashCache, metadataCollection, item)) {
                try deletableSourceIds.append(allocator, item.sourceId);
            }
        }
        cursor = page.nextCursor;
        if (cursor == null or context.isCancelled()) {
            break;
        }
    }

    if (data.dryRun or deletableSourceIds.items.len == 0) {
        return resultToJson(allocator, .{
            .considered = considered,
            .deletableSourceIds = deletableSourceIds.items,
            .deletedSourceIds = &.{},
            .failedSourceIds = &.{},
        });
    }

    const cleanupResult = try runSourceCleanup(allocator, io, source, deletableSourceIds.items, SOURCE_CLEANUP_BATCH_SIZE);
    if (cleanupResult.failedSourceIds.len > 0) {
        // Not retried: a source that refused once will refuse again, and looping would ask the
        // user the same question forever. Said out loud so the files are known to still be there.
        log.@"error"(try std.fmt.allocPrint(allocator, "Cleanup could not delete {d} source file(s): {s}", .{ cleanupResult.failedSourceIds.len, try std.mem.join(allocator, ", ", cleanupResult.failedSourceIds) }));
    }

    return resultToJson(allocator, .{
        .considered = considered,
        .deletableSourceIds = deletableSourceIds.items,
        .deletedSourceIds = cleanupResult.deletedSourceIds,
        .failedSourceIds = cleanupResult.failedSourceIds,
    });
}

//
// Converts the result to the JSON value returned as the task output. (No TypeScript counterpart: TypeScript
// returns the object itself.)
//
fn resultToJson(allocator: std.mem.Allocator, result: ICleanupSourcesResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

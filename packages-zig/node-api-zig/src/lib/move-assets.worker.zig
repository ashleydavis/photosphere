const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const Timers = @import("ziggy").timers.Timers;
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("ziggy").task_queue;
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const open_storage = @import("open-storage.zig");
const media_file_database = @import("media-file-database.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const retry = utils.retry.retry;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IBsonCollection = bdb.collection.IBsonCollection;
const BsonDocument = serialization_zig.bson.BsonDocument;
const openStorage = open_storage.openStorage;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const loadSortIndexes = media_file_database.loadSortIndexes;
const streamAsset = media_file_database.streamAsset;
const writeAssetStreamVerified = media_file_database.writeAssetStreamVerified;
const removeAsset = media_file_database.removeAsset;

//
// Input data for the move-assets background task.
//
pub const IMoveAssetsData = struct {
    //
    // Filesystem path (or S3 path) to the source database.
    //
    sourceDatabasePath: []const u8,

    //
    // Filesystem path (or S3 path) to the destination database.
    //
    destDatabasePath: []const u8,

    //
    // IDs of the assets to move from source to destination.
    //
    assetIds: []const []const u8,
};

//
// Result returned by the move-assets task.
//
pub const IMoveAssetsResult = struct {
    //
    // Number of assets successfully moved.
    //
    movedCount: u64,
};

//
// `() => sourceDb.metadataCollection.getOne(assetId)`.
//
const GetMetadataOperation = struct {
    // The text that stands for this operation in the timeout message of retryOnce.
    pub const source = "() => sourceDb.metadataCollection.getOne(assetId)";

    // The metadata collection of the source database.
    metadataCollection: *IBsonCollection,

    // The id of the record to get.
    assetId: []const u8,

    //
    // Gets the record.
    //
    pub fn run(self: *GetMetadataOperation, io: std.Io, log: ILog) !?BsonDocument {
        return self.metadataCollection.getOne(io, log, self.assetId);
    }
};

//
// `() => destDb.metadataCollection.updateOne(newAssetId, { ...metadata, _id: newAssetId }, { upsert: true })`.
//
const UpsertMetadataOperation = struct {
    // The text that stands for this operation in the timeout message of retryOnce.
    pub const source = "() => destDb.metadataCollection.updateOne(newAssetId, { ...metadata, _id: newAssetId }, { upsert: true })";

    // The metadata collection of the destination database.
    metadataCollection: *IBsonCollection,

    // The id of the new record.
    newAssetId: []const u8,

    // The record to write: the metadata of the original with its _id replaced by newAssetId.
    updates: BsonDocument,

    //
    // Writes the record, creating it when it does not exist.
    //
    pub fn run(self: *UpsertMetadataOperation, io: std.Io, log: ILog) !bool {
        return self.metadataCollection.updateOne(io, log, self.newAssetId, self.updates, .{
            .upsert = true,
        });
    }
};

//
// Background task handler that moves assets from one database to another.
// Opens both databases directly via storage, copies binary files and metadata,
// then hard-deletes the originals from the source database.
// (Zig: the task data and output are JSON values holding IMoveAssetsData and IMoveAssetsResult. Reading the task data into
// the typed struct fails when a key is missing or is not of the type the interface names; the failure is reported as a
// sentence, not a bare parser error name.)
//
pub fn moveAssetsHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    log: utils.log.ILog,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = std.json.parseFromValueLeaky(IMoveAssetsData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The move-assets task data is not valid: sourceDatabasePath and destDatabasePath must be strings, and assetIds must be a list of strings", .{});
    };
    const sourceDatabasePath = data.sourceDatabasePath;
    const destDatabasePath = data.destDatabasePath;
    const assetIds = data.assetIds;
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const source = try openStorage(allocator, io, log, sourceDatabasePath, null, null, context.nativeCaller);
    const sourceStorage = source.storage;
    const sourceRawStorage = source.rawStorage;
    const sourceDb = try createMediaFileDatabase(allocator, sourceStorage, uuidGenerator, timestampProvider);
    try loadSortIndexes(allocator, log, sourceStorage, sourceDb.metadataCollection);

    const dest = try openStorage(allocator, io, log, destDatabasePath, null, null, context.nativeCaller);
    const destStorage = dest.storage;
    const destRawStorage = dest.rawStorage;
    const destDb = try createMediaFileDatabase(allocator, destStorage, uuidGenerator, timestampProvider);
    try loadSortIndexes(allocator, log, destStorage, destDb.metadataCollection);

    for (assetIds) |assetId| {
        var getMetadataOperation: GetMetadataOperation = .{
            .metadataCollection = sourceDb.metadataCollection,
            .assetId = assetId,
        };
        const metadata = try retry(io, log, &getMetadataOperation, 3, 1_000, 2, 30_000, null) orelse {
            return errors.throwError("Asset \"{s}\" not found in source database \"{s}\".", .{ assetId, sourceDatabasePath });
        };

        const newAssetId = try uuidGenerator.generate(allocator, io);

        for ([_][]const u8{ "thumb", "display", "asset" }) |assetType| {
            const assetPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetType, assetId });
            const exists = try sourceStorage.fileExists(allocator, io, assetPath);
            if (exists) {
                var infoOperation: retry_operations.InfoOperation("() => sourceStorage.info(assetPath)") = .{
                    .allocator = allocator,
                    .storage = sourceStorage,
                    .fileName = assetPath,
                };
                const info = try retry(io, log, &infoOperation, 3, 1_000, 2, 30_000, null);
                const stream = try streamAsset(allocator, io, log, sourceStorage, assetId, assetType);
                defer stream.destroy(io);
                try writeAssetStreamVerified(
                    allocator,
                    io,
                    log,
                    sourceStorage,
                    destStorage,
                    destRawStorage,
                    sessionId,
                    assetId,
                    newAssetId,
                    assetType,
                    if (info) |fileInfo| fileInfo.contentType else null,
                    stream.reader(),
                    if (info) |fileInfo| fileInfo.length else null,
                );
            }
        }

        // `{ ...metadata, _id: newAssetId }`.
        var newMetadata: BsonDocument = .{
            .fields = try metadata.fields.clone(allocator),
        };
        try newMetadata.put(allocator, "_id", .{ .string = newAssetId });
        var upsertOperation: UpsertMetadataOperation = .{
            .metadataCollection = destDb.metadataCollection,
            .newAssetId = newAssetId,
            .updates = newMetadata,
        };
        _ = try retry(io, log, &upsertOperation, 3, 1_000, 2, 30_000, null);
        try destDb.bsonDatabase.commit(io, log);

        try removeAsset(
            allocator,
            io,
            log,
            sourceStorage,
            sourceRawStorage,
            sessionId,
            sourceDb.bsonDatabase,
            sourceDb.metadataCollection,
            assetId,
            true,
        );
    }

    const result: IMoveAssetsResult = .{
        .movedCount = assetIds.len,
    };
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

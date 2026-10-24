//
// Load assets worker handler - loads assets from database in pages
//

const std = @import("std");
const Timers = @import("ziggy").timers.Timers;
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const open_storage = @import("open-storage.zig");
const bson_json = @import("bson-json.zig");
const errors = utils.errors;
const log = &utils.log.log;
const ITaskContext = task_queue_zig.types.ITaskContext;
const TaskPriority = task_queue_zig.types.TaskPriority;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;
const createLazyDatabaseStorage = media_file_database.createLazyDatabaseStorage;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const isDatabasePartial = media_file_database.isDatabasePartial;
const openStorage = open_storage.openStorage;
const ILoadAssetsData = api.load_assets_types.ILoadAssetsData;
const ILoadAssetsResult = api.load_assets_types.ILoadAssetsResult;
const IAssetPageEvent = api.load_assets_types.IAssetPageEvent;

//
// The fields of a record that are sent for gallery display, in the order they are sent. The `properties` field (EXIF
// data) is intentionally excluded: structured clone deserialization of large EXIF objects blocks
// the renderer's main thread for hundreds of milliseconds per batch, causing 2-9fps during
// loading. `properties` can be fetched on demand when a detail view opens.
//
const GALLERY_FIELD_NAMES = [_][]const u8{
    "_id",
    "origFileName",
    "origPath",
    "contentType",
    "width",
    "height",
    "hash",
    "location",
    "coordinates",
    "fileDate",
    "photoDate",
    "uploadDate",
    "labels",
    "description",
    "deleted",
    "micro",
    "color",
};

//
// Picks the fields of a record that are sent for gallery display. A field the record does not hold is left out.
// (Zig: the batch is a list of JSON values.)
//
fn galleryRecordToJson(allocator: std.mem.Allocator, record: api.asset_query.IAsset) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    for (GALLERY_FIELD_NAMES) |fieldName| {
        const value = record.get(fieldName) orelse {
            continue;
        };
        if (value == .undefined) {
            continue;
        }
        try object.put(allocator, fieldName, try bson_json.bsonValueToJson(allocator, value));
    }
    return .{
        .object = object,
    };
}

//
// Handler for loading assets from database
// Note: This handler sends progress messages via a callback mechanism
// The actual streaming is handled by the dev-server which sends messages to the frontend
// (Zig: the task data and output are JSON values holding ILoadAssetsData and ILoadAssetsResult.)
//
pub fn loadAssetsHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(ILoadAssetsData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;

    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const runStartedAt = timestampProvider.now(io);

    log.info(try std.fmt.allocPrint(allocator, "Loading assets from database \"{s}\"", .{data.databasePath}));

    const opened = try openStorage(allocator, io, data.databasePath, null, null, context.nativeCaller);
    const plainStorage = opened.storage;
    const isPartial = try isDatabasePartial(allocator, io, data.databasePath, opened.s3Config, opened.storageOptions);

    // Only wrap in lazy storage for partial databases; plain storage otherwise.
    const storage = if (isPartial)
        try createLazyDatabaseStorage(allocator, io, data.databasePath, opened.s3Config, opened.storageOptions, context.nativeCaller)
    else
        plainStorage;

    // Create database instance
    const database = try createMediaFileDatabase(allocator, storage, uuidGenerator, timestampProvider);

    const metadataCollection = database.metadataCollection;

    // Iterate through assets in sorted order (by photoDate, descending)
    // Data is already organized into pages, so we send each page as-is
    var nextPageId: ?[]const u8 = null;
    var totalAssets: u64 = 0;
    var batchesSent: u64 = 0;

    while (!context.isCancelled(io, allocator)) {
        //todo: The sort order should be configurable.
        const sortIndex = try metadataCollection.sortIndex("photoDate", .desc);
        const result = try sortIndex.getPage(io, nextPageId);

        if (result.records.len == 0) {
            break;
        }

        // Send the entire page
        totalAssets += result.records.len;
        batchesSent += 1;

        // Whitelist only the fields needed for gallery display.
        const batch = try allocator.alloc(std.json.Value, result.records.len);
        for (result.records, 0..) |record, index| {
            batch[index] = try galleryRecordToJson(allocator, record);
        }

        // Send page via message
        const pageMessage: IAssetPageEvent = .{
            .type = "asset-page",
            .databasePath = data.databasePath,
            .batch = batch,
        };
        context.sendEvent(io, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, pageMessage, .{}), .{}));

        // The same count as the job the interface lists and can cancel. Indeterminate: the pages are
        // walked one at a time and how many there are is not known until the last one comes back.
        try sendJobProgress(allocator, io, context, data.job, runStartedAt, try std.fmt.allocPrint(allocator, "{d} assets loaded", .{totalAssets}));

        if (result.nextPageId == null) {
            break;
        }

        nextPageId = result.nextPageId;
    }

    if (isPartial) {
        // Queue thumb prefetch only for partial databases. Explicitly background, because it would
        // otherwise inherit this task's interactive priority and hold an engine for as long as it
        // takes to pull down every thumbnail, which is exactly the work interactive tasks must not
        // wait behind.
        // The queue is not shut down, which would cancel the prefetch. It is in the task's memory, which goes when the task ends, as
        // its subscriptions do.
        const queue = try TaskQueue.init(allocator, context.uuidGenerator, data.databasePath);
        var prefetchData: std.json.ObjectMap = .empty;
        try prefetchData.put(allocator, "databasePath", .{
            .string = data.databasePath,
        });
        _ = try queue.addTask(io, allocator, "prefetch-database", .{
            .object = prefetchData,
        }, null, TaskPriority.Background);
    }

    const loadResult: ILoadAssetsResult = .{
        .totalAssets = totalAssets,
        .batchesSent = batchesSent,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, loadResult, .{}), .{});
}

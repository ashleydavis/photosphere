const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const errors = utils.errors;
const IStorage = storage_zig.storage.IStorage;
const ITaskContext = task_queue_zig.types.ITaskContext;
const ISaveAssetItem = api.save_assets_types.ISaveAssetItem;
const createLazyDatabaseStorage = media_file_database.createLazyDatabaseStorage;
const streamAsset = media_file_database.streamAsset;

//
// Returns a lazy storage instance for the given database path.
// (A cache of these would need a global variable, which this repository avoids, and a task handler is a plain function with
// no state of its own to keep a cache in. A new storage is made for every call, which is once per task here.)
//
fn getAssetStorage(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8, host: ?utils.host_requester.IHostRequester) !IStorage {
    return createLazyDatabaseStorage(allocator, io, databasePath, null, null, host);
}

//
// Data payload for the save-assets-batch task.
//
pub const ISaveAssetsBatchData = struct {
    //
    // The assets to download.
    //
    assets: []const ISaveAssetItem,

    //
    // The destination folder chosen by the user.
    //
    folderPath: []const u8,

    //
    // The database path the assets belong to.
    //
    databasePath: []const u8,
};

//
// Details of a single file that failed to save.
//
pub const ISaveAssetsBatchFailure = struct {
    //
    // The filename of the asset that failed.
    //
    filename: []const u8,

    //
    // The error message describing why the save failed.
    //
    @"error": []const u8,
};

//
// Result returned by the save-assets-batch task.
//
pub const ISaveAssetsBatchResult = struct {
    //
    // The destination folder all files were saved into.
    //
    folderPath: []const u8,

    //
    // Filenames of assets that were saved successfully.
    //
    succeededFiles: []const []const u8,

    //
    // Details of assets that failed to save.
    //
    failedFiles: []const ISaveAssetsBatchFailure,
};

//
// Saves one asset into the folder: the body of the try block of the loop in saveAssetsBatchHandler.
// (Zig needs it as a function to catch the error it fails with.)
//
fn saveAsset(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, folderPath: []const u8, asset: ISaveAssetItem) !void {
    const destPath = try node_utils.path.join(allocator, &.{ folderPath, asset.filename });
    const assetStream = try streamAsset(allocator, io, storage, asset.assetId, asset.assetType);
    defer assetStream.destroy(io);
    const outputFile = try std.Io.Dir.cwd().createFile(io, destPath, .{});
    defer outputFile.close(io);
    var writeBuffer: [64 * 1024]u8 = undefined;
    var fileWriter = outputFile.writerStreaming(io, &writeBuffer);
    _ = try assetStream.reader().streamRemaining(&fileWriter.interface);
    try fileWriter.interface.flush();
}

//
// Background task handler that saves multiple assets into a single folder.
// Processes each asset individually and accumulates success and failure results.
// (Zig: the task data and output are JSON values holding ISaveAssetsBatchData and ISaveAssetsBatchResult. The context is
// ignored. Reading the task data into the typed struct fails when a key is missing or is not of the type
// the interface names; the failure is reported as a sentence, not a bare parser
// error name.)
//
pub fn saveAssetsBatchHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = std.json.parseFromValueLeaky(ISaveAssetsBatchData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The save-assets-batch task data is not valid: assets must be a list of items with assetId, assetType and filename, and folderPath and databasePath must be strings", .{});
    };
    const storage = try getAssetStorage(allocator, io, data.databasePath, context.hostRequester);
    var succeededFiles: std.ArrayList([]const u8) = .empty;
    var failedFiles: std.ArrayList(ISaveAssetsBatchFailure) = .empty;

    for (data.assets) |asset| {
        saveAsset(allocator, io, storage, data.folderPath, asset) catch |err| {
            try failedFiles.append(allocator, .{
                .filename = asset.filename,
                .@"error" = try allocator.dupe(u8, errors.errorMessage(err)),
            });
            continue;
        };
        try succeededFiles.append(allocator, asset.filename);
    }

    const result: ISaveAssetsBatchResult = .{
        .folderPath = data.folderPath,
        .succeededFiles = succeededFiles.items,
        .failedFiles = failedFiles.items,
    };
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

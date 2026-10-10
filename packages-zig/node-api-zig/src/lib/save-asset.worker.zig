const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const media_file_database = @import("media-file-database.zig");
const errors = utils.errors;
const IStorage = storage_zig.storage.IStorage;
const ITaskContext = task_queue_zig.types.ITaskContext;
const createLazyDatabaseStorage = media_file_database.createLazyDatabaseStorage;
const streamAsset = media_file_database.streamAsset;

//
// Returns a lazy storage instance for the given database path.
// (A cache of these would need a global variable, which this repository avoids, and a task handler is a plain function with
// no state of its own to keep a cache in. A new storage is made for every call.)
//
fn getAssetStorage(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8, host: ?utils.host_requester.IHostRequester) !IStorage {
    return createLazyDatabaseStorage(allocator, io, databasePath, null, null, host);
}

//
// Data payload for the save-asset task.
//
pub const ISaveAssetData = struct {
    //
    // The ID of the asset to save.
    //
    assetId: []const u8,

    //
    // The asset type to fetch (e.g. "asset", "display", "thumb").
    //
    assetType: []const u8,

    //
    // The destination file path chosen by the user.
    //
    destPath: []const u8,

    //
    // The database path the asset belongs to.
    //
    databasePath: []const u8,
};

//
// Background task handler that streams an asset from the database to a local file.
// (Zig: the task data is a JSON value holding ISaveAssetData, and the output is JSON null.
// The context is ignored. Reading the task data into the typed struct fails when a key is missing or is not a
// string; the failure is reported as a sentence, not a bare parser error name.)
//
pub fn saveAssetHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = std.json.parseFromValueLeaky(ISaveAssetData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The save-asset task data is not valid: assetId, assetType, destPath and databasePath must be strings", .{});
    };

    const storage = try getAssetStorage(allocator, io, data.databasePath, context.hostRequester);
    const assetStream = try streamAsset(allocator, io, storage, data.assetId, data.assetType);
    defer assetStream.destroy(io);
    const outputFile = try std.Io.Dir.cwd().createFile(io, data.destPath, .{});
    defer outputFile.close(io);
    var writeBuffer: [64 * 1024]u8 = undefined;
    var fileWriter = outputFile.writerStreaming(io, &writeBuffer);
    _ = try assetStream.reader().streamRemaining(&fileWriter.interface);
    try fileWriter.interface.flush();
    return .null;
}

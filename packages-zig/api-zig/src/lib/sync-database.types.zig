const std = @import("std");
const serialization_zig = @import("serialization-zig");
const task_queue_zig = @import("ziggy-core").task_queue;
const bson = serialization_zig.bson;
const IJobTag = task_queue_zig.types.IJobTag;

//
// Input data for the sync-database background task.
// (Zig: task data travels as JSON (std.json.Value); the defaults let std.json parse data that leaves keys out,
// so the handler can refuse a missing databasePath with its own message.)
//
pub const ISyncDatabaseData = struct {
    //
    // Absolute path to the local replica database.
    //
    databasePath: []const u8 = "",

    //
    // Names the job this task belongs to, so the sync shows up in the interface's job list. It
    // carries no cancel source: a sync is queued by the host under a source the interface never
    // learns, and syncing is switched off from Settings rather than stopped from the job list.
    //
    job: ?IJobTag = null,
};

//
// The kind of a change.
//
pub const SyncChangeType = enum {
    // A new asset from origin.
    added,

    // A merged asset.
    updated,

    // An asset removed because origin deleted it.
    deleted,
};

//
// A single change to the local database detected during the pull phase of a sync.
// (Zig: the asset is the BSON document of its record, as IAsset records are BSON documents.)
//
pub const ISyncChange = struct {
    //
    // The kind of change: "added" (new asset from origin), "updated" (merged asset),
    // or "deleted" (asset removed because origin deleted it).
    //
    type: SyncChangeType,

    //
    // The full asset record. Present for "added" and "updated".
    //
    asset: ?bson.BsonDocument = null,

    //
    // The ID of the deleted asset. Present for "deleted".
    //
    assetId: ?[]const u8 = null,
};

//
// Task message sent when a sync returns early without running, so the UI can report why a
// requested sync produced no sync-started / sync-completed pair. Without this a skipped sync is
// silent on the frontend and indistinguishable from a sync that never started.
//
pub const ISyncSkippedMessage = struct {
    //
    // Message type discriminator ("sync-skipped").
    //
    type: []const u8,

    //
    // The path of the local database whose sync was skipped.
    //
    databasePath: []const u8,

    //
    // Human-readable explanation of why the sync was skipped.
    //
    reason: []const u8,
};

//
// Task message sent when a sync has finished running, so the UI can report the outcome.
//
pub const ISyncCompletedMessage = struct {
    //
    // Message type discriminator ("sync-completed").
    //
    type: []const u8,

    //
    // The path of the local database that was synced.
    //
    databasePath: []const u8,

    //
    // False when the sync ran but both sides already held identical content, so nothing was
    // transferred. True when records or files moved in either direction.
    //
    synced: bool,
};

//
// Task message sent during a sync to carry a batch of incremental changes to the UI.
// (Zig: the assets are the JSON values of their records, as task messages are JSON.)
//
pub const ISyncBatchMessage = struct {
    //
    // Message type discriminator ("sync-batch").
    //
    type: []const u8,

    //
    // The path of the local database being synced.
    // Used by the UI to discard batches that belong to a closed database.
    //
    databasePath: []const u8,

    //
    // Assets that were added to the local database from origin in this batch.
    //
    added: []const std.json.Value,

    //
    // Assets whose metadata was updated in the local database in this batch.
    //
    updated: []const std.json.Value,

    //
    // IDs of assets that were deleted from the local database in this batch.
    //
    deletedIds: []const []const u8,
};

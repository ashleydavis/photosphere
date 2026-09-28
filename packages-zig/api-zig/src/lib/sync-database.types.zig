const serialization_zig = @import("serialization-zig");
const bson = serialization_zig.bson;

// Not ported: ISyncDatabaseData, ISyncSkippedMessage, ISyncCompletedMessage, ISyncBatchMessage (not used by psi
// sync).

//
// The kind of a change (TypeScript: the string union of ISyncChange.type).
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

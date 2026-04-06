import type { IAsset } from "defs";

//
// Input data for the sync-database background task.
//
export interface ISyncDatabaseData {
    //
    // Absolute path to the local replica database.
    //
    databasePath: string;
}

//
// A single change to the local database detected during the pull phase of a sync.
//
export interface ISyncChange {
    //
    // The kind of change: "added" (new asset from origin), "updated" (merged asset),
    // or "deleted" (asset removed because origin deleted it).
    //
    type: "added" | "updated" | "deleted";

    //
    // The full asset record. Present for "added" and "updated".
    //
    asset?: IAsset;

    //
    // The ID of the deleted asset. Present for "deleted".
    //
    assetId?: string;
}

//
// Task message sent during a sync to carry a batch of incremental changes to the UI.
//
export interface ISyncBatchMessage {
    //
    // Message type discriminator.
    //
    type: "sync-batch";

    //
    // The path of the local database being synced.
    // Used by the UI to discard batches that belong to a closed database.
    //
    databasePath: string;

    //
    // Assets that were added to the local database from origin in this batch.
    //
    added: IAsset[];

    //
    // Assets whose metadata was updated in the local database in this batch.
    //
    updated: IAsset[];

    //
    // IDs of assets that were deleted from the local database in this batch.
    //
    deletedIds: string[];
}

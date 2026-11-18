import type { IAsset } from "./asset";

//
// Task message sent during a sync to carry a batch of incremental changes to the UI.
//
export interface ISyncBatchEvent {
    //
    // Event type discriminator.
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

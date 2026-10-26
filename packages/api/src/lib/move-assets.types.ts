//
// The data the user interface queues the move-assets background task with.
//

//
// Input data for the move-assets background task.
//
export interface IMoveAssetsData {
    //
    // Filesystem path (or S3 path) to the source database.
    //
    sourceDatabasePath: string;

    //
    // Filesystem path (or S3 path) to the destination database.
    //
    destDatabasePath: string;

    //
    // IDs of the assets to move from source to destination.
    //
    assetIds: string[];
}

//
// The data of the get-database-summary background task: what the user interface queues it with and the summary it returns.
//

//
// Whether a database holds every asset ("full") or is a partial replica that fetches assets
// lazily from the database's origin.
//
export type DatabaseMode = "full" | "partial";

//
// A summary of a database, returned by the get-database-summary task.
//
export interface IDatabaseSummary {
    //
    // Whether this database is a full copy or a partial replica.
    //
    mode: DatabaseMode;

    //
    // Total number of files imported into the database.
    //
    totalImports: number;

    //
    // Total number of files in the database (including thumbnails, display images, BSON files, etc.).
    //
    totalFiles: number;

    //
    // Total size of all files in bytes.
    //
    totalSize: number;

    //
    // Total number of nodes in the merkle tree.
    //
    totalNodes: number;

    //
    // Full hash of the tree root.
    //
    fullHash: string;

    //
    // Root hash of the files merkle tree.
    //
    filesHash: string | undefined;

    //
    // Root hash of the BSON database merkle tree.
    //
    databaseHash: string | undefined;

    //
    // Database version from merkle tree.
    //
    databaseVersion: number;
}

//
// Input data for the get-database-summary task.
//
export interface IGetDatabaseSummaryData {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: string;
}

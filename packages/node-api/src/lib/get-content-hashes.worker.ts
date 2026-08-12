import type { ITaskContext } from "task-queue";
import { loadAssetContentHashes } from "./auto-import.worker";
import { openStorage } from "./open-storage";

//
// Every content hash the database holds an original for.
//
// This exists for automatic import on mobile, where the loop runs in the WebView and cannot open the
// database's storage itself. Cleanup deletes a photo from the device only once the database is
// confirmed to hold a file with that content hash, and this is how the WebView asks the database
// rather than taking the import's word for it.
//

//
// Input data for the get-content-hashes task.
//
export interface IGetContentHashesData {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: string;
}

//
// What the task returns.
//
// A list rather than a Set because the result crosses a task boundary as JSON, and a Set does not
// survive that.
//
export interface IGetContentHashesResult {
    //
    // Every content hash the database holds an original for, lower-case hex.
    //
    contentHashes: string[];
}

//
// Task handler returning the database's content hashes.
//
export async function getContentHashesHandler(
    data: IGetContentHashesData,
    _context: ITaskContext
): Promise<IGetContentHashesResult> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const { storage } = await openStorage(data.databasePath);
    const hashes = await loadAssetContentHashes(storage);
    return { contentHashes: Array.from(hashes) };
}

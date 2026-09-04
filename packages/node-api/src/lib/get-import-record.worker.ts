import type { ITaskContext } from "task-queue";
import { IImportRecord } from "api/src/lib/import-record";
import { loadImportRecord } from "./import-record-storage";

//
// What this machine has imported into a database, for the Import page to show.
//
// This exists so opening a database shows what it last took in, rather than only what happened while
// the app has been running. The interface cannot reach the machine's cache directory itself, on any
// platform, so it asks through here.
//
// The database's storage is never opened: the record is a local file beside the hash cache, so the
// record can be read for a database whose credentials are missing or whose remote is unreachable.
//

//
// Input data for the get-import-record task.
//
export interface IGetImportRecordData {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: string;
}

//
// Task handler returning the database's import record.
//
export async function getImportRecordHandler(
    data: IGetImportRecordData,
    _context: ITaskContext
): Promise<IImportRecord> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    return await loadImportRecord(data.databasePath);
}

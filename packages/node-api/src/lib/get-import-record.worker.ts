import type { ITaskContext } from "task-queue";
import { IImportRecord } from "api/src/lib/import-record";
import { loadImportRecord } from "./import-record-storage";
import { openStorage } from "./open-storage";

//
// What a database has imported, for the Import page to show.
//
// This exists so opening a database shows what it last took in, rather than only what happened while
// the app has been running. The interface cannot open the database's storage itself, on any
// platform, so it asks through here.
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

    const { storage } = await openStorage(data.databasePath);
    return await loadImportRecord(storage);
}

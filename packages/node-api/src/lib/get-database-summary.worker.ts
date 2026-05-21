import type { ITaskContext } from "task-queue";
import { getDatabaseSummary } from "./media-file-database";
import type { IDatabaseSummary } from "./media-file-database";
import { openStorage } from "./open-storage";

//
// Input data for the get-database-summary task.
//
export interface IGetDatabaseSummaryData {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: string;
}

//
// Task handler that computes a summary of the database at the given path.
// Returns the summary as the task result.
//
export async function getDatabaseSummaryHandler(
    data: IGetDatabaseSummaryData,
    _context: ITaskContext
): Promise<IDatabaseSummary> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const { storage } = await openStorage(data.databasePath);
    return await getDatabaseSummary(storage);
}

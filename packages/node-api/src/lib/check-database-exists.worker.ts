//
// Check-database-exists worker handler.
//
// Runs on both platforms via the shared task queue: desktop registers it through initTaskHandlers and
// mobile through mobile-worker-entry, so "the database exists" means the same thing everywhere. The
// handler reuses checkConnectivity, which builds storage for the path (FileStorage over the native
// host.fs* functions on device, real fs on desktop/worker threads) and asks whether the database's
// merkle tree file exists, so a directory that exists but holds no database reads as absent identically
// on desktop and mobile.
//

import type { ITaskContext } from "task-queue";
import { checkConnectivity } from "./media-file-database";

//
// Input for the check-database-exists task.
//
export interface ICheckDatabaseExistsData {
    // The database path to probe (sandbox-relative on device, e.g. "my-db", or an fs:/s3: path).
    databasePath: string;
}

//
// Result of the check-database-exists task.
//
export interface ICheckDatabaseExistsResult {
    // True when a real database is accessible at the path (its merkle tree file exists).
    exists: boolean;
}

//
// Handler for the check-database-exists task. Returns whether an accessible database lives at the
// given path, reusing checkConnectivity so "exists" means the same thing on desktop and mobile.
//
export async function checkDatabaseExistsHandler(data: ICheckDatabaseExistsData, _context: ITaskContext): Promise<ICheckDatabaseExistsResult> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const exists = await checkConnectivity(data.databasePath);
    return { exists };
}

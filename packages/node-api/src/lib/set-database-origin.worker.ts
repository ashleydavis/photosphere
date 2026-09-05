import type { ITaskContext } from "task-queue";
import { updateDatabaseConfig } from "api/src/lib/database-config";
import { openStorage } from "./open-storage";

//
// Records where a database syncs to, in the database's own config.
//
// The origin has to live inside the database because that is where every sync reads it from: a
// background pass runs when there is no interface and nothing has been opened, so it opens the
// database it was told to sync and asks that. A copy kept only in the machine's database list is a
// copy the sync loop never sees, which is a database that silently never syncs.
//
// The interface cannot write into a database's storage on any platform, so it asks through here.
// Desktop does the same work in its own process; this exists for mobile, where the WebView has no
// filesystem and every storage write goes through a task.
//

//
// Input data for the set-database-origin task.
//
export interface ISetDatabaseOriginData {
    //
    // Filesystem path (or S3 path) to the database whose origin is being set.
    //
    databasePath: string;

    //
    // Where the database syncs to. Undefined clears the origin, which stops it syncing anywhere.
    //
    origin?: string;
}

//
// Task handler that writes the origin into the database's config.
//
export async function setDatabaseOriginHandler(
    data: ISetDatabaseOriginData,
    _context: ITaskContext
): Promise<void> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const { rawStorage } = await openStorage(data.databasePath);
    await updateDatabaseConfig(rawStorage, { origin: data.origin });
}

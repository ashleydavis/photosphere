import { IBackfillCursor } from "api/src/lib/auto-import-queue";
import { IConfig } from "user-interface";

//
// Where automatic import's backfill has reached on this device.
//
// The CLI and the desktop record this in the database's own state, under the write lock. Mobile
// cannot: the loop runs in the WebView, which has no way to open the database's storage, and adding
// a task for each read and write would put a task in the engine pool every batch just to save two
// fields. It is kept in the app's config instead, which is the frontend's own bookkeeping.
//
// Losing it is harmless rather than dangerous: the backfill restarts from the beginning of the
// library and the import recognises everything it already holds by content hash. What it costs is
// time, which is why it is kept at all.
//

//
// Config key holding the backfill position for each database.
//
export const AUTO_IMPORT_BACKFILL_CURSORS_KEY = "autoImportBackfillCursors";

//
// The stored positions, keyed by database path.
//
// Keyed rather than single because the default database can be changed: a position from one
// database's library walk means nothing in another's, and reusing it would skip photos.
//
export interface IStoredBackfillCursors {
    // The position for each database path that has one.
    [databasePath: string]: IBackfillCursor;
}

//
// Reads where the backfill had reached for a database, starting at the beginning when there is
// nothing recorded or what is recorded cannot be read.
//
export async function loadBackfillCursor(config: IConfig, databasePath: string): Promise<IBackfillCursor> {
    const stored = await config.get<IStoredBackfillCursors>(AUTO_IMPORT_BACKFILL_CURSORS_KEY);
    const cursor = stored ? stored[databasePath] : undefined;

    if (!cursor || typeof cursor !== "object") {
        return { pageCursor: undefined, completed: false };
    }

    return {
        pageCursor: typeof cursor.pageCursor === "string" ? cursor.pageCursor : undefined,
        completed: cursor.completed === true,
    };
}

//
// Records where the backfill has reached for a database, leaving every other database's position
// alone.
//
export async function saveBackfillCursor(config: IConfig, databasePath: string, cursor: IBackfillCursor): Promise<void> {
    const stored = await config.get<IStoredBackfillCursors>(AUTO_IMPORT_BACKFILL_CURSORS_KEY);
    const updated: IStoredBackfillCursors = { ...(stored ?? {}) };
    updated[databasePath] = { pageCursor: cursor.pageCursor, completed: cursor.completed };
    await config.set(AUTO_IMPORT_BACKFILL_CURSORS_KEY, updated);
}

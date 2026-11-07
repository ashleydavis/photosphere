import * as fs from "fs/promises";
import { updateFileOptimistic } from "node-utils";
import { swallowError } from "utils";
import {
    IImportRecord,
    IImportRecordEntry,
    addImportEntries,
    createImportRecord,
    parseImportRecord,
    serializeImportRecord,
} from "api/src/lib/import-record";
import { getImportRecordPath } from "./database-cache-dir";

//
// Reading and writing this machine's record of what it imported into one database.
//
// The record is a local file in the machine's cache directory for that database, and it is reached
// through the filesystem only. Nothing here may go through IStorage on any platform: IStorage is how
// the database is reached, and this is not part of the database. It is this machine's account of
// what it did, and showing one machine's imports as another's would be a lie about where photos
// came from.
//
// Being outside the database is also what stops it travelling. Sync, replication and consolidation
// copy what the merkle tree indexes, and the tree indexes the database, so no arrangement is needed
// to keep this out of them.
//

//
// How many times a save retries when another process publishes a new record underneath it.
//
// The record is written once every IMPORT_RECORD_FLUSH_SIZE photos, so contention between the
// processes on one machine importing into one database is occasional rather than constant, and a
// handful of retries is plenty. Losing all of them means the save throws, and the entries are lost
// with it, which costs the history of those imports and nothing else.
//
const SAVE_RETRIES = 5;

//
// Reads this machine's import record for a database, returning an empty one when there is not a
// readable record.
//
// Never throws. This is a log of what happened rather than the photos themselves, so an unreadable
// one is worth losing, and is not worth failing an import or refusing to open a database over.
//
export async function loadImportRecord(databasePath: string): Promise<IImportRecord> {
    try {
        const fileContents = await fs.readFile(getImportRecordPath(databasePath), "utf8");
        return parseImportRecord(fileContents);
    }
    catch {
        // Missing, unreadable or not a record. Either way there is nothing to show.
        return createImportRecord();
    }
}

//
// Adds imports to this machine's record for a database, oldest first, and saves it.
//
// The read, the add and the write happen under an update lock beside the file, and are re-run from
// the winner's contents if another writer got in first. Without that the CLI and the desktop app
// importing into the same database at the same time would each read the same record, each add their
// own entries, and whichever wrote second would erase the other's.
//
// A failure to save is swallowed on purpose: the photos are already in the database, and losing the
// note about them must not turn a successful import into a failed one.
//
export async function recordImports(databasePath: string, newEntries: IImportRecordEntry[]): Promise<void> {
    if (newEntries.length === 0) {
        return;
    }

    await swallowError(async () => {
        await updateFileOptimistic(
            getImportRecordPath(databasePath),
            createImportRecord(),
            record => addImportEntries(record, newEntries),
            parseImportRecord,
            serializeImportRecord,
            SAVE_RETRIES,
        );
    });
}

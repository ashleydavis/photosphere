import { IStorage } from "storage";
import { swallowError } from "utils";
import {
    IImportRecord,
    IImportRecordEntry,
    IMPORT_RECORD_PATH,
    addImportEntries,
    createImportRecord,
    parseImportRecord,
    serializeImportRecord,
} from "api/src/lib/import-record";

//
// Reading and writing the database's import record.
//
// The record is written straight to storage and is never added to the merkle tree. That is what
// keeps it out of sync, replication and consolidation: those all copy what the tree indexes, so a
// file the tree does not know about does not travel. It must not travel, because it is this
// machine's account of what it did, and showing one machine's imports as another's would be a lie
// about where photos came from.
//

//
// Reads the database's import record, returning an empty one when there is not a readable record.
//
// Never throws. This is a log of what happened rather than the photos themselves, so an unreadable
// one is worth losing, and is not worth failing an import or refusing to open a database over.
//
export async function loadImportRecord(storage: IStorage): Promise<IImportRecord> {
    try {
        const buffer = await storage.read(IMPORT_RECORD_PATH);
        if (!buffer) {
            return createImportRecord();
        }
        return parseImportRecord(buffer.toString("utf8"));
    }
    catch {
        // Missing, unreadable or not a record. Either way there is nothing to show.
        return createImportRecord();
    }
}

//
// Adds imports to the database's record, oldest first, and saves it.
//
// A failure to save is swallowed on purpose: the photos are already in the database, and losing the
// note about them must not turn a successful import into a failed one.
//
export async function recordImports(storage: IStorage, newEntries: IImportRecordEntry[]): Promise<void> {
    if (newEntries.length === 0) {
        return;
    }

    await swallowError(async () => {
        const record = await loadImportRecord(storage);
        const updated = addImportEntries(record, newEntries);
        await storage.write(IMPORT_RECORD_PATH, "application/json", Buffer.from(serializeImportRecord(updated), "utf8"));
    });
}

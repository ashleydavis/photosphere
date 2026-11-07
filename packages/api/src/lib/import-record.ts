//
// What this database has taken in, so a user can ask what came in and get an answer.
//
// Manual imports and automatic ones go into the same list, newest first, because a user wanting to
// know what arrived does not care which asked for it, only which photos are now here. Each entry
// says which it was, so an unexpected one can be told apart at a glance.
//
// It is capped, because the alternative is a file that grows without limit on the device with the
// least room. When the cap is reached the oldest entries are dropped and the interface says so,
// rather than quietly presenting a partial history as a complete one.
//
// It belongs to the machine that wrote it, not to the database it describes, and it is kept on that
// machine: a local file in that machine's cache directory for that database. It must never be
// copied or synced to another machine, because it is this machine's account of what it did, not
// part of the photo collection.
//
// This file holds no path. Working out where the record goes needs a filesystem, and only node-api
// has one, so `getImportRecordPath` lives there. Everything here is the record's contents and the
// rules for reading, writing and capping them, which every platform shares.
//

//
// How many imports are remembered. Older ones are dropped.
//
export const MAX_IMPORT_RECORD_ENTRIES = 1000;

//
// Who asked for an import.
//
export type ImportSource = "manual" | "automatic";

//
// What became of one file an import looked at.
//
export type ImportOutcome = "imported" | "skipped" | "failed";

//
// One import, as the Import page shows it.
//
export interface IImportRecordEntry {
    // The id the asset was given in the database, or an empty string when it never got one.
    assetId: string;

    // Where the file came from.
    logicalPath: string;

    // What became of it.
    outcome: ImportOutcome;

    // When it happened, as an ISO date-time.
    importedAt: string;

    // Whether the user asked for this import or it arrived on its own.
    source: ImportSource;

    // Base64-encoded JPEG micro thumbnail, when one was made. Absent for a skip or a failure.
    micro?: string;
}

//
// The whole record, as it is stored.
//
export interface IImportRecord {
    // The imports, newest first.
    entries: IImportRecordEntry[];

    // True once something has been dropped for being older than the cap, so the interface can say
    // that what it is showing is not the whole history.
    truncated: boolean;
}

//
// An empty record, for a database that has imported nothing.
//
export function createImportRecord(): IImportRecord {
    return { entries: [], truncated: false };
}

//
// Returns the record with the given imports added, newest first, capped.
//
// The new entries are taken as being in the order they happened, so the last of them ends up first.
// Nothing is mutated: the caller decides what to do with the result.
//
export function addImportEntries(record: IImportRecord, newEntries: IImportRecordEntry[]): IImportRecord {
    if (newEntries.length === 0) {
        return record;
    }

    const newestFirst = [...newEntries].reverse();
    const combined = newestFirst.concat(record.entries);

    if (combined.length <= MAX_IMPORT_RECORD_ENTRIES) {
        return { entries: combined, truncated: record.truncated };
    }

    return {
        entries: combined.slice(0, MAX_IMPORT_RECORD_ENTRIES),
        // Once something has been dropped it stays true: the history has a hole in it from then on.
        truncated: true,
    };
}

//
// Reads a record out of what was stored, repairing anything that is not a record.
//
// A record that cannot be read is not worth failing an import over, and it is not worth showing
// either: it is a log of what happened, not the photos themselves. An unreadable one is treated as
// empty and overwritten by the next import.
//
export function parseImportRecord(fileContents: string): IImportRecord {
    let parsed: any;
    try {
        parsed = JSON.parse(fileContents);
    }
    catch {
        return createImportRecord();
    }

    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.entries)) {
        return createImportRecord();
    }

    const entries: IImportRecordEntry[] = [];
    for (const candidate of parsed.entries) {
        if (!candidate || typeof candidate !== "object") {
            continue;
        }
        if (typeof candidate.logicalPath !== "string") {
            continue;
        }
        if (candidate.outcome !== "imported" && candidate.outcome !== "skipped" && candidate.outcome !== "failed") {
            continue;
        }
        if (candidate.source !== "manual" && candidate.source !== "automatic") {
            continue;
        }

        entries.push({
            assetId: typeof candidate.assetId === "string" ? candidate.assetId : "",
            logicalPath: candidate.logicalPath,
            outcome: candidate.outcome,
            importedAt: typeof candidate.importedAt === "string" ? candidate.importedAt : "",
            source: candidate.source,
            micro: typeof candidate.micro === "string" ? candidate.micro : undefined,
        });
    }

    return {
        entries: entries.slice(0, MAX_IMPORT_RECORD_ENTRIES),
        truncated: parsed.truncated === true || entries.length > MAX_IMPORT_RECORD_ENTRIES,
    };
}

//
// Renders a record for storage.
//
export function serializeImportRecord(record: IImportRecord): string {
    return JSON.stringify(record);
}

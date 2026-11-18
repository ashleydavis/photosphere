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
// This file holds the types the interface reads the record through. The Zig import record storage
// reads, writes and caps the record.
//

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

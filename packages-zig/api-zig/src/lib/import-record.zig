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

const std = @import("std");

//
// How many imports are remembered. Older ones are dropped.
//
pub const MAX_IMPORT_RECORD_ENTRIES = 1000;

//
// Who asked for an import.
//
pub const ImportSource = enum {
    // The user asked for it.
    manual,

    // It arrived on its own.
    automatic,
};

//
// What became of one file an import looked at.
//
pub const ImportOutcome = enum {
    // It was added to the database.
    imported,

    // The database already held it.
    skipped,

    // It could not be imported.
    failed,
};

//
// One import, as the Import page shows it.
// (The field order is the order JSON.stringify writes them in; the `= null` default lets micro be left out.)
//
pub const IImportRecordEntry = struct {
    // The id the asset was given in the database, or an empty string when it never got one.
    assetId: []const u8,

    // Where the file came from.
    logicalPath: []const u8,

    // What became of it.
    outcome: ImportOutcome,

    // When it happened, as an ISO date-time.
    importedAt: []const u8,

    // Whether the user asked for this import or it arrived on its own.
    source: ImportSource,

    // Base64-encoded JPEG micro thumbnail, when one was made. Absent for a skip or a failure.
    micro: ?[]const u8 = null,
};

//
// The whole record, as it is stored.
//
pub const IImportRecord = struct {
    // The imports, newest first.
    entries: []const IImportRecordEntry,

    // True once something has been dropped for being older than the cap, so the interface can say
    // that what it is showing is not the whole history.
    truncated: bool,
};

//
// An empty record, for a database that has imported nothing.
//
pub fn createImportRecord() IImportRecord {
    return .{
        .entries = &.{},
        .truncated = false,
    };
}

//
// Returns the record with the given imports added, newest first, capped.
//
// The new entries are taken as being in the order they happened, so the last of them ends up first.
// Nothing is mutated: the caller decides what to do with the result.
//
pub fn addImportEntries(allocator: std.mem.Allocator, record: IImportRecord, newEntries: []const IImportRecordEntry) !IImportRecord {
    if (newEntries.len == 0) {
        return record;
    }

    var combined: std.ArrayList(IImportRecordEntry) = .empty;
    try combined.ensureTotalCapacity(allocator, newEntries.len + record.entries.len);
    var newEntryIndex = newEntries.len;
    while (newEntryIndex > 0) {
        newEntryIndex -= 1;
        combined.appendAssumeCapacity(newEntries[newEntryIndex]);
    }
    combined.appendSliceAssumeCapacity(record.entries);

    if (combined.items.len <= MAX_IMPORT_RECORD_ENTRIES) {
        return .{
            .entries = combined.items,
            .truncated = record.truncated,
        };
    }

    return .{
        .entries = combined.items[0..MAX_IMPORT_RECORD_ENTRIES],
        // Once something has been dropped it stays true: the history has a hole in it from then on.
        .truncated = true,
    };
}

//
// Gets a string property of a JSON object, or null when it is absent or not a string.
// (No TypeScript counterpart: TypeScript tests `typeof candidate.x === "string"` inline.)
//
fn stringProperty(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse {
        return null;
    };
    if (value != .string) {
        return null;
    }
    return value.string;
}

//
// Reads a record out of what was stored, repairing anything that is not a record.
//
// A record that cannot be read is not worth failing an import over, and it is not worth showing
// either: it is a log of what happened, not the photos themselves. An unreadable one is treated as
// empty and overwritten by the next import.
//
pub fn parseImportRecord(allocator: std.mem.Allocator, fileContents: []const u8) !IImportRecord {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, fileContents, .{}) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return createImportRecord();
    };

    if (parsed != .object) {
        return createImportRecord();
    }
    const entriesValue = parsed.object.get("entries") orelse {
        return createImportRecord();
    };
    if (entriesValue != .array) {
        return createImportRecord();
    }

    var entries: std.ArrayList(IImportRecordEntry) = .empty;
    for (entriesValue.array.items) |candidate| {
        if (candidate != .object) {
            continue;
        }
        const fields = candidate.object;
        const logicalPath = stringProperty(fields, "logicalPath") orelse {
            continue;
        };
        const outcomeText = stringProperty(fields, "outcome") orelse "";
        const outcome = std.meta.stringToEnum(ImportOutcome, outcomeText) orelse {
            continue;
        };
        const sourceText = stringProperty(fields, "source") orelse "";
        const source = std.meta.stringToEnum(ImportSource, sourceText) orelse {
            continue;
        };

        try entries.append(allocator, .{
            .assetId = stringProperty(fields, "assetId") orelse "",
            .logicalPath = logicalPath,
            .outcome = outcome,
            .importedAt = stringProperty(fields, "importedAt") orelse "",
            .source = source,
            .micro = stringProperty(fields, "micro"),
        });
    }

    const truncatedValue = parsed.object.get("truncated");
    const storedTruncated = truncatedValue != null and truncatedValue.? == .bool and truncatedValue.?.bool;
    return .{
        .entries = entries.items[0..@min(entries.items.len, MAX_IMPORT_RECORD_ENTRIES)],
        .truncated = storedTruncated or entries.items.len > MAX_IMPORT_RECORD_ENTRIES,
    };
}

//
// Renders a record for storage.
//
pub fn serializeImportRecord(allocator: std.mem.Allocator, record: IImportRecord) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, record, .{ .emit_null_optional_fields = false });
}

const std = @import("std");
const api = @import("api-zig");
const node_utils = @import("node-utils-zig");
const database_cache_dir = @import("database-cache-dir.zig");
const import_record = api.import_record;
const IImportRecord = import_record.IImportRecord;
const IImportRecordEntry = import_record.IImportRecordEntry;
const addImportEntries = import_record.addImportEntries;
const createImportRecord = import_record.createImportRecord;
const parseImportRecord = import_record.parseImportRecord;
const serializeImportRecord = import_record.serializeImportRecord;
const updateFileOptimistic = node_utils.fs.updateFileOptimistic;
const getImportRecordPath = database_cache_dir.getImportRecordPath;
const swallowError = @import("utils-zig").swallow_error.swallowError;

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
pub fn loadImportRecord(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8) !IImportRecord {
    const recordPath = try getImportRecordPath(allocator, databasePath);
    const fileContents = std.Io.Dir.cwd().readFileAlloc(io, recordPath, allocator, .unlimited) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }

        // Missing, unreadable or not a record. Either way there is nothing to show.
        return createImportRecord();
    };
    return parseImportRecord(allocator, fileContents);
}

//
// The mutator recordImports hands to updateFileOptimistic (TypeScript: `record => addImportEntries(record, newEntries)`).
//
const AddEntriesMutator = struct {
    // The imports to add.
    newEntries: []const IImportRecordEntry,

    //
    // Adds the imports to the record.
    //
    pub fn run(self: *const AddEntriesMutator, allocator: std.mem.Allocator, record: IImportRecord) !IImportRecord {
        return addImportEntries(allocator, record, self.newEntries);
    }
};

//
// The parse recordImports hands to updateFileOptimistic (TypeScript: parseImportRecord).
//
const ParseRecord = struct {
    //
    // Parses the stored text.
    //
    pub fn run(self: *const ParseRecord, allocator: std.mem.Allocator, fileContents: []const u8) !IImportRecord {
        _ = self;
        return parseImportRecord(allocator, fileContents);
    }
};

//
// The serialize recordImports hands to updateFileOptimistic (TypeScript: serializeImportRecord).
//
const SerializeRecord = struct {
    //
    // Renders the record.
    //
    pub fn run(self: *const SerializeRecord, allocator: std.mem.Allocator, record: IImportRecord) ![]const u8 {
        _ = self;
        return serializeImportRecord(allocator, record);
    }
};

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
pub fn recordImports(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8, newEntries: []const IImportRecordEntry) void {
    if (newEntries.len == 0) {
        return;
    }

    var operation: UpdateImportRecordOperation = .{
        .allocator = allocator,
        .databasePath = databasePath,
        .newEntries = newEntries,
    };
    _ = swallowError(io, &operation);
}

//
// The operation recordImports swallows the errors of (TypeScript: the arrow function passed to swallowError).
//
const UpdateImportRecordOperation = struct {
    // Allocates the record.
    allocator: std.mem.Allocator,

    // The database the record describes.
    databasePath: []const u8,

    // The imports to add.
    newEntries: []const IImportRecordEntry,

    //
    // Adds the imports to the record on disk.
    //
    pub fn run(self: *const UpdateImportRecordOperation, io: std.Io) !void {
        const mutator: AddEntriesMutator = .{ .newEntries = self.newEntries };
        const parse: ParseRecord = .{};
        const serialize: SerializeRecord = .{};
        try updateFileOptimistic(
            IImportRecord,
            self.allocator,
            io,
            try getImportRecordPath(self.allocator, self.databasePath),
            createImportRecord(),
            &mutator,
            &parse,
            &serialize,
            SAVE_RETRIES,
        );
    }
};

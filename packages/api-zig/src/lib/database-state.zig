//
// Database state stored at .db/state.dat.
// Holds runtime values that change as the database is modified, synced, or replicated.
// These are distinct from configuration (.db/config.json, which holds origin): the state file is
// rebuildable from the database's merkle trees, so a missing, empty, or corrupt file is simply
// treated as absent and rebuilt on the next write.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const write_lock = @import("write-lock.zig");
const IStorage = storage_zig.storage.IStorage;
const serialization = serialization_zig.serialization;
const save = serialization.save;
const load = serialization.load;
const ISerializer = serialization.ISerializer;
const IDeserializer = serialization.IDeserializer;
const acquireWriteLock = write_lock.acquireWriteLock;
const releaseWriteLock = write_lock.releaseWriteLock;

//
// Path of the database state file.
//
const STATE_PATH = ".db/state.dat";

//
// Four-character type code identifying the state file in the serialization header.
//
const STATE_TYPE_CODE = "DBST";

//
// Current on-disk version of the state file (independent of the merkle-tree version).
//
// Version 2 added the automatic import backfill cursor. Version 1 is still read, so a database
// written by an older build keeps its content hash and sync timestamps instead of losing them and
// forcing a full comparison on the next sync; it simply comes back with no backfill cursor, which
// is the same as never having run automatic import.
//
const STATE_VERSION = 2;

//
// Runtime state for a database.
// (Zig: null means the field is absent. A `Partial<IDatabaseState>` is also an IDatabaseState.)
//
pub const IDatabaseState = struct {
    // Combined merkle root hash of the database content (files-tree root combined with bson-db-tree root).
    // Two databases with the same content hash are identical, so this is used to skip a sync with no differences.
    contentHash: ?[]const u8 = null,
    // ISO date-time when the database was last modified locally (add, remove, edit metadata).
    lastModifiedAt: ?[]const u8 = null,
    // ISO date-time when the database was last synchronized with its origin.
    lastSyncedAt: ?[]const u8 = null,
    // ISO date-time when the database was last replicated (replica side).
    lastReplicatedAt: ?[]const u8 = null,
};

//
// Serializes the database state into the binary payload.
//
fn serializeDatabaseState(allocator: std.mem.Allocator, state: IDatabaseState, serializer: ISerializer) anyerror!void {
    _ = allocator;
    try serializer.writeBuffer(state.contentHash orelse "");
    try serializer.writeString(state.lastModifiedAt orelse "");
    try serializer.writeString(state.lastSyncedAt orelse "");
    try serializer.writeString(state.lastReplicatedAt orelse "");
}

//
// Deserializes the fields every version of the state file has.
// An empty buffer or empty string means the field is absent.
//
fn deserializeCommonDatabaseState(deserializer: IDeserializer) anyerror!IDatabaseState {
    const contentHash = try deserializer.readBuffer();
    const lastModifiedAt = try deserializer.readString();
    const lastSyncedAt = try deserializer.readString();
    const lastReplicatedAt = try deserializer.readString();

    var state: IDatabaseState = .{};
    if (contentHash.len > 0) {
        state.contentHash = contentHash;
    }
    if (lastModifiedAt.len > 0) {
        state.lastModifiedAt = lastModifiedAt;
    }
    if (lastSyncedAt.len > 0) {
        state.lastSyncedAt = lastSyncedAt;
    }
    if (lastReplicatedAt.len > 0) {
        state.lastReplicatedAt = lastReplicatedAt;
    }
    return state;
}

//
// Deserializes a state file of any version.
//
// A file written by an older build may hold more than this reads: version 2 used to carry the
// automatic import cursor, which is gone because every import now reads its sources from the
// beginning. Those trailing fields are simply not read, and what such a file says about the database
// itself, such as its content hash, is still honoured.
//
fn deserializeAnyDatabaseState(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!IDatabaseState {
    _ = allocator;
    _ = context;
    return deserializeCommonDatabaseState(deserializer);
}

//
// The deserializers of the state file by version (TypeScript: `{ 1: deserializeAnyDatabaseState, 2: deserializeAnyDatabaseState }`).
//
const state_deserializers = [_]serialization.DeserializerEntry(IDatabaseState, void){
    .{ .version = 1, .deserializer = deserializeAnyDatabaseState },
    .{ .version = 2, .deserializer = deserializeAnyDatabaseState },
};

//
// Loads the database state from .db/state.dat.
// Returns undefined if the file is missing, empty, truncated, or fails its checksum, so the caller
// rebuilds the state on the next write. Never throws for a bad file.
// (Zig: load takes no migrations or target version; with no migrations, STATE_VERSION has no effect.)
//
pub fn loadDatabaseState(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage) !?IDatabaseState {
    const state = load(
        IDatabaseState,
        allocator,
        io,
        rawStorage,
        STATE_PATH,
        STATE_TYPE_CODE,
        {},
        &state_deserializers,
    ) catch {
        // Missing, zero-byte, or corrupt file: treat as absent so it is rebuilt.
        return null;
    };
    return state;
}

//
// Saves the full database state to .db/state.dat.
// Lock-free primitive: the caller must already hold the database write lock (see acquireWriteLock).
//
pub fn saveDatabaseState(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, state: IDatabaseState) !void {
    try save(allocator, io, rawStorage, STATE_PATH, state, STATE_VERSION, STATE_TYPE_CODE, serializeDatabaseState);
}

//
// Merges partial into the existing state (or an empty state when absent) and saves it.
// Lock-free primitive: the caller must already hold the database write lock.
//
pub fn mergeDatabaseState(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, partial: IDatabaseState) !void {
    const existing = try loadDatabaseState(allocator, io, rawStorage);

    // `{ ...existing ?? {}, ...partial }`: a field partial holds replaces the existing one.
    var merged: IDatabaseState = existing orelse .{};
    inline for (@typeInfo(IDatabaseState).@"struct".fields) |field| {
        if (@field(partial, field.name)) |value| {
            @field(merged, field.name) = value;
        }
    }
    try saveDatabaseState(allocator, io, rawStorage, merged);
}

//
// Merges partial into the state while holding the write lock for the duration.
// For callers that do not already hold the lock. Silently does nothing if the lock cannot be acquired.
//
pub fn updateDatabaseStateLocked(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, sessionId: []const u8, partial: IDatabaseState) !void {
    if (!try acquireWriteLock(allocator, io, rawStorage, sessionId, 3)) {
        return;
    }
    // (Zig: the `finally` block; an error from releasing replaces the error of the merge, as in JavaScript.)
    mergeDatabaseState(allocator, io, rawStorage, partial) catch |err| {
        try releaseWriteLock(allocator, io, rawStorage);
        return err;
    };
    try releaseWriteLock(allocator, io, rawStorage);
}

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const tree = @import("tree.zig");
const errors = utils.errors;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IBsonCollection = bdb.collection.IBsonCollection;
const IDatabaseOp = api.database_op.IDatabaseOp;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;

//
// Groups operations by target database path (databaseId on each op), in the order the paths are first seen.
// (Zig: the Map is a std.StringArrayHashMapUnmanaged; the lists and the map are allocated with the allocator.)
//
pub fn groupOpsByDatabaseId(allocator: std.mem.Allocator, ops: []const IDatabaseOp) !std.StringArrayHashMapUnmanaged(std.ArrayList(IDatabaseOp)) {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(IDatabaseOp)) = .empty;
    for (ops) |op| {
        if (groups.getPtr(op.databaseId)) |existing| {
            try existing.append(allocator, op);
        }
        else {
            var group: std.ArrayList(IDatabaseOp) = .empty;
            try group.append(allocator, op);
            try groups.put(allocator, op.databaseId, group);
        }
    }
    return groups;
}

//
// Reads a JSON value as a BSON value.
//
fn toBsonValue(allocator: std.mem.Allocator, value: std.json.Value) !BsonValue {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return serialization_zig.json_parse.jsonParse(allocator, text);
}

//
// Whether two values are the same: scalars by value, while objects
// and arrays only by identity, which a value read from an operation never has with one already in the record.
//
fn isSameValue(left: BsonValue, right: BsonValue) bool {
    switch (left) {
        .document, .array, .binary => {
            return false;
        },
        else => {
            return left.eql(right);
        },
    }
}

//
// Applies a single metadata operation using the given metadata collection.
//
pub fn applyMetadataDatabaseOps(allocator: std.mem.Allocator, io: std.Io, metadataCollection: *IBsonCollection, ops: []const IDatabaseOp) !void {
    for (ops) |op| {
        if (!std.mem.eql(u8, op.collectionName, "metadata")) {
            return errors.throwError("Unsupported collection \"{s}\". Only \"metadata\" is supported.", .{op.collectionName});
        }

        switch (op.op) {
            .set => |setOp| {
                // Every field except _id: the record is addressed by recordId, so an _id in the fields is ignored.
                var updates: BsonDocument = .empty;
                var iterator = setOp.fields.iterator();
                while (iterator.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "_id")) {
                        continue;
                    }
                    try updates.put(allocator, entry.key_ptr.*, try toBsonValue(allocator, entry.value_ptr.*));
                }
                _ = try metadataCollection.updateOne(io, op.recordId, updates, .{
                    .upsert = true,
                });
            },
            .push => |pushOp| {
                const existing = try metadataCollection.getOne(io, op.recordId) orelse {
                    return errors.throwError("Cannot push: metadata record \"{s}\" does not exist.", .{op.recordId});
                };
                const previous = existing.get(pushOp.field);
                var asArray: std.ArrayList(BsonValue) = .empty;
                if (previous) |previousValue| {
                    if (previousValue == .array) {
                        try asArray.appendSlice(allocator, previousValue.array);
                    }
                }
                const value = try toBsonValue(allocator, pushOp.value);
                var included = false;
                for (asArray.items) |item| {
                    if (isSameValue(item, value)) {
                        included = true;
                        break;
                    }
                }
                if (!included) {
                    try asArray.append(allocator, value);
                }
                var partial: BsonDocument = .empty;
                try partial.put(allocator, pushOp.field, .{
                    .array = asArray.items,
                });
                _ = try metadataCollection.updateOne(io, op.recordId, partial, .{});
            },
            .pull => |pullOp| {
                const existing = try metadataCollection.getOne(io, op.recordId) orelse {
                    return errors.throwError("Cannot pull: metadata record \"{s}\" does not exist.", .{op.recordId});
                };
                const previous = existing.get(pullOp.field);
                const value = try toBsonValue(allocator, pullOp.value);
                var filtered: std.ArrayList(BsonValue) = .empty;
                if (previous) |previousValue| {
                    if (previousValue == .array) {
                        for (previousValue.array) |item| {
                            if (!isSameValue(item, value)) {
                                try filtered.append(allocator, item);
                            }
                        }
                    }
                }
                var partial: BsonDocument = .empty;
                try partial.put(allocator, pullOp.field, .{
                    .array = filtered.items,
                });
                _ = try metadataCollection.updateOne(io, op.recordId, partial, .{});
            },
        }
    }
}

//
// Persists metadata changes to disk for one or more databases (grouped by each op's databaseId).
// uuidGenerator and timestampProvider are passed through to the BSON database; sessionId owns .db/write.lock during writes.
// (Zig: the write lock is acquired with 3 attempts, the default of acquireWriteLock's maxAttempts, as Zig has no default
// parameter values; the lock is released before the failure of the try block is returned, as the finally block does.)
//
pub fn applyDatabaseOps(allocator: std.mem.Allocator, io: std.Io, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, sessionId: []const u8, ops: []const IDatabaseOp, host: ?utils.native_caller.INativeCaller) !void {
    if (ops.len == 0) {
        return;
    }

    const groups = try groupOpsByDatabaseId(allocator, ops);
    for (groups.keys(), groups.values()) |databasePath, pathOps| {
        const created = try storage_zig.storage_factory.createStorage(allocator, io, databasePath, null, null);
        const rawStorage = created.rawStorage;
        const assetStorage = try media_file_database.createLazyDatabaseStorage(allocator, io, databasePath, null, null, host);
        const database = try media_file_database.createMediaFileDatabase(allocator, assetStorage, uuidGenerator, timestampProvider);
        try media_file_database.loadSortIndexes(allocator, assetStorage, database.metadataCollection);

        if (!try api.write_lock.acquireWriteLock(allocator, io, rawStorage, sessionId, 3)) {
            return errors.throwError("Failed to acquire write lock.", .{});
        }

        const result = applyGroupUnderLock(allocator, io, assetStorage, rawStorage, database, pathOps.items);
        try api.write_lock.releaseWriteLock(allocator, io, rawStorage);
        try result;
    }
}

//
// The try block of applyDatabaseOps, run holding the write lock.
// Zig needs it as a function to release the lock whether it failed or not.
//
fn applyGroupUnderLock(allocator: std.mem.Allocator, io: std.Io, assetStorage: storage_zig.storage.IStorage, rawStorage: storage_zig.storage.IStorage, database: media_file_database.IMediaFileDatabase, pathOps: []const IDatabaseOp) !void {
    try applyMetadataDatabaseOps(allocator, io, database.metadataCollection, pathOps);
    try database.bsonDatabase.commit(io);
    try tree.stampDatabaseModified(allocator, io, assetStorage, rawStorage);
}

const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const BsonDocument = bson.BsonDocument;
const BsonCollection = bdb.collection.BsonCollection;
const IInternalRecord = bdb.shard.IInternalRecord;
const errors = utils.errors;

const io = std.testing.io;

//
// Counts onDirty notifications (TypeScript tests pass `() => {}`).
//
var dirty_notifications: u32 = 0;

//
// The onDirty callback given to the collection under test.
//
fn onDirty(context: *anyopaque) void {
    _ = context;
    dirty_notifications += 1;
}

//
// Generates tree and page ids.
//
var test_uuid_generator: utils.test_uuid_generator.TestUuidGenerator = .{};

//
// Creates the collection under test (TypeScript: the beforeEach block).
//
fn newCollection(allocator: std.mem.Allocator, storage: *MemoryStorage) !*BsonCollection {
    const collection = try allocator.create(BsonCollection);
    collection.* = BsonCollection.init(allocator, "users", "", storage.asStorage(), "", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider(), .{ .context = storage, .function = onDirty });
    return collection;
}

//
// Builds a TestUser record in internal form.
//
fn makeUser(allocator: std.mem.Allocator, id: []const u8, name: []const u8, age: f64, role: []const u8) !IInternalRecord {
    return .{
        ._id = id,
        .fields = try BsonDocument.fromFields(allocator, &.{
            .{ .key = "name", .value = .{ .string = name } },
            .{ .key = "email", .value = .{ .string = try std.fmt.allocPrint(allocator, "{s}@example.com", .{name}) } },
            .{ .key = "age", .value = .{ .number = age } },
            .{ .key = "role", .value = .{ .string = role } },
        }),
        .metadata = .empty,
    };
}

//
// Gets a record by id through its shard (TypeScript: getOne, which is not ported).
//
fn getRecord(collection: *BsonCollection, id: []const u8) !?IInternalRecord {
    const shard = try collection.shard(try collection.getShardId(id));
    return shard.record(io, id);
}

test "should delete a record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const user = try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 30, "user");

    // (Zig: insertOne is not ported; setInternalRecord inserts the record.)
    try collection.setInternalRecord(io, user);

    try std.testing.expect(try collection.deleteOne(io, user._id));
    try std.testing.expect((try collection.getOne(io, user._id)) == null);
}

test "should return false when deleting non-existent record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    try std.testing.expect(!try collection.deleteOne(io, "123e4567-e89b-12d3-a456-000000000000"));
}

test "should iterate through all records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const ids = [_][]const u8{ "123e4567-e89b-12d3-a456-426614174001", "123e4567-e89b-12d3-a456-426614174002", "123e4567-e89b-12d3-a456-426614174003" };
    for (ids) |id| {
        try collection.setInternalRecord(io, try makeUser(allocator, id, "User", 30, "user"));
    }

    var retrieved: std.ArrayList([]const u8) = .empty;
    var iterator = collection.iterateRecords();
    while (try iterator.next(io)) |record| {
        try retrieved.append(allocator, record._id);
    }

    try std.testing.expectEqual(ids.len, retrieved.items.len);
    for (ids) |id| {
        var found = false;
        for (retrieved.items) |retrievedId| {
            if (std.mem.eql(u8, retrievedId, id)) {
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "should list and delete sort indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    try (try collection.sortIndex("age", .asc)).ensure(io, collection, .number);
    try (try collection.sortIndex("role", .asc)).ensure(io, collection, .string);
    try (try collection.sortIndex("name", .desc)).ensure(io, collection, .string);

    const indexes = try collection.sortIndexes(io);
    try std.testing.expectEqual(@as(usize, 3), indexes.len);
    // (Zig: listDirs sorts the directory names, so the order is known.)
    try std.testing.expectEqualStrings("age", indexes[0].fieldName);
    try std.testing.expectEqual(bdb.sort_index.SortDirection.asc, indexes[0].direction);
    try std.testing.expectEqualStrings("name", indexes[1].fieldName);
    try std.testing.expectEqual(bdb.sort_index.SortDirection.desc, indexes[1].direction);
    try std.testing.expectEqualStrings("role", indexes[2].fieldName);
    // Not ported: dropping an index (drop is not used by psi replicate or psi verify).
}

test "should update sort index when record is updated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const john = try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "John Doe", 30, "user");
    const alice = try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "Alice Smith", 25, "admin");
    try collection.setInternalRecord(io, john);
    try collection.setInternalRecord(io, alice);

    const ageIndex = try collection.sortIndex("age", .asc);
    try ageIndex.ensure(io, collection, .number);

    // Verify initial sort order
    var values = try helpers.sortIndexValues(allocator, io, ageIndex);
    try std.testing.expectEqual(@as(f64, 25), values[0].number); // Alice first
    try std.testing.expectEqual(@as(f64, 30), values[1].number); // John second

    // Update John's age to 20 (should move him before Alice)
    _ = try collection.updateOne(io, john._id, try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "age",
            .value = .{ .number = 20 },
        },
    }), .{});

    values = try helpers.sortIndexValues(allocator, io, ageIndex);
    try std.testing.expectEqual(@as(f64, 20), values[0].number); // John first now
    try std.testing.expectEqual(@as(f64, 25), values[1].number); // Alice second now
}

test "should update sort index when record is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const john = try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "John Doe", 30, "user");
    const alice = try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "Alice Smith", 25, "admin");
    try collection.setInternalRecord(io, john);
    try collection.setInternalRecord(io, alice);

    const ageIndex = try collection.sortIndex("age", .asc);
    try ageIndex.ensure(io, collection, .number);
    try std.testing.expectEqual(@as(u32, 2), ageIndex.totalEntries);

    // Delete Alice
    _ = try collection.deleteOne(io, alice._id);

    const values = try helpers.sortIndexValues(allocator, io, ageIndex);
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqual(@as(u32, 1), ageIndex.totalEntries);
    try std.testing.expectEqual(@as(f64, 30), values[0].number); // Only John remains
}

test "should set an internal record preserving metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const nameMetadata = try BsonDocument.fromFields(allocator, &.{.{ .key = "timestamp", .value = .{ .number = 999 } }});
    const fieldsMetadata = try BsonDocument.fromFields(allocator, &.{.{ .key = "name", .value = .{ .document = nameMetadata } }});
    const internalRecord: IInternalRecord = .{
        ._id = "123e4567-e89b-12d3-a456-426614174000",
        .fields = try BsonDocument.fromFields(allocator, &.{
            .{ .key = "name", .value = .{ .string = "Sync User" } },
            .{ .key = "age", .value = .{ .number = 42 } },
        }),
        .metadata = try BsonDocument.fromFields(allocator, &.{
            .{ .key = "timestamp", .value = .{ .number = 1000000 } },
            .{ .key = "fields", .value = .{ .document = fieldsMetadata } },
        }),
    };

    try collection.setInternalRecord(io, internalRecord);
    try collection.commit(io);

    // Reload from storage with a fresh collection: the metadata survives exactly.
    const reloaded = try newCollection(allocator, &storage);
    const retrieved = (try getRecord(reloaded, internalRecord._id)).?;
    try std.testing.expectEqualStrings("Sync User", retrieved.fields.get("name").?.string);
    try std.testing.expectEqual(@as(f64, 42), retrieved.fields.get("age").?.number);
    try std.testing.expect(retrieved.metadata.eql(internalRecord.metadata));
}

test "setInternalRecord should upsert (update existing record)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const id = "123e4567-e89b-12d3-a456-426614174000";
    try collection.setInternalRecord(io, try makeUser(allocator, id, "Original", 20, "user"));
    try collection.setInternalRecord(io, try makeUser(allocator, id, "Updated", 21, "admin"));

    const retrieved = (try getRecord(collection, id)).?;
    try std.testing.expectEqualStrings("Updated", retrieved.fields.get("name").?.string);
    try std.testing.expectEqual(@as(f64, 21), retrieved.fields.get("age").?.number);
}

test "getSorted should return empty when sort index does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    const result = try (try collection.sortIndex("age", .asc)).getPage(io, null);
    try std.testing.expectEqual(@as(usize, 0), result.records.len);
    try std.testing.expectEqual(@as(u32, 0), result.totalRecords);
}

test "findByIndex should return empty when no index exists on either direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    const result = try (try collection.sortIndex("role", .asc)).findByValue(io, .{ .string = "user" }, null);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "getShardId should return consistent shard IDs for the same record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    const id = "123e4567-e89b-12d3-a456-426614174000";
    const shardId1 = try collection.getShardId(id);
    const shardId2 = try collection.getShardId(id);
    try std.testing.expectEqualStrings(shardId1, shardId2);
    const shardNumber = try std.fmt.parseInt(u32, shardId1, 10);
    try std.testing.expect(shardNumber < 100);
}

test "getShardId matches the shard files of the test databases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", "db");
    const collection = try allocator.create(BsonCollection);
    collection.* = BsonCollection.init(allocator, "metadata", "db", storage.asStorage(), "db", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider(), .{ .context = &storage, .function = onDirty });
    var checked: usize = 0;
    var shards = collection.iterateShards();
    var shardIdsSeen: std.ArrayList([]const u8) = .empty;
    for (collection.shardCache.keys()) |key| {
        _ = key;
    }
    while (try shards.next(io)) |shardRecords| {
        for (shardRecords) |record| {
            const shardId = try collection.getShardId(record._id);
            const shardPath = try std.fmt.allocPrint(allocator, "db/collections/metadata/shards/{s}", .{shardId});
            try std.testing.expect(storage.getFile(shardPath) != null);
            const shard = try collection.shard(shardId);
            try std.testing.expect((try shard.record(io, record._id)) != null);
            try shardIdsSeen.append(allocator, shardId);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 50), checked);
}

test "getShardId should throw for an invalid record ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    try std.testing.expectError(error.Thrown, collection.getShardId("not-a-valid-uuid"));
    try std.testing.expectEqualStrings("Invalid record ID not-a-valid-uuid with length 0", errors.lastErrorMessage());
}

test "iterateShards should only yield non-empty shards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    try collection.setInternalRecord(io, try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "A", 10, "user"));
    try collection.setInternalRecord(io, try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "B", 20, "user"));

    var totalRecords: usize = 0;
    var shards = collection.iterateShards();
    while (try shards.next(io)) |shardRecords| {
        try std.testing.expect(shardRecords.len > 0);
        totalRecords += shardRecords.len;
    }
    try std.testing.expectEqual(@as(usize, 2), totalRecords);
}

test "commit should flush dirty state and allow flush to succeed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const notificationsBefore = dirty_notifications;
    try collection.setInternalRecord(io, try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "Committed", 30, "user"));
    try std.testing.expect(collection.dirty());
    try std.testing.expectEqual(notificationsBefore + 1, dirty_notifications);

    try collection.commit(io);
    try std.testing.expect(!collection.dirty());

    // flush should succeed after commit
    try collection.flush();

    // The commit wrote the shard, its merkle tree and the collection merkle tree.
    const shardId = try collection.getShardId("123e4567-e89b-12d3-a456-426614174000");
    try std.testing.expect(storage.getFile(try std.fmt.allocPrint(allocator, "collections/users/shards/{s}", .{shardId})) != null);
    try std.testing.expect(storage.getFile(try std.fmt.allocPrint(allocator, "collections/users/shards/{s}.dat", .{shardId})) != null);
    try std.testing.expect(storage.getFile("collections/users/collection.dat") != null);
}

test "merkleTree should return a usable IMerkleRef" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    const merkleRef = try collection.merkleTree();
    // A fresh uncommitted collection has no persisted tree yet
    try std.testing.expect((try merkleRef.get(io)) == null);
    try std.testing.expectEqual(merkleRef, try collection.merkleTree());
}

test "sortIndex load should populate the sort index cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    try collection.setInternalRecord(io, try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "A", 10, "user"));
    try collection.setInternalRecord(io, try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "B", 20, "user"));
    try (try collection.sortIndex("age", .asc)).ensure(io, collection, .number);

    // load on a non-existent index should be a no-op (no throw)
    try std.testing.expect(!try (try collection.sortIndex("name", .asc)).load(io));

    // load on an existing index should succeed
    try std.testing.expect(try (try collection.sortIndex("age", .asc)).load(io));
    try std.testing.expectEqual(try collection.sortIndex("age", .asc), try collection.sortIndex("age", .asc));
}

test "shard should return the same cached instance for the same shardId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const collection = try newCollection(arena.allocator(), &storage);
    try std.testing.expectEqual(try collection.shard("0"), try collection.shard("0"));
}

test "deleteOne removes the record from every sort index and the merkle trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    try (try collection.sortIndex("age", .asc)).ensure(io, collection, .number);
    try (try collection.sortIndex("name", .desc)).ensure(io, collection, .string);
    const id = "123e4567-e89b-12d3-a456-426614174001";
    try collection.setInternalRecord(io, try makeUser(allocator, id, "A", 10, "user"));
    try collection.commit(io);
    try std.testing.expect(try collection.deleteOne(io, id));
    try collection.commit(io);
    try std.testing.expectEqual(@as(u32, 0), (try collection.sortIndex("age", .asc)).totalEntries);
    try std.testing.expectEqual(@as(u32, 0), (try collection.sortIndex("name", .desc)).totalEntries);
    try std.testing.expect(storage.getFile("collections/users/collection.dat") == null);
}

test "the shard cache is bounded, so walking a collection does not end up holding all of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // A shard holds every record in it, so an unbounded cache holds the whole collection once
    // enough of it has been touched. A sync's record merge visits every differing shard on both
    // sides: measured on a Pixel 6 against a database of 8,231 photos, that ran the embedded
    // engine out of memory and aborted the app three times.
    //
    // Asserted by identity rather than by reading a size: a shard that was dropped comes back as
    // a different instance, and one that was kept comes back as the same one.
    const first = try collection.shard("shard-0");

    var shardNumber: u32 = 1;
    while (shardNumber <= 32) : (shardNumber += 1) {
        _ = try collection.shard(try std.fmt.allocPrint(allocator, "shard-{d}", .{shardNumber}));
    }

    try std.testing.expect(try collection.shard("shard-0") != first);
    try std.testing.expectEqual(try collection.shard("shard-32"), try collection.shard("shard-32"));
}

test "a shard used recently survives while older ones are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    const kept = try collection.shard("shard-kept");

    var shardNumber: u32 = 0;
    while (shardNumber < 32) : (shardNumber += 1) {
        _ = try collection.shard(try std.fmt.allocPrint(allocator, "shard-{d}", .{shardNumber}));
        // Touched on every round, so it is never the least recently used one.
        _ = try collection.shard("shard-kept");
    }

    try std.testing.expectEqual(kept, try collection.shard("shard-kept"));
}

test "a shard with uncommitted writes is never dropped, because its records are the only copy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // Eviction frees records that can be read again from storage. A dirty shard's records cannot:
    // dropping one would silently lose the write.
    const user = try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 30, "user");
    // (Zig: insertOne is not ported; setInternalRecord inserts the record.)
    try collection.setInternalRecord(io, user);

    const dirtyShardId = try collection.getShardId(user._id);
    const dirtyShard = try collection.shard(dirtyShardId);

    var shardNumber: u32 = 0;
    while (shardNumber < 32) : (shardNumber += 1) {
        _ = try collection.shard(try std.fmt.allocPrint(allocator, "other-shard-{d}", .{shardNumber}));
    }

    try std.testing.expectEqual(dirtyShard, try collection.shard(dirtyShardId));
    const record = (try getRecord(collection, user._id)).?;
    try std.testing.expectEqualStrings("John Doe", record.fields.get("name").?.string);
}

test "iterateShards reads the shards a listing finds as well as the ones held in memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const writer = try newCollection(allocator, &storage);
    try writer.setInternalRecord(io, try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "A", 10, "user"));
    try writer.commit(io);

    // A fresh collection holds nothing in memory, so the committed record is found through the listing.
    const reader = try newCollection(allocator, &storage);
    try reader.setInternalRecord(io, try makeUser(allocator, "223e4567-e89b-12d3-a456-426614174002", "B", 20, "user"));

    var totalRecords: usize = 0;
    var shards = reader.iterateShards();
    while (try shards.next(io)) |shardRecords| {
        totalRecords += shardRecords.len;
    }
    try std.testing.expectEqual(@as(usize, 2), totalRecords);
}

//
// Builds a TestUser record in external form (TypeScript: the TestUser object literal).
//
fn makeExternalUser(allocator: std.mem.Allocator, id: []const u8, name: []const u8, age: f64, role: []const u8) !BsonDocument {
    return BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = id },
        },
        .{
            .key = "name",
            .value = .{ .string = name },
        },
        .{
            .key = "email",
            .value = .{ .string = try std.fmt.allocPrint(allocator, "{s}@example.com", .{name}) },
        },
        .{
            .key = "age",
            .value = .{ .number = age },
        },
        .{
            .key = "role",
            .value = .{ .string = role },
        },
    });
}

test "should insert and retrieve a record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var user = try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 30, "user");

    try collection.insertOne(io, &user, null);

    const retrieved = (try collection.getOne(io, "123e4567-e89b-12d3-a456-426614174000")).?;
    try std.testing.expect(retrieved.eql(user));
}

test "should generate an ID if not provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var user = try makeExternalUser(allocator, "", "Jane Doe", 25, "admin"); // Empty ID will be replaced

    try collection.insertOne(io, &user, null);

    // Get all records to find the one we inserted
    const result = try collection.getAll(io, null);
    try std.testing.expectEqual(@as(usize, 1), result.records.len);

    const retrieved = result.records[0];
    try std.testing.expectEqualStrings("Jane Doe", retrieved.get("name").?.string);
    try std.testing.expect(retrieved.get("_id").?.string.len > 0); // ID should have been generated
    try std.testing.expectEqual(@as(usize, 36), retrieved.get("_id").?.string.len); // UUID format
}

test "should update a record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var user = try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 30, "user");

    try collection.insertOne(io, &user, null);

    const updates = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "age",
            .value = .{ .number = 31 },
        },
        .{
            .key = "role",
            .value = .{ .string = "admin" },
        },
    });

    const updateResult = try collection.updateOne(io, "123e4567-e89b-12d3-a456-426614174000", updates, .{});
    try std.testing.expect(updateResult);

    const updated = (try collection.getOne(io, "123e4567-e89b-12d3-a456-426614174000")).?;
    try std.testing.expect(updated.eql(try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 31, "admin")));
}

test "should return false when updating non-existent record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const nonExistentId = "123e4567-e89b-12d3-a456-000000000000";
    const updates = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "name",
            .value = .{ .string = "New Name" },
        },
    });

    const updateResult = try collection.updateOne(io, nonExistentId, updates, .{});
    try std.testing.expect(!updateResult);
}

test "should upsert a record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    const id = "123e4567-e89b-12d3-a456-426614174001";
    const updates = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "name",
            .value = .{ .string = "Upserted User" },
        },
        .{
            .key = "email",
            .value = .{ .string = "upsert@example.com" },
        },
        .{
            .key = "age",
            .value = .{ .number = 40 },
        },
        .{
            .key = "role",
            .value = .{ .string = "guest" },
        },
    });

    const updateResult = try collection.updateOne(io, id, updates, .{ .upsert = true });
    try std.testing.expect(updateResult);

    const upserted = (try collection.getOne(io, id)).?;
    var expected = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = id },
        },
    });
    for (updates.fields.items) |updateField| {
        try expected.put(allocator, updateField.key, updateField.value);
    }
    try std.testing.expect(upserted.eql(expected));
}

test "should paginate through records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var users = [_]BsonDocument{
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "User 1", 30, "user"),
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "User 2", 35, "admin"),
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174003", "User 3", 25, "user"),
    };

    // Insert all users
    for (&users) |*user| {
        try collection.insertOne(io, user, null);
    }

    // Get first page
    var result = try collection.getAll(io, null);
    try std.testing.expect(result.records.len > 0);
    try std.testing.expect(result.next != null);

    var allUsers: std.ArrayList(BsonDocument) = .empty;
    try allUsers.appendSlice(allocator, result.records);

    // Continue pagination if there are more pages
    while (result.next) |next| {
        result = try collection.getAll(io, next);
        try allUsers.appendSlice(allocator, result.records);
    }

    // Check that all users were retrieved
    try std.testing.expectEqual(users.len, allUsers.items.len);

    // Check that each user was retrieved
    for (users) |user| {
        var found = false;
        for (allUsers.items) |retrieved| {
            if (std.mem.eql(u8, retrieved.get("_id").?.string, user.get("_id").?.string)) {
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

//
// The users of the TypeScript sort index tests.
//
fn sortIndexTestUsers(allocator: std.mem.Allocator) ![3]BsonDocument {
    return .{
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "John Doe", 30, "user"),
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "Alice Smith", 25, "admin"),
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174003", "Bob Johnson", 35, "user"),
    };
}

test "should create and use a sort index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var users = try sortIndexTestUsers(allocator);

    // Insert all users
    for (&users) |*user| {
        try collection.insertOne(io, user, null);
    }

    // Create an index on the age field
    try (try collection.sortIndex("age", .asc)).ensure(io, collection, .number);

    // Get sorted records
    const result = try (try collection.sortIndex("age", .asc)).getPage(io, null);

    // Check that the records are sorted by age
    try std.testing.expectEqual(users.len, result.records.len);
    try std.testing.expectEqual(@as(f64, 25), result.records[0].get("age").?.number); // Alice
    try std.testing.expectEqual(@as(f64, 30), result.records[1].get("age").?.number); // John
    try std.testing.expectEqual(@as(f64, 35), result.records[2].get("age").?.number); // Bob
}

test "should find records by index value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var users = [_]BsonDocument{
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "User 1", 30, "user"),
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174002", "User 2", 35, "admin"),
        try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174003", "User 3", 30, "user"),
    };

    // Insert all users
    for (&users) |*user| {
        try collection.insertOne(io, user, null);
    }

    // Create an index on the role field
    try (try collection.sortIndex("role", .asc)).ensure(io, collection, .string);

    // Find users with role 'user'
    const userRoleResults = try (try collection.sortIndex("role", .asc)).findByValue(io, .{ .string = "user" }, null);
    try std.testing.expectEqual(@as(usize, 2), userRoleResults.len);
    for (userRoleResults) |userRoleResult| {
        try std.testing.expectEqualStrings("user", userRoleResult.get("role").?.string);
    }

    // Find users with role 'admin'
    const adminRoleResults = try (try collection.sortIndex("role", .asc)).findByValue(io, .{ .string = "admin" }, null);
    try std.testing.expectEqual(@as(usize, 1), adminRoleResults.len);
    try std.testing.expectEqualStrings("admin", adminRoleResults[0].get("role").?.string);

    // Create an index on the age field
    try (try collection.sortIndex("age", .asc)).ensure(io, collection, .number);

    // Find users with age 30
    const age30Results = try (try collection.sortIndex("age", .asc)).findByValue(io, .{ .number = 30 }, null);
    try std.testing.expectEqual(@as(usize, 2), age30Results.len);
    for (age30Results) |age30Result| {
        try std.testing.expectEqual(@as(f64, 30), age30Result.get("age").?.number);
    }
}

test "should support pagination with sort indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var users = try sortIndexTestUsers(allocator);

    // Insert users
    for (&users) |*user| {
        try collection.insertOne(io, user, null);
    }

    // Create an index on age
    try (try collection.sortIndex("age", .asc)).ensure(io, collection, .number);

    // Get first page
    var result = try (try collection.sortIndex("age", .asc)).getPage(io, null);
    try std.testing.expect(result.records.len > 0);
    try std.testing.expectEqual(@as(u32, 3), result.totalRecords);
    try std.testing.expect(result.totalPages > 0);

    // Collect all records across pages
    var allRecords: std.ArrayList(BsonDocument) = .empty;
    try allRecords.appendSlice(allocator, result.records);
    var currentPageId = result.nextPageId;

    while (currentPageId) |pageId| {
        result = try (try collection.sortIndex("age", .asc)).getPage(io, pageId);
        try allRecords.appendSlice(allocator, result.records);
        currentPageId = result.nextPageId;
    }

    // Verify we got all records
    try std.testing.expectEqual(@as(usize, 3), allRecords.items.len);

    // Verify they're sorted correctly
    try std.testing.expectEqual(@as(f64, 25), allRecords.items[0].get("age").?.number); // Alice
    try std.testing.expectEqual(@as(f64, 30), allRecords.items[1].get("age").?.number); // John
    try std.testing.expectEqual(@as(f64, 35), allRecords.items[2].get("age").?.number); // Bob
}

test "should support descending order with sort indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var users = try sortIndexTestUsers(allocator);

    // Insert users
    for (&users) |*user| {
        try collection.insertOne(io, user, null);
    }

    // Create a descending index on age
    try (try collection.sortIndex("age", .desc)).ensure(io, collection, .number);

    // Get sorted records in descending order
    const result = try (try collection.sortIndex("age", .desc)).getPage(io, null);

    // Verify records are sorted in descending order
    try std.testing.expectEqual(users.len, result.records.len);
    try std.testing.expectEqual(@as(f64, 35), result.records[0].get("age").?.number); // Bob first
    try std.testing.expectEqual(@as(f64, 30), result.records[1].get("age").?.number); // John second
    try std.testing.expectEqual(@as(f64, 25), result.records[2].get("age").?.number); // Alice last
}

test "should throw when inserting a record with a duplicate ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var user = try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 30, "user");

    try collection.insertOne(io, &user, null);

    try std.testing.expectError(error.Thrown, collection.insertOne(io, &user, null));
}

test "flush should throw when collection is dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var user = try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "Dirty", 30, "user");

    try collection.insertOne(io, &user, null);

    // flush without commit should throw because the collection is dirty
    try std.testing.expectError(error.Thrown, collection.flush());
}

//
// insertOne stores the record's fields apart from its id and stamps the time it was written, as
// toInternal does. (No TypeScript counterpart: TypeScript tests read the record back through getOne.)
//
test "insertOne stores the fields apart from the id and stamps the write time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);
    var user = try makeExternalUser(allocator, "123e4567-e89b-12d3-a456-426614174000", "John Doe", 30, "user");

    try collection.insertOne(io, &user, 1234);

    const stored = (try getRecord(collection, "123e4567-e89b-12d3-a456-426614174000")).?;
    try std.testing.expect(stored.fields.get("_id") == null);
    try std.testing.expectEqualStrings("name", stored.fields.fields.items[0].key);
    try std.testing.expectEqual(@as(f64, 1234), stored.metadata.get("timestamp").?.number);
}

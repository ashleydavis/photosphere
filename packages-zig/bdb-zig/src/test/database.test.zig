const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonDatabase = bdb.database.BsonDatabase;
const IInternalRecord = bdb.shard.IInternalRecord;

const io = std.testing.io;

//
// Valid UUID v4 strings for use as record IDs in tests.
//
const ID1 = "11111111-1111-4111-a111-111111111111";

//
// A second record id.
//
const ID2 = "22222222-2222-4222-a222-222222222222";

//
// Generates tree ids.
//
var test_uuid_generator: utils.test_uuid_generator.TestUuidGenerator = .{};

//
// Creates the database under test (TypeScript: the beforeEach block).
//
fn newDatabase(allocator: std.mem.Allocator, storage: *MemoryStorage) !*BsonDatabase {
    return BsonDatabase.init(allocator, storage.asStorage(), "", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
}

//
// Builds a record with one string field.
//
fn makeRecord(allocator: std.mem.Allocator, id: []const u8, key: []const u8, value: []const u8) !IInternalRecord {
    return .{
        ._id = id,
        .fields = try BsonDocument.fromFields(allocator, &.{.{ .key = key, .value = .{ .string = value } }}),
        .metadata = .empty,
    };
}

test "should create a new collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    const collection = try database.collection("users");
    try std.testing.expectEqualStrings("users", collection.name);
}

test "should return the same collection instance for the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    try std.testing.expectEqual(try database.collection("users"), try database.collection("users"));
}

test "should return different collection instances for different names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    try std.testing.expect(try database.collection("users") != try database.collection("products"));
}

//
// Returns true when the list holds the name (TypeScript: `expect(list).toContain(name)`).
//
fn containsName(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) {
            return true;
        }
    }
    return false;
}

test "should list collections created in memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    _ = try database.collection("users");
    _ = try database.collection("products");
    _ = try database.collection("orders");

    const collections = try database.collections(io);

    try std.testing.expect(containsName(collections, "users"));
    try std.testing.expect(containsName(collections, "products"));
    try std.testing.expect(containsName(collections, "orders"));
}

test "should list collections from storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    try storage.write(arena.allocator(), io, "collections/metadata/shards/0", null, "test");

    const collections = try database.collections(io);

    try std.testing.expect(containsName(collections, "metadata"));
}

test "should merge in-memory and storage collections without duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    _ = try database.collection("users");
    try storage.write(arena.allocator(), io, "collections/users/shards/0", null, "test");
    try storage.write(arena.allocator(), io, "collections/photos/shards/0", null, "test");

    const collections = try database.collections(io);

    var userEntries: usize = 0;
    for (collections) |name| {
        if (std.mem.eql(u8, name, "users")) {
            userEntries += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), userEntries);
    try std.testing.expect(containsName(collections, "photos"));
}

test "should return empty array when no collections exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);

    const collections = try database.collections(io);

    try std.testing.expectEqual(@as(usize, 0), collections.len);
}

test "commit should be a no-op when not dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    try database.commit(io);
    try std.testing.expectEqual(@as(usize, 0), storage.files.count());
}

test "commit clears dirty flag so a second commit is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    try users.setInternalRecord(io, try makeRecord(allocator, ID1, "name", "Alice"));
    try std.testing.expect(database.dirty);

    try database.commit(io);
    try std.testing.expect(!database.dirty);
    const databaseTree = storage.getFile("db.dat").?;

    // Second commit should not throw and should be a no-op
    try database.commit(io);
    try std.testing.expectEqual(databaseTree.ptr, storage.getFile("db.dat").?.ptr);
}

test "commit processes multiple collections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    const products = try database.collection("products");
    try users.setInternalRecord(io, try makeRecord(allocator, ID1, "name", "Alice"));
    try products.setInternalRecord(io, try makeRecord(allocator, ID2, "title", "Widget"));

    try database.commit(io);
    try std.testing.expect(!users.dirty());
    try std.testing.expect(!products.dirty());
    try std.testing.expect(storage.getFile("collections/users/collection.dat") != null);
    try std.testing.expect(storage.getFile("collections/products/collection.dat") != null);
    const databaseTree = (try (try database.merkleTree()).get(io)).?;
    try std.testing.expectEqual(@as(u32, 2), databaseTree.sort.?.leafCount);
}

test "merkleTree should return the same instance on repeated calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    try std.testing.expectEqual(try database.merkleTree(), try database.merkleTree());
}

test "merkleTree get should return undefined for an empty database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    try std.testing.expect((try (try database.merkleTree()).get(io)) == null);
}

test "commit removes a collection from the database tree when its last record is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    try users.setInternalRecord(io, try makeRecord(allocator, ID1, "name", "Alice"));
    try database.commit(io);
    try std.testing.expect(storage.getFile("db.dat") != null);

    _ = try users.deleteOne(io, ID1);
    try database.commit(io);
    try std.testing.expect(storage.getFile("db.dat") == null);
    try std.testing.expect(storage.getFile("collections/users/collection.dat") == null);
}

test "a database committed by Zig has the root hash TypeScript computes for the same records" {
    // The 50-assets test database was written by TypeScript. Re-setting every record into an empty database gives
    // the same collection root hash, because merkle hashes only depend on the record hashes.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source = MemoryStorage.init(allocator);
    try source.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", ".db/bson");
    var destination = MemoryStorage.init(allocator);
    const sourceDatabase = try BsonDatabase.init(allocator, source.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
    const destinationDatabase = try BsonDatabase.init(allocator, destination.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
    const sourceCollection = try sourceDatabase.collection("metadata");
    const destinationCollection = try destinationDatabase.collection("metadata");
    var iterator = sourceCollection.iterateRecords();
    while (try iterator.next(io)) |record| {
        try destinationCollection.setInternalRecord(io, record);

        // Committed after every record: the collection keeps at most 8 shards cached and drops a newly created
        // shard straight away when the other 8 are dirty, which would lose its record (as in TypeScript).
        try destinationDatabase.commit(io);
    }

    const sourceTree = (try bdb.merkle_tree.loadDatabaseMerkleTree(allocator, io, source.asStorage(), ".db/bson")).?;
    const destinationTree = (try bdb.merkle_tree.loadDatabaseMerkleTree(allocator, io, destination.asStorage(), ".db/bson")).?;
    try std.testing.expectEqualSlices(u8, sourceTree.merkle.?.hash, destinationTree.merkle.?.hash);
}

//
// Builds an external record with one string field (TypeScript: the `{ _id, name }` literal).
//
fn makeExternalRecord(allocator: std.mem.Allocator, id: []const u8, key: []const u8, value: []const u8) !BsonDocument {
    var record: BsonDocument = .empty;
    try record.put(allocator, "_id", .{ .string = id });
    try record.put(allocator, key, .{ .string = value });
    return record;
}

test "commit should allow flush after completing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    var alice = try makeExternalRecord(allocator, ID1, "name", "Alice");
    try users.insertOne(io, &alice, null);

    try database.commit(io);

    // After commit, flush should succeed (dirty flag cleared)
    try database.flush();
}

test "flush should throw when database is dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    var alice = try makeExternalRecord(allocator, ID1, "name", "Alice");
    try users.insertOne(io, &alice, null);

    try std.testing.expectError(error.Thrown, database.flush());
}

test "flush should succeed when database is not dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);

    // Never modified: flush should not throw
    try database.flush();
}

test "flush should succeed after commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    var alice = try makeExternalRecord(allocator, ID1, "name", "Alice");
    try users.insertOne(io, &alice, null);

    try database.commit(io);
    try database.flush();
}

test "flush evicts collection internal state but keeps the collection object cached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const database = try newDatabase(allocator, &storage);
    const users = try database.collection("users");
    var alice = try makeExternalRecord(allocator, ID1, "name", "Alice");
    try users.insertOne(io, &alice, null);
    try database.commit(io);

    try database.flush();

    // The collection's shards were dropped.
    try std.testing.expectEqual(@as(usize, 0), users.shardCache.count());

    // The same collection instance is returned (collection objects stay cached)
    const users2 = try database.collection("users");
    try std.testing.expectEqual(users, users2);
}

test "merkleTree should return a new instance after flush" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    const database = try newDatabase(arena.allocator(), &storage);
    const ref1 = try database.merkleTree();

    // Must commit before flushing (even though nothing is dirty)
    try database.flush();
    const ref2 = try database.merkleTree();
    try std.testing.expect(ref2 != ref1);
}

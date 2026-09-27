const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const merkle_tree = bdb.merkle_tree;
const IInternalRecord = bdb.shard.IInternalRecord;

const io = std.testing.io;

//
// Generates tree ids.
//
var test_uuid_generator: utils.test_uuid_generator.TestUuidGenerator = .{};

test "hashRecord matches TypeScript for the synthetic records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.readJsonFixture(allocator, io, "hash-records.json");
    const decoder = std.base64.standard.Decoder;
    for (fixture.object.get("synthetic").?.array.items) |item| {
        const encoded = item.object.get("bson").?.string;
        const bsonBytes = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
        try decoder.decode(bsonBytes, encoded);
        const fields = try bson.deserialize(allocator, bsonBytes);
        const hashedItem = try merkle_tree.hashRecord(allocator, io, "00000000-0000-4000-8000-000000000000", fields);
        const hashHex = std.fmt.bytesToHex(hashedItem.hash[0..32].*, .lower);
        std.testing.expectEqualStrings(item.object.get("hash").?.string, &hashHex) catch |err| {
            std.debug.print("synthetic record: {s}\n", .{item.object.get("name").?.string});
            return err;
        };
        try std.testing.expectEqual(@as(u64, @intCast(item.object.get("length").?.integer)), hashedItem.length);
        try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", hashedItem.name);
    }
}

test "hashRecord matches the hashes TypeScript stored for every test database record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.readJsonFixture(allocator, io, "hash-records.json");
    var currentDatabase: []const u8 = "";
    var records: std.StringHashMapUnmanaged(IInternalRecord) = .empty;
    for (fixture.object.get("real").?.array.items) |item| {
        const databaseName = item.object.get("database").?.string;
        if (!std.mem.eql(u8, databaseName, currentDatabase)) {
            currentDatabase = databaseName;
            records = .empty;
            const storage = try allocator.create(MemoryStorage);
            storage.* = MemoryStorage.init(allocator);
            try storage.loadDirectory(io, try std.fmt.allocPrint(allocator, "{s}/{s}/.db/bson", .{ helpers.TEST_DBS_DIR, databaseName }), ".db/bson");
            const database = try bdb.database.BsonDatabase.init(allocator, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
            const collection = try database.collection("metadata");
            var iterator = collection.iterateRecords();
            while (try iterator.next(io)) |record| {
                try records.put(allocator, record._id, record);
            }
        }
        const record = records.get(item.object.get("id").?.string).?;
        const hashedItem = try merkle_tree.hashRecord(allocator, io, record._id, record.fields);
        const hashHex = std.fmt.bytesToHex(hashedItem.hash[0..32].*, .lower);
        try std.testing.expectEqualStrings(item.object.get("hash").?.string, &hashHex);
        try std.testing.expectEqual(@as(u64, @intCast(item.object.get("length").?.integer)), hashedItem.length);
    }
}

test "buildShardMerkleTree adds a leaf per record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const records = [_]IInternalRecord{
        .{ ._id = "123e4567-e89b-12d3-a456-426614174000", .fields = try bson.BsonDocument.fromFields(allocator, &.{.{ .key = "a", .value = .{ .number = 1 } }}), .metadata = .empty },
        .{ ._id = "aabbccdd-1122-3344-5566-778899aabbcc", .fields = try bson.BsonDocument.fromFields(allocator, &.{.{ .key = "a", .value = .{ .number = 2 } }}), .metadata = .empty },
    };
    const tree = try merkle_tree.buildShardMerkleTree(allocator, io, &records, test_uuid_generator.uuidGenerator());
    try std.testing.expectEqual(@as(u32, 2), tree.sort.?.leafCount);
    try std.testing.expect(tree.dirty);
    const empty = try merkle_tree.buildShardMerkleTree(allocator, io, &.{}, test_uuid_generator.uuidGenerator());
    try std.testing.expect(empty.sort == null);
}

test "shard, collection and database merkle trees save, load and delete at the v6 paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const records = [_]IInternalRecord{
        .{ ._id = "123e4567-e89b-12d3-a456-426614174000", .fields = try bson.BsonDocument.fromFields(allocator, &.{.{ .key = "a", .value = .{ .number = 1 } }}), .metadata = .empty },
    };
    var tree = try merkle_tree.buildShardMerkleTree(allocator, io, &records, test_uuid_generator.uuidGenerator());

    try merkle_tree.saveShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", "7", &tree);
    try std.testing.expect(!tree.dirty);
    try std.testing.expect(storage.getFile(".db/bson/collections/metadata/shards/7.dat") != null);
    const loadedShardTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", "7")).?;
    try std.testing.expectEqualSlices(u8, tree.merkle.?.hash, loadedShardTree.merkle.?.hash);
    try merkle_tree.deleteShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", "7");
    try std.testing.expect((try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", "7")) == null);

    try merkle_tree.saveCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", &tree);
    try std.testing.expect(storage.getFile(".db/bson/collections/metadata/collection.dat") != null);
    try std.testing.expect((try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")) != null);
    try merkle_tree.deleteCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata");
    try std.testing.expect((try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")) == null);

    try merkle_tree.saveDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", &tree);
    const databaseFile = storage.getFile(".db/bson/db.dat").?;
    try std.testing.expectEqualStrings("BDBT", databaseFile[4..8]);
    try std.testing.expect((try merkle_tree.loadDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson")) != null);
    try merkle_tree.deleteDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson");
    try std.testing.expect((try merkle_tree.loadDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson")) == null);
}

test "loadDatabaseMerkleTree loads the tree TypeScript wrote for the v6 test database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/v6/.db/bson", ".db/bson");
    const databaseTree = (try merkle_tree.loadDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson")).?;
    const collectionTree = (try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")).?;
    const shardTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", "96")).?;
    try std.testing.expectEqual(@as(u32, 1), databaseTree.sort.?.leafCount);
    try std.testing.expectEqualSlices(u8, collectionTree.merkle.?.hash, databaseTree.sort.?.contentHash.?);
    try std.testing.expectEqualSlices(u8, shardTree.merkle.?.hash, collectionTree.sort.?.contentHash.?);
}

test "getDatabaseRootHash returns the root hash of the database merkle tree, or undefined when there is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect((try merkle_tree.getDatabaseRootHash(allocator, io, storage.asStorage(), ".db/bson")) == null);

    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/v6/.db/bson", ".db/bson");
    const databaseTree = (try merkle_tree.loadDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson")).?;
    const rootHash = (try merkle_tree.getDatabaseRootHash(allocator, io, storage.asStorage(), ".db/bson")).?;
    try std.testing.expectEqualSlices(u8, databaseTree.merkle.?.hash, rootHash);
}

//
// The state of a merkle tree update test (TypeScript: the describe block variables set in beforeEach of
// merkle-tree-update.test.ts).
//
const UpdateFixture = struct {
    // The storage the database writes to.
    storage: *MemoryStorage,

    // The database under test.
    database: *bdb.database.BsonDatabase,

    // The "test" collection of the database.
    collection: *bdb.collection.BsonCollection,
};

//
// Creates the database and collection of a merkle tree update test (TypeScript: the beforeEach block).
//
fn newUpdateFixture(allocator: std.mem.Allocator) !UpdateFixture {
    const storage = try allocator.create(MemoryStorage);
    storage.* = MemoryStorage.init(allocator);
    const database = try bdb.database.BsonDatabase.init(allocator, storage.asStorage(), "", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
    return .{
        .storage = storage,
        .database = database,
        .collection = try database.collection("test"),
    };
}

//
// Builds the `{ _id, name, age }` record the merkle tree update tests insert.
//
fn makePerson(allocator: std.mem.Allocator, recordId: []const u8, name: []const u8, age: f64) !bson.BsonDocument {
    var record: bson.BsonDocument = .empty;
    try record.put(allocator, "_id", .{ .string = recordId });
    try record.put(allocator, "name", .{ .string = name });
    try record.put(allocator, "age", .{ .number = age });
    return record;
}

test "insertOne should update shard, collection, and database merkle trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try newUpdateFixture(allocator);
    const recordId = try test_uuid_generator.uuidGenerator().generate(allocator, io);
    var record = try makePerson(allocator, recordId, "John", 30);
    try fixture.collection.insertOne(io, &record, null);
    try fixture.database.commit(io);

    // Determine which shard the record went to (v6: collection dir = collections/test)
    const shardIds = try merkle_tree.listShards(allocator, io, fixture.storage.asStorage(), "", "test");
    try std.testing.expect(shardIds.len > 0);
    const shardId = shardIds[0];

    // Check shard merkle tree exists
    const shardTree = try merkle_tree.loadShardMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test", shardId);
    try std.testing.expect(shardTree != null);
    try std.testing.expect(shardTree.?.merkle != null);
    try std.testing.expect(shardTree.?.sort != null);

    // Check collection merkle tree exists
    const collectionTree = try merkle_tree.loadCollectionMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test");
    try std.testing.expect(collectionTree != null);
    try std.testing.expect(collectionTree.?.merkle != null);

    // Check database merkle tree exists
    const databaseTree = try merkle_tree.loadDatabaseMerkleTree(allocator, io, fixture.storage.asStorage(), "");
    try std.testing.expect(databaseTree != null);
}

test "updateOne should update shard, collection, and database merkle trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try newUpdateFixture(allocator);
    const recordId = try test_uuid_generator.uuidGenerator().generate(allocator, io);

    // Insert initial record
    var record = try makePerson(allocator, recordId, "John", 30);
    try fixture.collection.insertOne(io, &record, null);
    try fixture.database.commit(io);

    // Determine which shard the record went to
    const shardIds = try merkle_tree.listShards(allocator, io, fixture.storage.asStorage(), "", "test");
    try std.testing.expect(shardIds.len > 0);
    const shardId = shardIds[0];

    // Get initial shard tree hash
    const initialShardTree = try merkle_tree.loadShardMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test", shardId);
    try std.testing.expect(initialShardTree != null);
    try std.testing.expect(initialShardTree.?.merkle != null);
    const initialShardHash = initialShardTree.?.merkle.?.hash;

    // Update the record
    var updates: bson.BsonDocument = .empty;
    try updates.put(allocator, "name", .{ .string = "Jane" });
    try updates.put(allocator, "age", .{ .number = 31 });
    _ = try fixture.collection.updateOne(io, recordId, updates, .{});
    try fixture.database.commit(io);

    // Get updated shard tree hash
    const updatedShardTree = try merkle_tree.loadShardMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test", shardId);
    try std.testing.expect(updatedShardTree != null);
    try std.testing.expect(updatedShardTree.?.merkle != null);
    const updatedShardHash = updatedShardTree.?.merkle.?.hash;

    // The shard tree hash should have changed
    try std.testing.expect(!std.mem.eql(u8, initialShardHash, updatedShardHash));

    // Collection tree should also be updated
    const collectionTree = try merkle_tree.loadCollectionMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test");
    try std.testing.expect(collectionTree != null);
    try std.testing.expect(collectionTree.?.merkle != null);
}

test "deleteOne should update shard, collection, and database merkle trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try newUpdateFixture(allocator);
    const recordId = try test_uuid_generator.uuidGenerator().generate(allocator, io);

    // Insert initial record
    var record = try makePerson(allocator, recordId, "John", 30);
    try fixture.collection.insertOne(io, &record, null);
    try fixture.database.commit(io);

    // Determine which shard the record went to
    const shardIds = try merkle_tree.listShards(allocator, io, fixture.storage.asStorage(), "", "test");
    try std.testing.expect(shardIds.len > 0);
    const shardId = shardIds[0];

    // Get initial shard tree
    const initialShardTree = try merkle_tree.loadShardMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test", shardId);
    try std.testing.expect(initialShardTree != null);
    try std.testing.expect(initialShardTree.?.sort != null);

    // Delete the record
    const deleted = try fixture.collection.deleteOne(io, recordId);
    try std.testing.expect(deleted);
    try fixture.database.commit(io);

    // Get updated shard tree
    const updatedShardTree = try merkle_tree.loadShardMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test", shardId);

    // After deleting the last record, the shard tree file is deleted (empty shards don't have tree files)
    try std.testing.expect(updatedShardTree == null);

    // Collection tree is also deleted when the collection becomes empty (no shards with records)
    const collectionTree = try merkle_tree.loadCollectionMerkleTree(allocator, io, fixture.storage.asStorage(), "", "test");
    try std.testing.expect(collectionTree == null);
}

test "getDatabaseMerkleTree matches persisted database merkle after commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try newUpdateFixture(allocator);
    const recordId = try test_uuid_generator.uuidGenerator().generate(allocator, io);
    var record = try makePerson(allocator, recordId, "John", 30);
    try fixture.collection.insertOne(io, &record, null);
    try fixture.database.commit(io);
    const memoryTree = try (try fixture.database.merkleTree()).get(io);
    const diskTree = try merkle_tree.loadDatabaseMerkleTree(allocator, io, fixture.storage.asStorage(), "");
    try std.testing.expect(memoryTree != null and memoryTree.?.merkle != null);
    try std.testing.expect(diskTree != null and diskTree.?.merkle != null);
    try std.testing.expectEqualSlices(u8, memoryTree.?.merkle.?.hash, diskTree.?.merkle.?.hash);
}

//
// Writes a shard file that holds no records (the version 2 shard format is a record count followed by the records).
//
fn writeEmptyShard(allocator: std.mem.Allocator, recordCount: u32, serializer: serialization_zig.serialization.ISerializer) anyerror!void {
    _ = allocator;
    try serializer.writeUInt32(recordCount);
}

//
// Returns the root hash of a tree, building the merkle tree first when the tree is dirty.
//
fn treeRootHash(allocator: std.mem.Allocator, tree: *const merkle_tree_zig.merkle_tree.IMerkleTree) ![]const u8 {
    if (tree.dirty) {
        return (try merkle_tree_zig.merkle_tree.buildMerkleTree(allocator, tree.sort)).?.hash;
    }
    return tree.merkle.?.hash;
}

test "listShards lists the shards of a collection in name order, skipping the merkle tree files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", ".db/bson");

    const shardIds = try merkle_tree.listShards(allocator, io, storage.asStorage(), ".db/bson", "metadata");
    try std.testing.expectEqual(@as(usize, 40), shardIds.len);
    var previousShardNumber: ?u32 = null;
    for (shardIds) |shardId| {
        // Numeric collation, so "2" comes before "13", and no ".dat" file is listed.
        const shardNumber = try std.fmt.parseInt(u32, shardId, 10);
        if (previousShardNumber) |previous| {
            try std.testing.expect(previous < shardNumber);
        }
        previousShardNumber = shardNumber;
    }

    try std.testing.expectEqual(@as(usize, 0), (try merkle_tree.listShards(allocator, io, storage.asStorage(), ".db/bson", "nonexistent")).len);
}

test "buildDatabaseMerkleTree with rebuild reproduces the merkle trees TypeScript wrote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", ".db/bson");
    const originalDatabaseHash = (try merkle_tree.getDatabaseRootHash(allocator, io, storage.asStorage(), ".db/bson")).?;
    const originalCollectionTree = (try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")).?;
    const shardIds = try merkle_tree.listShards(allocator, io, storage.asStorage(), ".db/bson", "metadata");
    const originalShardTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0])).?;

    // A rebuild writes every tree again, so the stale shard tree written here must be replaced.
    try merkle_tree.saveShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0], @constCast(&(try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[1])).?));

    const databaseTree = try merkle_tree.buildDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), null, null, true);
    try std.testing.expectEqual(@as(u32, 1), databaseTree.sort.?.leafCount);
    try std.testing.expectEqualSlices(u8, originalDatabaseHash, try treeRootHash(allocator, &databaseTree));

    const rebuiltCollectionTree = (try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")).?;
    try std.testing.expectEqual(@as(u32, 40), rebuiltCollectionTree.sort.?.leafCount);
    try std.testing.expectEqualSlices(u8, originalCollectionTree.merkle.?.hash, rebuiltCollectionTree.merkle.?.hash);
    const rebuiltShardTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0])).?;
    try std.testing.expectEqualSlices(u8, originalShardTree.merkle.?.hash, rebuiltShardTree.merkle.?.hash);
}

test "buildDatabaseMerkleTree without rebuild loads the saved trees and builds the missing ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", ".db/bson");
    const originalDatabaseHash = (try merkle_tree.getDatabaseRootHash(allocator, io, storage.asStorage(), ".db/bson")).?;
    const originalCollectionTree = (try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")).?;
    const shardIds = try merkle_tree.listShards(allocator, io, storage.asStorage(), ".db/bson", "metadata");
    const originalShardTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0])).?;

    // The collection tree and one shard tree are missing, so both are built and saved.
    try merkle_tree.deleteCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata");
    try merkle_tree.deleteShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0]);

    const databaseTree = try merkle_tree.buildDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), null, null, false);
    try std.testing.expectEqualSlices(u8, originalDatabaseHash, try treeRootHash(allocator, &databaseTree));
    const builtCollectionTree = (try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")).?;
    try std.testing.expectEqualSlices(u8, originalCollectionTree.merkle.?.hash, builtCollectionTree.merkle.?.hash);
    const builtShardTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0])).?;
    try std.testing.expectEqualSlices(u8, originalShardTree.merkle.?.hash, builtShardTree.merkle.?.hash);

    // A saved collection tree is used as it is, without reading the shards: a stale one gives a different root.
    try merkle_tree.saveCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", @constCast(&builtShardTree));
    const staleDatabaseTree = try merkle_tree.buildDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), null, null, false);
    try std.testing.expectEqualSlices(u8, builtShardTree.merkle.?.hash, staleDatabaseTree.sort.?.contentHash.?);
}

test "buildDatabaseMerkleTree uses the preloaded collection tree in place of the saved one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", ".db/bson");
    const shardIds = try merkle_tree.listShards(allocator, io, storage.asStorage(), ".db/bson", "metadata");
    const preloadedTree = (try merkle_tree.loadShardMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", shardIds[0])).?;
    const collectionFile = storage.getFile(".db/bson/collections/metadata/collection.dat").?;

    const databaseTree = try merkle_tree.buildDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), "metadata", preloadedTree, true);
    try std.testing.expectEqual(@as(u32, 1), databaseTree.sort.?.leafCount);
    try std.testing.expectEqualSlices(u8, preloadedTree.merkle.?.hash, databaseTree.sort.?.contentHash.?);
    // The preloaded collection is not rebuilt, so its saved tree is untouched.
    try std.testing.expectEqualSlices(u8, collectionFile, storage.getFile(".db/bson/collections/metadata/collection.dat").?);

    // A preloaded tree without a merkle tree adds nothing.
    const emptyTree = merkle_tree_zig.merkle_tree.createTree("empty");
    const emptyDatabaseTree = try merkle_tree.buildDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), "metadata", emptyTree, false);
    try std.testing.expect(emptyDatabaseTree.sort == null);
}

test "buildCollectionMerkleTree deletes the merkle tree of an empty shard and leaves the shard out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/v6/.db/bson", ".db/bson");
    const originalCollectionTree = (try merkle_tree.loadCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata")).?;
    try serialization_zig.serialization.save(allocator, io, storage.asStorage(), ".db/bson/collections/metadata/shards/5", @as(u32, 0), 2, "SHAR", writeEmptyShard);
    try storage.putFile(".db/bson/collections/metadata/shards/5.dat", storage.getFile(".db/bson/collections/metadata/shards/96.dat").?);

    for ([_]bool{ true, false }) |rebuild| {
        const collectionTree = try merkle_tree.buildCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", test_uuid_generator.uuidGenerator(), rebuild);
        try std.testing.expect(storage.getFile(".db/bson/collections/metadata/shards/5.dat") == null);
        try std.testing.expectEqual(@as(u32, 1), collectionTree.sort.?.leafCount);
        try std.testing.expectEqualSlices(u8, originalCollectionTree.merkle.?.hash, try treeRootHash(allocator, &collectionTree));
    }
}

test "buildDatabaseMerkleTree deletes the tree of a collection that has no records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]bool{ true, false }) |rebuild| {
        var storage = MemoryStorage.init(allocator);
        try serialization_zig.serialization.save(allocator, io, storage.asStorage(), ".db/bson/collections/metadata/shards/5", @as(u32, 0), 2, "SHAR", writeEmptyShard);
        if (rebuild) {
            // A rebuild replaces a saved collection tree, so a stale one is deleted.
            var staleTree = merkle_tree_zig.merkle_tree.createTree(try test_uuid_generator.uuidGenerator().generate(allocator, io));
            try merkle_tree.saveCollectionMerkleTree(allocator, io, storage.asStorage(), ".db/bson", "metadata", &staleTree);
        }

        const databaseTree = try merkle_tree.buildDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson", test_uuid_generator.uuidGenerator(), null, null, rebuild);
        try std.testing.expect(databaseTree.sort == null);
        try std.testing.expect(storage.getFile(".db/bson/collections/metadata/collection.dat") == null);
    }
}

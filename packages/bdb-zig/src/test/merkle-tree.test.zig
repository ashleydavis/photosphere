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

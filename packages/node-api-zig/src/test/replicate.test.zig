const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const replicate_module = node_api.replicate;
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;
const MerkleNode = merkle_tree.MerkleNode;
const HashedItem = merkle_tree.HashedItem;
const IMerkleTree = merkle_tree.IMerkleTree;
const IStorage = storage_zig.storage.IStorage;
const ICollectionRecord = replicate_module.ICollectionRecord;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// A valid uuid used as the id of the test trees.
//
const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

//
// sha256 of a seed string.
//
fn makeHash(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const digest = try allocator.create([32]u8);
    Sha256.hash(seed, digest, .{});
    return digest;
}

//
// Builds a tree with the given items and its merkle tree.
//
fn buildTree(allocator: std.mem.Allocator, uuid: []const u8, items: []const HashedItem) !IMerkleTree {
    var tree = merkle_tree.createTree(uuid);
    for (items) |item| {
        tree = try merkle_tree.addItem(allocator, &tree, item);
    }
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    return tree;
}

//
// Makes the items of a tree whose leaves are the given names (hash of the name, length 0).
//
fn makeItems(allocator: std.mem.Allocator, leafNames: []const []const u8) ![]HashedItem {
    const items = try allocator.alloc(HashedItem, leafNames.len);
    for (leafNames, 0..) |name, index| {
        items[index] = .{ .name = name, .hash = try makeHash(allocator, name), .length = 0, .lastModified = 1_700_000_000_000 };
    }
    return items;
}

//
// Builds a tree whose leaves are the given names and saves it.
//
fn buildAndSaveTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, filePath: []const u8, uuid: []const u8, leafNames: []const []const u8, typeCode: []const u8) !void {
    const tree = try buildTree(allocator, uuid, try makeItems(allocator, leafNames));
    try merkle_tree.saveTree(allocator, io, filePath, &tree, storage, typeCode);
}

//
// Saves a tree.
//
fn saveTree(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, tree: IMerkleTree, storage: IStorage, typeCode: []const u8) !void {
    try merkle_tree.saveTree(allocator, io, filePath, &tree, storage, typeCode);
}

//
// Collects the leaf names yielded by iterateLeaves.
//
fn collectLeaves(allocator: std.mem.Allocator, nodes: []const *MerkleNode) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = replicate_module.iterateLeaves(allocator, nodes);
    while (try iterator.next()) |name| {
        try names.append(allocator, name);
    }
    return names.items;
}

//
// Collects the records yielded by a difference iterator.
//
fn collectRecords(allocator: std.mem.Allocator, iterator: anytype) ![]ICollectionRecord {
    var records: std.ArrayList(ICollectionRecord) = .empty;
    while (try iterator.next()) |record| {
        try records.append(allocator, record);
    }
    return records.items;
}

//
// Gets the sorted record ids of a list of records.
//
fn sortedRecordIds(allocator: std.mem.Allocator, records: []const ICollectionRecord) ![][]const u8 {
    const ids = try allocator.alloc([]const u8, records.len);
    for (records, 0..) |record, index| {
        ids[index] = record.recordId;
    }
    helpers.sortStrings(ids);
    return ids;
}

//
// Checks that a list of strings is as expected.
//
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedString, actualString| {
        try std.testing.expectEqualStrings(expectedString, actualString);
    }
}

//
// Creates a merkle node.
//
fn makeNode(allocator: std.mem.Allocator, seed: []const u8, nodeCount: u32, name: ?[]const u8, left: ?*MerkleNode, right: ?*MerkleNode) !*MerkleNode {
    const node = try allocator.create(MerkleNode);
    node.* = .{ .hash = try makeHash(allocator, seed), .nodeCount = nodeCount, .name = name, .left = left, .right = right };
    return node;
}

//
// Two empty storages in temporary directories.
//
const StoragePair = struct {
    // The temporary directory holding both storages.
    dir: []const u8,

    // The first storage.
    storage1: IStorage,

    // The second storage.
    storage2: IStorage,
};

//
// Creates two empty storages.
//
fn makeStorages(allocator: std.mem.Allocator, io: std.Io) !StoragePair {
    const dir = try helpers.makeTempDir(allocator, io, "replicate-storages");
    return .{
        .dir = dir,
        .storage1 = try helpers.directoryStorage(allocator, io, try std.fmt.allocPrint(allocator, "{s}/one", .{dir})),
        .storage2 = try helpers.directoryStorage(allocator, io, try std.fmt.allocPrint(allocator, "{s}/two", .{dir})),
    };
}

//
// The path of a shard tree.
//
fn shardPath(allocator: std.mem.Allocator, collection: []const u8, shardId: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".db/bson/collections/{s}/shards/{s}.dat", .{ collection, shardId });
}

//
// The path of a collection tree.
//
fn collCollectionPath(allocator: std.mem.Allocator, collection: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".db/bson/collections/{s}/collection.dat", .{collection});
}

test "returns empty array for empty nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try collectLeaves(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "yields name of a single leaf node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf = try makeNode(allocator, "a", 1, "leaf1", null, null);
    try expectStrings(&.{"leaf1"}, try collectLeaves(allocator, &.{leaf}));
}

test "throws if leaf has no name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaf = try makeNode(allocator, "a", 1, null, null, null);
    try std.testing.expectError(error.Thrown, collectLeaves(allocator, &.{leaf}));
    try std.testing.expectEqualStrings("Leaf node has no name", errors.lastErrorMessage());
}

test "yields names from multiple leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaves = [_]*MerkleNode{ try makeNode(allocator, "a", 1, "a", null, null), try makeNode(allocator, "b", 1, "b", null, null) };
    try expectStrings(&.{ "a", "b" }, try collectLeaves(allocator, &leaves));
}

test "recurses into left child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const inner = try makeNode(allocator, "inner", 1, "inner", null, null);
    const root = try makeNode(allocator, "root", 2, null, inner, null);
    try expectStrings(&.{"inner"}, try collectLeaves(allocator, &.{root}));
}

test "recurses into right child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const inner = try makeNode(allocator, "inner", 1, "inner", null, null);
    const root = try makeNode(allocator, "root", 2, null, null, inner);
    try expectStrings(&.{"inner"}, try collectLeaves(allocator, &.{root}));
}

test "recurses into both left and right children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leftLeaf = try makeNode(allocator, "l", 1, "left", null, null);
    const rightLeaf = try makeNode(allocator, "r", 1, "right", null, null);
    const root = try makeNode(allocator, "root", 3, null, leftLeaf, rightLeaf);
    try expectStrings(&.{ "left", "right" }, try collectLeaves(allocator, &.{root}));
}

test "yields nothing when tree1 does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage2, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{"rec1"}, "COLT");
    var iterator = try replicate_module.iterateShardDifferences(allocator, io, "coll", "s1", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "yields all record ids from tree1 when tree2 does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{ "rec1", "rec2" }, "COLT");
    var iterator = try replicate_module.iterateShardDifferences(allocator, io, "coll", "s1", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try expectStrings(&.{ "rec1", "rec2" }, try sortedRecordIds(allocator, results));
    for (results) |result| {
        try std.testing.expectEqualStrings("coll", result.collectionName);
    }
}

test "yields differing record ids when both trees exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{ "rec1", "rec2", "rec3" }, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage2, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{"rec1"}, "COLT");
    var iterator = try replicate_module.iterateShardDifferences(allocator, io, "coll", "s1", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try expectStrings(&.{ "rec2", "rec3" }, try sortedRecordIds(allocator, results));
    for (results) |result| {
        try std.testing.expectEqualStrings("coll", result.collectionName);
    }
}

test "yields nothing when both trees are identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{ "rec1", "rec2" }, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage2, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{ "rec1", "rec2" }, "COLT");
    var iterator = try replicate_module.iterateShardDifferences(allocator, io, "coll", "s1", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "yields nothing when tree1 collection does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage2, try collCollectionPath(allocator, "coll"), VALID_UUID, &.{"s1"}, "COLT");
    var iterator = try replicate_module.iterateCollectionDifferences(allocator, io, "coll", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "yields record ids from all shards when tree2 collection does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage1, try collCollectionPath(allocator, "coll"), VALID_UUID, &.{ "s1", "s2" }, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "coll", "s1"), VALID_UUID, &.{"rec1"}, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "coll", "s2"), VALID_UUID, &.{ "rec2", "rec3" }, "COLT");
    var iterator = try replicate_module.iterateCollectionDifferences(allocator, io, "coll", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try expectStrings(&.{ "rec1", "rec2", "rec3" }, try sortedRecordIds(allocator, results));
    for (results) |result| {
        try std.testing.expectEqualStrings("coll", result.collectionName);
    }
}

test "yields differing record ids when both collections exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    const shardTree1 = try buildTree(allocator, VALID_UUID, try makeItems(allocator, &.{ "a", "b", "c" }));
    const shardTree2 = try buildTree(allocator, VALID_UUID, try makeItems(allocator, &.{"a"}));
    try saveTree(allocator, io, try shardPath(allocator, "coll", "s1"), shardTree1, storages.storage1, "COLT");
    try saveTree(allocator, io, try shardPath(allocator, "coll", "s1"), shardTree2, storages.storage2, "COLT");
    const collTree1 = try buildTree(allocator, VALID_UUID, &.{.{ .name = "s1", .hash = shardTree1.merkle.?.hash, .length = 0, .lastModified = 0 }});
    const collTree2 = try buildTree(allocator, VALID_UUID, &.{.{ .name = "s1", .hash = shardTree2.merkle.?.hash, .length = 0, .lastModified = 0 }});
    try saveTree(allocator, io, try collCollectionPath(allocator, "coll"), collTree1, storages.storage1, "COLT");
    try saveTree(allocator, io, try collCollectionPath(allocator, "coll"), collTree2, storages.storage2, "COLT");
    var iterator = try replicate_module.iterateCollectionDifferences(allocator, io, "coll", storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try expectStrings(&.{ "b", "c" }, try sortedRecordIds(allocator, results));
    for (results) |result| {
        try std.testing.expectEqualStrings("coll", result.collectionName);
    }
}

test "yields nothing when tree1 database does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage2, ".db/bson/db.dat", VALID_UUID, &.{"coll"}, "BDBT");
    var iterator = try replicate_module.iterateDatabaseDifferences(allocator, io, storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "yields record ids from all collections when tree2 database does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    try buildAndSaveTree(allocator, io, storages.storage1, ".db/bson/db.dat", VALID_UUID, &.{ "c1", "c2" }, "BDBT");
    try buildAndSaveTree(allocator, io, storages.storage1, try collCollectionPath(allocator, "c1"), VALID_UUID, &.{"s1"}, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "c1", "s1"), VALID_UUID, &.{"r1"}, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage1, try collCollectionPath(allocator, "c2"), VALID_UUID, &.{"s1"}, "COLT");
    try buildAndSaveTree(allocator, io, storages.storage1, try shardPath(allocator, "c2", "s1"), VALID_UUID, &.{"r2"}, "COLT");
    var iterator = try replicate_module.iterateDatabaseDifferences(allocator, io, storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |result| {
        if (std.mem.eql(u8, result.collectionName, "c1")) {
            try std.testing.expectEqualStrings("r1", result.recordId);
        }
        else {
            try std.testing.expectEqualStrings("c2", result.collectionName);
            try std.testing.expectEqualStrings("r2", result.recordId);
        }
    }
}

test "yields differing record ids when both databases exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storages = try makeStorages(allocator, io);
    defer helpers.removeTempDir(io, storages.dir);
    const shardTree1 = try buildTree(allocator, VALID_UUID, try makeItems(allocator, &.{ "id1", "id2" }));
    const shardTree2 = try buildTree(allocator, VALID_UUID, try makeItems(allocator, &.{"id1"}));
    try saveTree(allocator, io, try shardPath(allocator, "coll", "s1"), shardTree1, storages.storage1, "COLT");
    try saveTree(allocator, io, try shardPath(allocator, "coll", "s1"), shardTree2, storages.storage2, "COLT");
    const collTree1 = try buildTree(allocator, VALID_UUID, &.{.{ .name = "s1", .hash = shardTree1.merkle.?.hash, .length = 0, .lastModified = 0 }});
    const collTree2 = try buildTree(allocator, VALID_UUID, &.{.{ .name = "s1", .hash = shardTree2.merkle.?.hash, .length = 0, .lastModified = 0 }});
    try saveTree(allocator, io, try collCollectionPath(allocator, "coll"), collTree1, storages.storage1, "COLT");
    try saveTree(allocator, io, try collCollectionPath(allocator, "coll"), collTree2, storages.storage2, "COLT");
    const dbTree1 = try buildTree(allocator, VALID_UUID, &.{.{ .name = "coll", .hash = collTree1.merkle.?.hash, .length = 0, .lastModified = 0 }});
    const dbTree2 = try buildTree(allocator, VALID_UUID, &.{.{ .name = "coll", .hash = collTree2.merkle.?.hash, .length = 0, .lastModified = 0 }});
    try saveTree(allocator, io, ".db/bson/db.dat", dbTree1, storages.storage1, "BDBT");
    try saveTree(allocator, io, ".db/bson/db.dat", dbTree2, storages.storage2, "BDBT");
    var iterator = try replicate_module.iterateDatabaseDifferences(allocator, io, storages.storage1, storages.storage2);
    const results = try collectRecords(allocator, &iterator);
    try expectStrings(&.{"id2"}, try sortedRecordIds(allocator, results));
    try std.testing.expectEqualStrings("coll", results[0].collectionName);
}

//
// The generators and storages of a replicate test.
//
const ReplicateFixture = struct {
    // The temporary directory holding the storages.
    dir: []const u8,

    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // Deterministic time.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The source database storage.
    sourceAsset: IStorage,

    // The destination database storage.
    destAsset: IStorage,

    // The source BSON database (in an empty storage, like `new BsonDatabase(new MockStorage(), "", ...)`).
    sourceBdb: *bdb.database.BsonDatabase,
};

//
// Creates the fixture of a replicate test.
//
fn makeReplicateFixture(allocator: std.mem.Allocator, io: std.Io) !*ReplicateFixture {
    _ = try helpers.setupEnvironment(io);
    const fixture = try allocator.create(ReplicateFixture);
    fixture.dir = try helpers.makeTempDir(allocator, io, "replicate");
    fixture.uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    fixture.timestampProvider = .{};
    fixture.sourceAsset = try helpers.directoryStorage(allocator, io, try std.fmt.allocPrint(allocator, "{s}/source", .{fixture.dir}));
    fixture.destAsset = try helpers.directoryStorage(allocator, io, try std.fmt.allocPrint(allocator, "{s}/dest", .{fixture.dir}));
    const bdbStorage = try helpers.directoryStorage(allocator, io, try std.fmt.allocPrint(allocator, "{s}/bdb", .{fixture.dir}));
    fixture.sourceBdb = try bdb.database.BsonDatabase.init(allocator, bdbStorage, "", fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());
    return fixture;
}

//
// Saves an empty files tree with the given id and `{ filesImported: 0 }` metadata.
//
fn saveEmptyFilesTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, id: []const u8) !void {
    var tree = merkle_tree.createTree(id);
    tree.databaseMetadata = try node_api.media_file_database.emptyDatabaseMetadata(allocator);
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    try merkle_tree.saveTree(allocator, io, ".db/files.dat", &tree, storage, "FTRE");
}

test "throws when source merkle tree fails to load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try makeReplicateFixture(allocator, io);
    defer helpers.removeTempDir(io, fixture.dir);
    try std.testing.expectError(error.Thrown, replicate_module.replicate(allocator, io, "mock://source", fixture.sourceAsset, fixture.sourceBdb, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), fixture.destAsset, fixture.destAsset, null, null));
    try std.testing.expectEqualStrings("Failed to load merkle tree", errors.lastErrorMessage());
}

test "throws when dest has different database ID and force is not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try makeReplicateFixture(allocator, io);
    defer helpers.removeTempDir(io, fixture.dir);
    const dbId = try fixture.uuidGenerator.generate(allocator, io);
    try saveEmptyFilesTree(allocator, io, fixture.sourceAsset, dbId);
    const destDbId = try fixture.uuidGenerator.generate(allocator, io);
    try saveEmptyFilesTree(allocator, io, fixture.destAsset, destDbId);
    try std.testing.expectError(error.FatalError, replicate_module.replicate(allocator, io, "mock://source", fixture.sourceAsset, fixture.sourceBdb, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), fixture.destAsset, fixture.destAsset, null, null));
    const expected = try std.fmt.allocPrint(allocator, "You are trying to replicate to a database that has a different ID than the source database.\nSource database ID: {s}\nDestination database ID: {s}\nThe destination database is not related to the source database.\nUse the --force flag to proceed anyway.", .{ dbId, destDbId });
    try std.testing.expectEqualStrings(expected, errors.lastErrorMessage());
}

test "succeeds when force is true and database IDs differ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try makeReplicateFixture(allocator, io);
    defer helpers.removeTempDir(io, fixture.dir);
    const dbId = try fixture.uuidGenerator.generate(allocator, io);
    try saveEmptyFilesTree(allocator, io, fixture.sourceAsset, dbId);
    try saveEmptyFilesTree(allocator, io, fixture.destAsset, try fixture.uuidGenerator.generate(allocator, io));
    const result = try replicate_module.replicate(allocator, io, "mock://source", fixture.sourceAsset, fixture.sourceBdb, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), fixture.destAsset, fixture.destAsset, .{ .force = true }, null);
    try std.testing.expectEqual(@as(u64, 0), result.filesImported);
    try std.testing.expectEqual(@as(u64, 0), result.copiedFiles);
    try std.testing.expectEqual(@as(u64, 0), result.copiedRecords);
    try std.testing.expectEqual(@as(usize, 0), result.prunedFiles.len);
}

test "returns result shape with zero counts when source has no files and empty dest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try makeReplicateFixture(allocator, io);
    defer helpers.removeTempDir(io, fixture.dir);
    try saveEmptyFilesTree(allocator, io, fixture.sourceAsset, try fixture.uuidGenerator.generate(allocator, io));
    const result = try replicate_module.replicate(allocator, io, "mock://source", fixture.sourceAsset, fixture.sourceBdb, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), fixture.destAsset, fixture.destAsset, null, null);
    try std.testing.expectEqual(@as(u64, 0), result.filesImported);
    try std.testing.expectEqual(@as(u64, 0), result.copiedFiles);
    try std.testing.expectEqual(@as(u64, 0), result.copiedRecords);

    // The README.md that createDatabase added to the new destination is not in the empty source, so it is pruned.
    try std.testing.expectEqual(@as(usize, 1), result.prunedFiles.len);
    try std.testing.expectEqualStrings("README.md", result.prunedFiles[0]);
}

test "replicate copies a v6 database, reports progress, and a second replicate copies nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try makeReplicateFixture(allocator, io);
    defer helpers.removeTempDir(io, fixture.dir);
    const sourceDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(sourceDir).?);
    const destDir = try std.fmt.allocPrint(allocator, "{s}/replica", .{fixture.dir});
    const source = try node_api.open_storage.openStorage(allocator, io, sourceDir, null, null);
    const dest = try node_api.open_storage.openStorage(allocator, io, destDir, null, null);
    const sourceDb = try node_api.media_file_database.createMediaFileDatabase(allocator, source.storage, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());

    var recorder: helpers.ProgressRecorder = .{ .allocator = allocator };
    const Record = struct {
        fn call(context: ?*anyopaque, message: ?[]const u8) void {
            const self: *helpers.ProgressRecorder = @ptrCast(@alignCast(context.?));
            self.record(message orelse "");
        }
    };
    const progressCallback: node_api.media_file_database.ProgressCallback = .{ .context = &recorder, .function = Record.call };

    const result = try replicate_module.replicate(allocator, io, sourceDir, source.storage, sourceDb.bsonDatabase, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), dest.storage, dest.rawStorage, null, progressCallback);
    try std.testing.expectEqual(@as(u64, 1), result.filesImported);
    try std.testing.expectEqual(@as(u64, 3), result.copiedFiles);
    try std.testing.expectEqual(@as(u64, 1), result.copiedRecords);
    try std.testing.expectEqual(@as(usize, 0), result.prunedFiles.len);
    try std.testing.expectEqualStrings("Copied 1", recorder.messages.items[0]);
    try std.testing.expectEqualStrings("Copied 3 files, 1 records", recorder.messages.items[recorder.messages.items.len - 1]);

    const config = (try node_api.open_storage.openStorage(allocator, io, destDir, null, null)).rawStorage;
    const configData = (try config.read(allocator, io, ".db/config.json")).?;
    const expectedConfig = try std.fmt.allocPrint(allocator, "{{\n  \"origin\": {f},\n  \"lastReplicatedAt\": \"2022-01-01T00:00:00.000Z\"\n}}", .{std.json.fmt(sourceDir, .{})});
    try std.testing.expectEqualStrings(expectedConfig, configData);

    const secondSourceDb = try node_api.media_file_database.createMediaFileDatabase(allocator, source.storage, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());
    const secondResult = try replicate_module.replicate(allocator, io, sourceDir, source.storage, secondSourceDb.bsonDatabase, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), dest.storage, dest.rawStorage, null, null);
    try std.testing.expectEqual(@as(u64, 0), secondResult.copiedFiles);
    try std.testing.expectEqual(@as(u64, 0), secondResult.copiedRecords);
}

test "replicate with a path filter only copies the matching files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try makeReplicateFixture(allocator, io);
    defer helpers.removeTempDir(io, fixture.dir);
    const sourceDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(sourceDir).?);
    const destDir = try std.fmt.allocPrint(allocator, "{s}/replica", .{fixture.dir});
    const source = try node_api.open_storage.openStorage(allocator, io, sourceDir, null, null);
    const dest = try node_api.open_storage.openStorage(allocator, io, destDir, null, null);
    const sourceDb = try node_api.media_file_database.createMediaFileDatabase(allocator, source.storage, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());

    const result = try replicate_module.replicate(allocator, io, sourceDir, source.storage, sourceDb.bsonDatabase, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), dest.storage, dest.rawStorage, .{ .pathFilter = "thumb" }, null);
    try std.testing.expectEqual(@as(u64, 1), result.copiedFiles);
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/thumb/89171cd9-a652-4047-b869-1154bf2c95a1", .{destDir})));
    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/asset/89171cd9-a652-4047-b869-1154bf2c95a1", .{destDir})));
}

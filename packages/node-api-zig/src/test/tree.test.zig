const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const tree = node_api.tree;
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;

test "merkleTreeExists is false for an empty directory and true for a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "tree-empty");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expect(!try tree.merkleTreeExists(allocator, io, try helpers.directoryStorage(allocator, io, emptyDir)));

    const databaseDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.testing.expect(try tree.merkleTreeExists(allocator, io, try helpers.directoryStorage(allocator, io, databaseDir)));
}

test "loadMerkleTree loads the files tree of a v6 database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storage = try helpers.directoryStorage(allocator, io, helpers.TEST_DBS_DIR ++ "/v6");
    const loaded = (try tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(u32, 4), loaded.sort.?.leafCount);
    try std.testing.expect(loaded.merkle != null);
    try std.testing.expectEqual(@as(u64, 1), node_api.media_file_database.getFilesImported(loaded.databaseMetadata));
}

test "loadMerkleTree returns null when there is no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "tree-none");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expect(try tree.loadMerkleTree(allocator, io, try helpers.directoryStorage(allocator, io, emptyDir)) == null);
}

test "saveMerkleTree throws when no tree is provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "tree-null");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expectError(error.Thrown, tree.saveMerkleTree(allocator, io, null, try helpers.directoryStorage(allocator, io, emptyDir)));
    try std.testing.expectEqualStrings("Cannot save database. No merkle tree provided.", errors.lastErrorMessage());
}

test "saveMerkleTree rebuilds a dirty tree and saves it to .db/files.dat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "tree-save");
    defer helpers.removeTempDir(io, dir);
    const storage = try helpers.directoryStorage(allocator, io, dir);

    var merkleTree = merkle_tree.createTree("12345678-1234-5678-9abc-123456789abc");
    merkleTree = try merkle_tree.addItem(allocator, &merkleTree, .{ .name = "asset/a", .hash = &([_]u8{1} ** 32), .length = 5, .lastModified = 1000 });
    try std.testing.expect(merkleTree.dirty);
    try tree.saveMerkleTree(allocator, io, &merkleTree, storage);
    try std.testing.expect(!merkleTree.dirty);
    try std.testing.expect(merkleTree.merkle != null);

    const loaded = (try tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqualStrings("12345678-1234-5678-9abc-123456789abc", loaded.id);
    try std.testing.expectEqualSlices(u8, merkleTree.merkle.?.hash, loaded.merkle.?.hash);
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/files.dat", .{dir})));
}

test "loadCollectionMerkleTree and loadShardMerkleTree load the BSON trees of a v6 database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const storage = try helpers.directoryStorage(allocator, io, helpers.TEST_DBS_DIR ++ "/v6");
    const collectionTree = (try tree.loadCollectionMerkleTree(allocator, io, storage, "metadata")).?;
    var shardNames = merkle_tree.iterateLeaves(merkle_tree.MerkleNode, allocator, collectionTree.merkle);
    const shardLeaf = (try shardNames.next()).?;
    try std.testing.expectEqualStrings("96", shardLeaf.name.?);

    const shardTree = (try tree.loadShardMerkleTree(allocator, io, storage, "metadata", "96")).?;
    var recordNames = merkle_tree.iterateLeaves(merkle_tree.MerkleNode, allocator, shardTree.merkle);
    const recordLeaf = (try recordNames.next()).?;
    try std.testing.expectEqualStrings("89171cd9-a652-4047-b869-1154bf2c95a1", recordLeaf.name.?);

    try std.testing.expect(try tree.loadShardMerkleTree(allocator, io, storage, "metadata", "1") == null);
    try std.testing.expect(try tree.loadCollectionMerkleTree(allocator, io, storage, "missing") == null);
}

//
// Adds a file entry to the files merkle tree and saves it.
//
fn addFileToFilesTree(allocator: std.mem.Allocator, io: std.Io, assetStorage: storage_zig.storage.IStorage, name: []const u8, seed: u8) !void {
    var loaded = (try tree.loadMerkleTree(allocator, io, assetStorage)) orelse {
        return error.TestUnexpectedResult;
    };
    const hash = try allocator.alloc(u8, 32);
    @memset(hash, seed);
    var updated = try merkle_tree.addItem(allocator, &loaded, .{
        .name = name,
        .hash = hash,
        .length = 3,
        .lastModified = 0,
    });
    try tree.saveMerkleTree(allocator, io, &updated, assetStorage);
}

//
// Creates a new database (files tree only, no committed BSON record) in a new directory.
//
fn createEmptyDatabase(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !TestDatabase {
    _ = try helpers.setupEnvironment(io);
    const dir = try helpers.makeTempDir(allocator, io, name);
    const opened = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    const database = try node_api.media_file_database.createMediaFileDatabase(allocator, opened.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    try node_api.media_file_database.createDatabase(allocator, io, opened.storage, opened.rawStorage, uuidGenerator.uuidGenerator(), database.metadataCollection, null);
    return .{ .dir = dir, .assetStorage = opened.storage, .rawStorage = opened.rawStorage };
}

//
// A database of a test.
//
const TestDatabase = struct {
    // The directory holding it.
    dir: []const u8,

    // Its storage.
    assetStorage: storage_zig.storage.IStorage,

    // Its raw storage.
    rawStorage: storage_zig.storage.IStorage,
};

//
// A copy of test/dbs/v6: a database with a files tree and committed BSON records.
//
fn createPopulatedDatabase(allocator: std.mem.Allocator, io: std.Io) !TestDatabase {
    _ = try helpers.setupEnvironment(io);
    const dir = try helpers.copyTestDatabase(allocator, io, "v6");
    const opened = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    return .{ .dir = dir, .assetStorage = opened.storage, .rawStorage = opened.rawStorage };
}

test "returns undefined when there is no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const emptyDir = try helpers.makeTempDir(allocator, io, "content-hash-empty");
    defer helpers.removeTempDir(io, emptyDir);
    try std.testing.expect(try tree.getDatabaseContentHash(allocator, io, try helpers.directoryStorage(allocator, io, emptyDir)) == null);
}

test "returns undefined when the bson database tree is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try createEmptyDatabase(allocator, io, "content-hash-nobson");
    defer helpers.removeTempDir(io, database.dir);

    // Files tree has content, but no bson record has been committed.
    try addFileToFilesTree(allocator, io, database.assetStorage, "asset/1", 1);

    try std.testing.expect(try tree.getDatabaseContentHash(allocator, io, database.assetStorage) == null);
}

test "returns a 32-byte combined hash when both trees exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try createPopulatedDatabase(allocator, io);
    defer helpers.removeTempDir(io, std.fs.path.dirname(database.dir).?);

    const hash = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;
    try std.testing.expectEqual(@as(usize, 32), hash.len);

    // The files root combined with the BSON database root.
    const filesRoot = (try tree.getFilesRootHash(allocator, io, database.assetStorage)).?;
    const bsonRoot = (try bdb.merkle_tree.getDatabaseRootHash(allocator, io, database.assetStorage, ".db/bson")).?;
    try std.testing.expectEqualSlices(u8, &merkle_tree.combineHashes(filesRoot, bsonRoot), hash);
}

test "changes when the files tree changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try createPopulatedDatabase(allocator, io);
    defer helpers.removeTempDir(io, std.fs.path.dirname(database.dir).?);

    const before = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;
    try addFileToFilesTree(allocator, io, database.assetStorage, "asset/2", 2);
    const after = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;

    try std.testing.expect(!std.mem.eql(u8, before, after));
}

test "writes the content hash plus the extra fields while holding the lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try createPopulatedDatabase(allocator, io);
    defer helpers.removeTempDir(io, std.fs.path.dirname(database.dir).?);

    try tree.stampDatabaseStateLocked(allocator, io, database.assetStorage, database.rawStorage, "session-1", .{ .lastSyncedAt = "2026-01-02T03:04:05.000Z" });

    const state = (try api.database_state.loadDatabaseState(allocator, io, database.rawStorage)).?;
    try std.testing.expectEqualStrings("2026-01-02T03:04:05.000Z", state.lastSyncedAt.?);
    const expectedHash = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;
    try std.testing.expectEqualSlices(u8, expectedHash, state.contentHash.?);

    // The lock is released afterwards.
    try std.testing.expect(try database.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "other"));
}

test "omits the content hash when the database is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const dir = try helpers.makeTempDir(allocator, io, "stamp-locked-empty");
    defer helpers.removeTempDir(io, dir);
    const opened = try node_api.open_storage.openStorage(allocator, io, dir, null, null);

    try tree.stampDatabaseStateLocked(allocator, io, opened.storage, opened.rawStorage, "session-1", .{ .lastReplicatedAt = "2026-01-02T03:04:05.000Z" });

    const state = (try api.database_state.loadDatabaseState(allocator, io, opened.rawStorage)).?;
    try std.testing.expectEqualStrings("2026-01-02T03:04:05.000Z", state.lastReplicatedAt.?);
    try std.testing.expect(state.contentHash == null);
}

test "does nothing when the lock is held by another owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try createPopulatedDatabase(allocator, io);
    defer helpers.removeTempDir(io, std.fs.path.dirname(database.dir).?);
    _ = try database.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "other-owner");

    try tree.stampDatabaseStateLocked(allocator, io, database.assetStorage, database.rawStorage, "session-1", .{ .lastSyncedAt = "2026-01-02T03:04:05.000Z" });

    try std.testing.expect(try api.database_state.loadDatabaseState(allocator, io, database.rawStorage) == null);
}

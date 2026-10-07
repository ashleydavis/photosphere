const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const console_capture = @import("console-capture.zig");
const test_environment = @import("test-environment.zig");
const fixture_dirs = @import("fixture-dirs.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const tree = node_api.tree;
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;

test "merkleTreeExists is false for an empty directory and true for a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "tree-empty");
    defer temp_dirs.removeTempDir(io, emptyDir);
    try std.testing.expect(!try tree.merkleTreeExists(allocator, io, try test_files.directoryStorage(allocator, io, emptyDir)));

    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.testing.expect(try tree.merkleTreeExists(allocator, io, try test_files.directoryStorage(allocator, io, databaseDir)));
}

test "loadMerkleTree loads the files tree of a v6 database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const storage = try test_files.directoryStorage(allocator, io, fixture_dirs.TEST_DBS_DIR ++ "/v6");
    const loaded = (try tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(u32, 4), loaded.sort.?.leafCount);
    try std.testing.expect(loaded.merkle != null);
    try std.testing.expectEqual(@as(u64, 1), node_api.media_file_database.getFilesImported(loaded.databaseMetadata));
}

test "loadMerkleTree returns null when there is no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "tree-none");
    defer temp_dirs.removeTempDir(io, emptyDir);
    try std.testing.expect(try tree.loadMerkleTree(allocator, io, try test_files.directoryStorage(allocator, io, emptyDir)) == null);
}

test "saveMerkleTree throws when no tree is provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "tree-null");
    defer temp_dirs.removeTempDir(io, emptyDir);
    try std.testing.expectError(error.Thrown, tree.saveMerkleTree(allocator, io, null, try test_files.directoryStorage(allocator, io, emptyDir)));
    try std.testing.expectEqualStrings("Cannot save database. No merkle tree provided.", errors.lastErrorMessage());
}

test "saveMerkleTree rebuilds a dirty tree and saves it to .db/files.dat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const dir = try temp_dirs.makeTempDir(allocator, io, "tree-save");
    defer temp_dirs.removeTempDir(io, dir);
    const storage = try test_files.directoryStorage(allocator, io, dir);

    var merkleTree = merkle_tree.createTree("12345678-1234-5678-9abc-123456789abc");
    merkleTree = try merkle_tree.addItem(allocator, &merkleTree, .{ .name = "asset/a", .hash = &([_]u8{1} ** 32), .length = 5, .lastModified = 1000 });
    try std.testing.expect(merkleTree.dirty);
    try tree.saveMerkleTree(allocator, io, &merkleTree, storage);
    try std.testing.expect(!merkleTree.dirty);
    try std.testing.expect(merkleTree.merkle != null);

    const loaded = (try tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqualStrings("12345678-1234-5678-9abc-123456789abc", loaded.id);
    try std.testing.expectEqualSlices(u8, merkleTree.merkle.?.hash, loaded.merkle.?.hash);
    try std.testing.expect(test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/files.dat", .{dir})));
}

test "loadCollectionMerkleTree and loadShardMerkleTree load the BSON trees of a v6 database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const storage = try test_files.directoryStorage(allocator, io, fixture_dirs.TEST_DBS_DIR ++ "/v6");
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
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
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
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    const opened = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    return .{ .dir = dir, .assetStorage = opened.storage, .rawStorage = opened.rawStorage };
}

test "returns undefined when there is no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "content-hash-empty");
    defer temp_dirs.removeTempDir(io, emptyDir);
    try std.testing.expect(try tree.getDatabaseContentHash(allocator, io, try test_files.directoryStorage(allocator, io, emptyDir)) == null);
}

test "returns undefined when the bson database tree is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createEmptyDatabase(allocator, io, "content-hash-nobson");
    defer temp_dirs.removeTempDir(io, database.dir);

    // Files tree has content, but no bson record has been committed.
    try addFileToFilesTree(allocator, io, database.assetStorage, "asset/1", 1);

    try std.testing.expect(try tree.getDatabaseContentHash(allocator, io, database.assetStorage) == null);
}

test "returns a 32-byte combined hash when both trees exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);

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
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);

    const before = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;
    try addFileToFilesTree(allocator, io, database.assetStorage, "asset/2", 2);
    const after = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;

    try std.testing.expect(!std.mem.eql(u8, before, after));
}

test "writes the content hash plus the extra fields while holding the lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);

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
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "stamp-locked-empty");
    defer temp_dirs.removeTempDir(io, dir);
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
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);
    _ = try database.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "other-owner");

    // The failed lock attempt warns on the console; captured so nothing reaches the test program's stderr.
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    console_capture.captureStderr(&stderr_capture.writer);
    defer console_capture.endConsoleCapture();

    try tree.stampDatabaseStateLocked(allocator, io, database.assetStorage, database.rawStorage, "session-1", .{ .lastSyncedAt = "2026-01-02T03:04:05.000Z" });

    try std.testing.expect(try api.database_state.loadDatabaseState(allocator, io, database.rawStorage) == null);
}

test "writes the given fields plus the current content hash without acquiring the lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);

    try tree.stampDatabaseState(allocator, io, database.assetStorage, database.rawStorage, .{ .lastSyncedAt = "2026-01-02T03:04:05.000Z" });

    const state = (try api.database_state.loadDatabaseState(allocator, io, database.rawStorage)).?;
    try std.testing.expectEqualStrings("2026-01-02T03:04:05.000Z", state.lastSyncedAt.?);
    const expectedHash = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;
    try std.testing.expectEqualSlices(u8, expectedHash, state.contentHash.?);

    // The write lock was never taken, so it is still free.
    try std.testing.expect(try database.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "other"));
}

test "omits the content hash when the database is empty and preserves other fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "stamp-state-empty");
    defer temp_dirs.removeTempDir(io, dir);
    const opened = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    try api.database_state.saveDatabaseState(allocator, io, opened.rawStorage, .{ .lastModifiedAt = "2026-01-02T03:04:05.000Z" });

    try tree.stampDatabaseState(allocator, io, opened.storage, opened.rawStorage, .{ .lastSyncedAt = "2026-01-02T03:04:06.000Z" });

    const state = (try api.database_state.loadDatabaseState(allocator, io, opened.rawStorage)).?;
    try std.testing.expectEqualStrings("2026-01-02T03:04:05.000Z", state.lastModifiedAt.?);
    try std.testing.expectEqualStrings("2026-01-02T03:04:06.000Z", state.lastSyncedAt.?);
    try std.testing.expect(state.contentHash == null);
}

//
// `new Date().toISOString()`. (No TypeScript counterpart.)
//
fn nowIsoString(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const now: utils.timestamp_provider.Date = .{
        .epochMilliseconds = std.Io.Clock.real.now(io).toMilliseconds(),
    };
    return now.toISOString(allocator);
}

test "writes lastModifiedAt and the current content hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);

    const before = try nowIsoString(allocator, io);
    try tree.stampDatabaseModified(allocator, io, database.assetStorage, database.rawStorage);
    const after = try nowIsoString(allocator, io);

    const state = (try api.database_state.loadDatabaseState(allocator, io, database.rawStorage)).?;
    const lastModifiedAt = state.lastModifiedAt.?;
    try std.testing.expect(std.mem.order(u8, before, lastModifiedAt) != .gt);
    try std.testing.expect(std.mem.order(u8, lastModifiedAt, after) != .gt);

    const expectedHash = (try tree.getDatabaseContentHash(allocator, io, database.assetStorage)).?;
    try std.testing.expectEqualSlices(u8, expectedHash, state.contentHash.?);
}

test "writes lastModifiedAt but no content hash when the database is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "stamp-modified-empty");
    defer temp_dirs.removeTempDir(io, dir);
    const opened = try node_api.open_storage.openStorage(allocator, io, dir, null, null);

    try tree.stampDatabaseModified(allocator, io, opened.storage, opened.rawStorage);

    const state = (try api.database_state.loadDatabaseState(allocator, io, opened.rawStorage)).?;
    try std.testing.expect(state.lastModifiedAt != null);
    try std.testing.expect(state.contentHash == null);
}

test "preserves other state fields when stamping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const database = try createPopulatedDatabase(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(database.dir).?);
    try api.database_state.saveDatabaseState(allocator, io, database.rawStorage, .{ .lastSyncedAt = "2026-01-02T03:04:05.000Z" });

    try tree.stampDatabaseModified(allocator, io, database.assetStorage, database.rawStorage);

    const state = (try api.database_state.loadDatabaseState(allocator, io, database.rawStorage)).?;
    try std.testing.expectEqualStrings("2026-01-02T03:04:05.000Z", state.lastSyncedAt.?);
    try std.testing.expect(state.lastModifiedAt != null);
    try std.testing.expect(state.contentHash != null);
}

test "isDatabaseEncrypted is true only when the database has the encryption marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);
    try std.testing.expect(!try tree.isDatabaseEncrypted(allocator, io, storage));

    try storage.write(allocator, io, ".db/encryption.pub", null, "a public key");
    try std.testing.expect(try tree.isDatabaseEncrypted(allocator, io, storage));
}

//
// Path of the files tree in storage (the TypeScript FILES_TREE_PATH of tree.test.ts).
//
const FILES_TREE_PATH = ".db/files.dat";

//
// The ID of the trees the buildFilesTree tests build (the TypeScript TREE_ID of tree.test.ts).
//
const TREE_ID = "12345678-1234-5678-9abc-123456789abc";

//
// Returns the SHA-256 hash of a seed (TypeScript: makeHash).
//
fn makeHash(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const digest = try allocator.create([32]u8);
    std.crypto.hash.sha2.Sha256.hash(seed, digest, .{});
    return digest;
}

//
// Builds a files tree holding the named leaves, with `{ filesImported: 0 }` metadata (TypeScript: buildMinimalTree).
//
fn buildMinimalTree(allocator: std.mem.Allocator, leafNames: []const []const u8) !merkle_tree.IMerkleTree {
    var minimalTree = merkle_tree.createTree(TREE_ID);
    for (leafNames) |name| {
        minimalTree = try merkle_tree.addItem(allocator, &minimalTree, .{
            .name = name,
            .hash = try makeHash(allocator, name),
            .length = 0,
            .lastModified = std.Io.Clock.real.now(std.testing.io).toMilliseconds(),
        });
    }
    minimalTree.merkle = try merkle_tree.buildMerkleTree(allocator, minimalTree.sort);
    minimalTree.dirty = false;
    minimalTree.databaseMetadata = try node_api.media_file_database.emptyDatabaseMetadata(allocator);
    return minimalTree;
}

//
// Gets the names of the leaves of a tree's sort tree
// (TypeScript: `[...iterateLeaves<SortNode>(tree.sort)].map(n => n.name).filter(Boolean)`).
//
fn leafNamesOf(allocator: std.mem.Allocator, builtTree: *const merkle_tree.IMerkleTree) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var leaves = merkle_tree.iterateLeaves(merkle_tree.SortNode, allocator, builtTree.sort);
    while (try leaves.next()) |leaf| {
        if (leaf.name) |name| {
            if (name.len > 0) {
                try names.append(allocator, name);
            }
        }
    }
    return names.items;
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

//
// Records each file count buildFilesTree reports (TypeScript: `(count) => progressCalls.push(count)`).
//
const ProgressRecorder = struct {
    // Allocates the list.
    allocator: std.mem.Allocator,

    // The counts reported so far.
    progressCalls: std.ArrayList(u64) = .empty,

    //
    // Records a count.
    //
    fn record(context: ?*anyopaque, fileCount: u64) void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(context.?));
        self.progressCalls.append(self.allocator, fileCount) catch @panic("out of memory recording progress");
    }

    //
    // Gets the progress callback that records into this recorder.
    //
    fn callback(self: *ProgressRecorder) node_api.tree.IBuildFilesTreeProgress {
        return .{
            .context = self,
            .function = record,
        };
    }
};

//
// Ignores the file counts (TypeScript: `() => {}`).
//
fn ignoreProgress(context: ?*anyopaque, fileCount: u64) void {
    _ = context;
    _ = fileCount;
}

//
// A progress callback that does nothing (TypeScript: `() => {}`).
//
const noProgress: node_api.tree.IBuildFilesTreeProgress = .{
    .context = null,
    .function = ignoreProgress,
};

test "builds tree from storage when no existing tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    try storage.write(allocator, io, "asset/f1", "application/octet-stream", "a");
    try storage.write(allocator, io, "display/d1", "application/octet-stream", "b");
    try storage.write(allocator, io, "thumb/t1", "application/octet-stream", "c");

    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    var recorder: ProgressRecorder = .{ .allocator = allocator };
    const result = try tree.buildFilesTree(allocator, io, storage, recorder.callback(), uuidGenerator.uuidGenerator());

    try std.testing.expect(result.fileCount >= 3);
    const leafNames = try leafNamesOf(allocator, &result.merkleTree);
    try std.testing.expect(containsName(leafNames, "asset/f1"));
    try std.testing.expect(containsName(leafNames, "display/d1"));
    try std.testing.expect(containsName(leafNames, "thumb/t1"));
    try std.testing.expect(node_api.media_file_database.getFilesImported(result.merkleTree.databaseMetadata) >= 1);
    try std.testing.expect(try storage.fileExists(allocator, io, FILES_TREE_PATH));
    for (recorder.progressCalls.items, 0..) |count, index| {
        try std.testing.expectEqual(@as(u64, index + 1), count);
    }
}

test "preserves existing tree id when rebuilding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    const existingTree = try buildMinimalTree(allocator, &.{"asset/old"});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &existingTree, storage, "FTRE");
    try storage.write(allocator, io, "asset/old", "application/octet-stream", "old");
    try storage.write(allocator, io, "asset/new", "application/octet-stream", "new");

    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const result = try tree.buildFilesTree(allocator, io, storage, noProgress, uuidGenerator.uuidGenerator());

    try std.testing.expectEqualStrings(TREE_ID, result.merkleTree.id);
    const leafNames = try leafNamesOf(allocator, &result.merkleTree);
    try std.testing.expect(containsName(leafNames, "asset/old"));
    try std.testing.expect(containsName(leafNames, "asset/new"));
}

test "ignores paths under .db/" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    try storage.write(allocator, io, "asset/f1", "application/octet-stream", "a");
    try storage.write(allocator, io, ".db/config.json", "application/json", "{}");

    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const result = try tree.buildFilesTree(allocator, io, storage, noProgress, uuidGenerator.uuidGenerator());

    const leafNames = try leafNamesOf(allocator, &result.merkleTree);
    try std.testing.expect(containsName(leafNames, "asset/f1"));
    try std.testing.expect(!containsName(leafNames, ".db/config.json"));
}

test "returns fileCount 0 and filesImported 0 when storage has no content files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();

    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const result = try tree.buildFilesTree(allocator, io, storage, noProgress, uuidGenerator.uuidGenerator());

    try std.testing.expectEqual(@as(u64, 0), result.fileCount);
    try std.testing.expectEqual(@as(u64, 0), node_api.media_file_database.getFilesImported(result.merkleTree.databaseMetadata));
    try std.testing.expect(try storage.fileExists(allocator, io, FILES_TREE_PATH));
}

test "invokes progressCallback with incrementing count for each file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    try storage.write(allocator, io, "asset/a", "application/octet-stream", "a");
    try storage.write(allocator, io, "asset/b", "application/octet-stream", "b");

    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    var recorder: ProgressRecorder = .{ .allocator = allocator };
    _ = try tree.buildFilesTree(allocator, io, storage, recorder.callback(), uuidGenerator.uuidGenerator());

    const progressCalls = recorder.progressCalls.items;
    try std.testing.expect(progressCalls.len >= 2);
    try std.testing.expectEqual(@as(u64, 1), progressCalls[0]);
    try std.testing.expectEqual(@as(u64, progressCalls.len), progressCalls[progressCalls.len - 1]);
}

test "saved tree can be loaded and has correct databaseMetadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    try storage.write(allocator, io, "asset/only", "application/octet-stream", "x");

    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    _ = try tree.buildFilesTree(allocator, io, storage, noProgress, uuidGenerator.uuidGenerator());

    const loaded = try tree.loadMerkleTree(allocator, io, storage);
    try std.testing.expect(loaded != null);
    try std.testing.expect(loaded.?.databaseMetadata != null);
    try std.testing.expect(node_api.media_file_database.getFilesImported(loaded.?.databaseMetadata) >= 1);
}

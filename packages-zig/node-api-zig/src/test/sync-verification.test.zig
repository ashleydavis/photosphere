//
// Tests for how a sync checks its copies against the target's own hash (port of
// src/test/lib/sync-verification.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const sync_helpers = @import("sync-test-helpers.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const tree = node_api.tree;
const media_file_database = node_api.media_file_database;
const hash_module = node_api.hash;
const IStorage = storage_zig.storage.IStorage;
const createStorage = storage_zig.storage_factory.createStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const SpyStorage = sync_helpers.SpyStorage;
const SettableTimestampProvider = sync_helpers.SettableTimestampProvider;
const syncDatabases = node_api.sync.syncDatabases;

//
// The asset the source database holds and the sync has to push.
//
const assetId = "11111111-2222-3333-4444-555555555555";

//
// The bytes of that asset.
//
const assetBytes = "the-bytes-of-a-photo";

//
// A second asset, sorted after the first, so a test can say the sync carried on past a file it
// could not copy.
//
const laterAssetId = "99999999-2222-3333-4444-555555555555";

//
// The bytes of the second asset.
//
const laterAssetBytes = "the-bytes-of-another-photo";

//
// Writes an asset file and records it in the database's merkle tree.
// (Zig: writeAsset is not ported; this does what it does for a test, without the write lock.)
//
fn writeAsset(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, rawStorage: IStorage, id: []const u8, contentType: []const u8, buffer: []const u8) !void {
    const assetPath = try std.fmt.allocPrint(allocator, "asset/{s}", .{id});
    var merkleTree = (try tree.loadMerkleTree(allocator, io, assetStorage)).?;
    try assetStorage.write(allocator, io, assetPath, contentType, buffer);
    const assetInfo = (try assetStorage.info(allocator, io, assetPath)).?;
    const stream = try assetStorage.readStream(allocator, io, assetPath);
    defer stream.destroy(io);
    const hashedAsset = try hash_module.computeAssetHash(allocator, stream.reader(), .{
        .contentType = assetInfo.contentType,
        .length = assetInfo.length,
        .lastModified = assetInfo.lastModified,
    });
    merkleTree = try merkle_tree.addItem(allocator, &merkleTree, .{
        .name = assetPath,
        .hash = hashedAsset.hash,
        .length = hashedAsset.length,
        .lastModified = hashedAsset.lastModified,
    });
    const filesImported = media_file_database.getFilesImported(merkleTree.databaseMetadata);
    try merkleTree.databaseMetadata.?.put(allocator, "filesImported", .{ .number = @floatFromInt(filesImported + 1) });
    try tree.saveMerkleTree(allocator, io, &merkleTree, assetStorage);
    try tree.stampDatabaseModified(allocator, io, assetStorage, rawStorage);
}

//
// Inserts a metadata record and commits it.
//
fn insertRecord(allocator: std.mem.Allocator, io: std.Io, database: media_file_database.IMediaFileDatabase, id: []const u8, origFileName: []const u8) !void {
    var record = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = id },
        },
        .{
            .key = "origFileName",
            .value = .{ .string = origFileName },
        },
        .{
            .key = "contentType",
            .value = .{ .string = "image/jpeg" },
        },
    });
    try database.metadataCollection.insertOne(io, &record, null);
    try database.bsonDatabase.commit(io);
}

//
// Builds a source database holding one asset file, and an empty target replicated from it, and
// runs a sync between them with the target wrapped so its storedHash answers can be chosen.
//
// Returns the wrapper, so a test can read what was streamed back out of the target.
//
fn syncOneAsset(allocator: std.mem.Allocator, io: std.Io, workingDir: []const u8, targetHashes: *const std.StringHashMapUnmanaged([]const u8), verifiesWhatItWrites: ?bool) !*SpyStorage {
    const clock = try allocator.create(SettableTimestampProvider);
    clock.* = .{ .current = 1767225600000 }; // 2026-01-01T00:00:00.000Z

    const sourcePath = try std.fmt.allocPrint(allocator, "{s}/source", .{workingDir});
    try std.Io.Dir.cwd().createDirPath(io, sourcePath);
    const source = try createStorage(allocator, io, sourcePath, null, null);
    const sourceDatabase = try media_file_database.createMediaFileDatabase(allocator, source.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    try media_file_database.createDatabase(allocator, io, source.storage, source.rawStorage, try sync_helpers.testUuidGenerator(allocator), sourceDatabase.metadataCollection, null);

    try insertRecord(allocator, io, sourceDatabase, assetId, "test.jpg");
    try writeAsset(allocator, io, source.storage, source.rawStorage, assetId, "image/jpeg", assetBytes);

    try insertRecord(allocator, io, sourceDatabase, laterAssetId, "later.jpg");
    try writeAsset(allocator, io, source.storage, source.rawStorage, laterAssetId, "image/jpeg", laterAssetBytes);

    // The target is a database of its own, holding nothing, carrying the source's database id so
    // the two are related and a sync between them is allowed.
    //
    // Replicating one would not do: a replica arrives with the source's merkle tree, so it claims
    // to hold every file already and the sync copies nothing. Copying the id across is what
    // `replicate --force` does to a destination whose id does not match.
    const targetPath = try std.fmt.allocPrint(allocator, "{s}/target", .{workingDir});
    try std.Io.Dir.cwd().createDirPath(io, targetPath);
    const target = try createStorage(allocator, io, targetPath, null, null);
    const targetDatabase = try media_file_database.createMediaFileDatabase(allocator, target.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    try media_file_database.createDatabase(allocator, io, target.storage, target.rawStorage, try sync_helpers.testUuidGenerator(allocator), targetDatabase.metadataCollection, null);

    const sourceTree = try tree.loadMerkleTree(allocator, io, source.storage);
    var targetTree = try tree.loadMerkleTree(allocator, io, target.storage);
    if (sourceTree == null or targetTree == null) {
        return error.BothDatabasesMustHaveAMerkleTree;
    }
    targetTree.?.id = sourceTree.?.id;
    try tree.saveMerkleTree(allocator, io, &targetTree.?, target.storage);

    const reopenedSource = try createStorage(allocator, io, sourcePath, null, null);
    const reopenedSourceDatabase = try media_file_database.createMediaFileDatabase(allocator, reopenedSource.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    const reopenedTarget = try createStorage(allocator, io, targetPath, null, null);
    const wrappedTarget = try allocator.create(SpyStorage);
    wrappedTarget.* = .{
        .allocator = allocator,
        .inner = reopenedTarget.storage,
        .hashes = targetHashes,
        .verifiesWhatItWrites = verifiesWhatItWrites,
    };
    const reopenedTargetDatabase = try media_file_database.createMediaFileDatabase(allocator, wrappedTarget.storage(), try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());

    _ = try syncDatabases(
        allocator,
        io,
        reopenedSource.storage,
        reopenedSource.rawStorage,
        reopenedSourceDatabase.bsonDatabase,
        wrappedTarget.storage(),
        reopenedTarget.rawStorage,
        reopenedTargetDatabase.bsonDatabase,
        "session-sync",
        null,
    );

    return wrappedTarget;
}

//
// The path of an asset's file.
//
fn assetPathOf(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "asset/{s}", .{id});
}

test "a target that knows its own hash is not read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const workingDir = try temp_dirs.makeTempDir(allocator, io, "psphere-sync-verify");
    defer temp_dirs.removeTempDir(io, workingDir);

    // Reading every copied file back is what made syncing a phone's library unusable: the file
    // crosses the network twice and is hashed by the embedded engine's pure JavaScript SHA-256.
    var hashes: std.StringHashMapUnmanaged([]const u8) = .empty;
    try hashes.put(allocator, try assetPathOf(allocator, assetId), try sync_helpers.hashOf(allocator, assetBytes));

    const target = try syncOneAsset(allocator, io, workingDir, &hashes, null);

    // Said first, because "it was not read back" is true of a file that was never copied at all.
    try std.testing.expect(try target.storage().fileExists(allocator, io, try assetPathOf(allocator, assetId)));
    try std.testing.expect(!target.wasReadBack(try assetPathOf(allocator, assetId)));
}

test "a store that checked the bytes as it wrote them is asked nothing further" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const workingDir = try temp_dirs.makeTempDir(allocator, io, "psphere-sync-verify");
    defer temp_dirs.removeTempDir(io, workingDir);

    // Asking cost two more round trips per file on top of the write: one to learn the file is
    // there and how long it is, another to read back the hash the server had just verified. On a
    // phone, where every request is a fresh connection and the response crosses the engine
    // bridge, those two were a large part of what a file cost.
    const hashes: std.StringHashMapUnmanaged([]const u8) = .empty;
    const target = try syncOneAsset(allocator, io, workingDir, &hashes, true);

    try std.testing.expect(try target.storage().fileExists(allocator, io, try assetPathOf(allocator, assetId)));
    try std.testing.expect(!target.wasAskedAbout(try assetPathOf(allocator, assetId)));
}

test "the hash the sync already has goes up with the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const workingDir = try temp_dirs.makeTempDir(allocator, io, "psphere-sync-verify");
    defer temp_dirs.removeTempDir(io, workingDir);

    // Nothing should have to compute it. The AWS SDK asked to checksum a body hashes it in the
    // embedded engine's pure JavaScript SHA-256 at well under a megabyte a second, and on a
    // Pixel 6 one 100MB video held the upload for over a quarter of an hour with no byte
    // reaching the server. The merkle tree is made of these hashes, so the sync already has it.
    const hashes: std.StringHashMapUnmanaged([]const u8) = .empty;
    const target = try syncOneAsset(allocator, io, workingDir, &hashes, null);

    try std.testing.expectEqualSlices(u8, try sync_helpers.hashOf(allocator, assetBytes), target.hashesWrittenWith.get(try assetPathOf(allocator, assetId)).?);
}

test "a target that does not know its own hash is checked by length, not read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const workingDir = try temp_dirs.makeTempDir(allocator, io, "psphere-sync-verify");
    defer temp_dirs.removeTempDir(io, workingDir);

    // Reading a file back to hash it is what made syncing a phone's library impossible: each file
    // crossed the network twice and was hashed by the embedded engine's pure JavaScript SHA-256
    // at well under a megabyte a second. `psi verify` is the deep check.
    const hashes: std.StringHashMapUnmanaged([]const u8) = .empty;
    const target = try syncOneAsset(allocator, io, workingDir, &hashes, null);

    try std.testing.expect(try target.storage().fileExists(allocator, io, try assetPathOf(allocator, assetId)));
    try std.testing.expect(!target.wasReadBack(try assetPathOf(allocator, assetId)));
}

test "a file that will not copy is left behind and the rest of the library still goes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const workingDir = try temp_dirs.makeTempDir(allocator, io, "psphere-sync-verify");
    defer temp_dirs.removeTempDir(io, workingDir);

    // The rest of the library has nothing to do with the bad file, and abandoning the pass on it
    // means everything after it in the tree never goes anywhere: measured on a Pixel 6 against a
    // real library, one video the server kept refusing held up all 2,292 assets, pass after pass.
    var hashes: std.StringHashMapUnmanaged([]const u8) = .empty;
    try hashes.put(allocator, try assetPathOf(allocator, assetId), &([_]u8{9} ** 32));
    try hashes.put(allocator, try assetPathOf(allocator, laterAssetId), try sync_helpers.hashOf(allocator, laterAssetBytes));

    const target = try syncOneAsset(allocator, io, workingDir, &hashes, null);

    try std.testing.expect(try target.storage().fileExists(allocator, io, try assetPathOf(allocator, laterAssetId)));
}

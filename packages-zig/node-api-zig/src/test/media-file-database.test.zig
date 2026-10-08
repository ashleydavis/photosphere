const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const fixture_dirs = @import("fixture-dirs.zig");
const mock_log = @import("mock-log.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const media_file_database = node_api.media_file_database;
const errors = utils.errors;
const bson = serialization_zig.bson;

//
// The generators given to the databases the tests create.
//
const Generators = struct {
    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // The real clock.
    timestampProvider: utils.timestamp_provider.TimestampProvider,
};

//
// Creates the generators (after installing the test environment, which sets TEST_TMP_DIR).
//
fn makeGenerators(allocator: std.mem.Allocator, io: std.Io) !*Generators {
    _ = try test_environment.setupEnvironment(io);
    const generators = try allocator.create(Generators);
    generators.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
    };
    return generators;
}

test "DATABASE_README_CONTENT is the README of the test databases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const readme = try test_files.readFile(arena.allocator(), std.testing.io, fixture_dirs.TEST_DBS_DIR ++ "/v6/README.md");
    try std.testing.expectEqualStrings(readme, media_file_database.DATABASE_README_CONTENT);
}

test "createMediaFileDatabase creates the BSON database under .db/bson with the metadata collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const storage = try test_files.directoryStorage(allocator, io, fixture_dirs.TEST_DBS_DIR ++ "/v6");
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try std.testing.expectEqualStrings(".db/bson", database.bsonDatabase.bsonDbPath);
    try std.testing.expectEqualStrings("metadata", database.metadataCollection.name);
    var records = database.metadataCollection.iterateRecords();
    const record = (try records.next(io)).?;
    try std.testing.expectEqualStrings("89171cd9-a652-4047-b869-1154bf2c95a1", record._id);
    try std.testing.expect(try records.next(io) == null);
}

test "createDatabase creates README.md, the files tree, the sort indexes and config.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "create-database");
    defer temp_dirs.removeTempDir(io, dir);
    const created = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());

    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, generators.uuidGenerator.uuidGenerator(), database.metadataCollection, "12345678-1234-4678-8abc-123456789abc");

    try std.testing.expectEqualStrings(media_file_database.DATABASE_README_CONTENT, try test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/README.md", .{dir})));
    try std.testing.expectEqualStrings("{}", try test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/.db/config.json", .{dir})));
    try std.testing.expect(test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/hash_asc/tree.dat", .{dir})));
    try std.testing.expect(test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/photoDate_desc/tree.dat", .{dir})));

    const loaded = (try node_api.tree.loadMerkleTree(allocator, io, created.storage)).?;
    try std.testing.expectEqualStrings("12345678-1234-4678-8abc-123456789abc", loaded.id);
    try std.testing.expectEqual(@as(u32, 1), loaded.sort.?.leafCount);
    try std.testing.expectEqualStrings("README.md", loaded.sort.?.name.?);
    try std.testing.expectEqual(@as(u64, media_file_database.DATABASE_README_CONTENT.len), loaded.sort.?.size);
    try std.testing.expectEqual(@as(u64, 0), media_file_database.getFilesImported(loaded.databaseMetadata));
    try std.testing.expect(loaded.databaseMetadata.?.get("filesImported") != null);
}

test "createDatabase generates a database id when none is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "create-database-id");
    defer temp_dirs.removeTempDir(io, dir);
    const created = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, generators.uuidGenerator.uuidGenerator(), database.metadataCollection, null);
    const loaded = (try node_api.tree.loadMerkleTree(allocator, io, created.storage)).?;
    try std.testing.expectEqual(@as(usize, 36), loaded.id.len);
}

test "createDatabase throws when the directory already contains files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "create-database-full");
    defer temp_dirs.removeTempDir(io, dir);
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/something.txt", .{dir}), "x");
    const created = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try std.testing.expectError(error.Thrown, media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, generators.uuidGenerator.uuidGenerator(), database.metadataCollection, null));

    // The location is `pathJoin("fs:", path)` with forward slashes, so on Windows it reads "fs:/C:/...".
    const forwardSlashDir = try allocator.dupe(u8, dir);
    std.mem.replaceScalar(u8, forwardSlashDir, '\\', '/');
    const location = try storage_zig.storage_factory.pathJoin(allocator, &.{ "fs:", forwardSlashDir });
    const expected = try std.fmt.allocPrint(allocator, "Cannot create new media file database in {s}. This storage location already contains files! Please create your database in a new empty directory.", .{location});
    try std.testing.expectEqualStrings(expected, errors.lastErrorMessage());
}

test "createReadme writes README.md and adds it to the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const dir = try temp_dirs.makeTempDir(allocator, io, "create-readme");
    defer temp_dirs.removeTempDir(io, dir);
    const storage = try test_files.directoryStorage(allocator, io, dir);
    const merkleTree = try media_file_database.createReadme(allocator, io, storage, merkle_tree_zig.merkle_tree.createTree("id"));
    try std.testing.expect(merkleTree.dirty);
    try std.testing.expectEqualStrings("README.md", merkleTree.sort.?.name.?);
    var expectedHash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(media_file_database.DATABASE_README_CONTENT, &expectedHash, .{});
    try std.testing.expectEqualSlices(u8, &expectedHash, merkleTree.sort.?.contentHash.?);
}

test "ensureSortIndex builds the hash and photoDate sort indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.Io.Dir.cwd().deleteTree(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes", .{databaseDir}));
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try media_file_database.ensureSortIndex(io, database.metadataCollection);
    try std.testing.expect(test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/hash_asc/tree.dat", .{databaseDir})));
    try std.testing.expect(test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/photoDate_desc/tree.dat", .{databaseDir})));
}

test "loadSortIndexes succeeds for an existing database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const storage = try test_files.directoryStorage(allocator, io, fixture_dirs.TEST_DBS_DIR ++ "/v6");
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try media_file_database.loadSortIndexes(allocator, database.assetStorage, database.metadataCollection);
}

test "getFilesImported, isPartialDatabase, emptyDatabaseMetadata and copyDatabaseMetadata read and write the metadata document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(u64, 0), media_file_database.getFilesImported(null));
    try std.testing.expect(!media_file_database.isPartialDatabase(null));
    var metadata = try media_file_database.emptyDatabaseMetadata(allocator);
    try std.testing.expectEqual(@as(u64, 0), media_file_database.getFilesImported(metadata));
    try metadata.put(allocator, "filesImported", .{ .number = 7 });
    try metadata.put(allocator, "isPartial", .{ .boolean = true });
    try std.testing.expectEqual(@as(u64, 7), media_file_database.getFilesImported(metadata));
    try std.testing.expect(media_file_database.isPartialDatabase(metadata));
    const copy = try media_file_database.copyDatabaseMetadata(allocator, metadata);
    try std.testing.expect(copy.eql(metadata));
    try metadata.put(allocator, "isPartial", .{ .string = "true" });
    try std.testing.expect(!media_file_database.isPartialDatabase(metadata));
    const bytes = try bson.serialize(allocator, copy);
    try std.testing.expect(bytes.len > 0);
}

//
// Builds a one-file database in a storage, with the database metadata under test written into its files merkle
// tree, and returns the storage ready for getDatabaseSummary to read.
//
fn buildSummaryDatabase(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, databaseMetadata: ?bson.BsonDocument) !storage_zig.storage.IStorage {
    const storage = try test_files.directoryStorage(allocator, io, directory);
    var tree = merkle_tree_zig.merkle_tree.createTree("12345678-1234-5678-9abc-123456789abc");
    const hash = [_]u8{1} ** 32;
    tree = try merkle_tree_zig.merkle_tree.addItem(allocator, &tree, .{
        .name = "thumb/photo.jpg",
        .hash = &hash,
        .length = 100,
        .lastModified = 0,
    });
    tree.merkle = try merkle_tree_zig.merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    tree.databaseMetadata = databaseMetadata;
    try node_api.tree.saveMerkleTree(allocator, io, &tree, storage);
    return storage;
}

//
// Returns database metadata with filesImported 1 and the given isPartial.
//
fn summaryMetadata(allocator: std.mem.Allocator, isPartial: bool) !bson.BsonDocument {
    var metadata = try media_file_database.emptyDatabaseMetadata(allocator);
    try metadata.put(allocator, "filesImported", .{ .number = 1 });
    try metadata.put(allocator, "isPartial", .{ .boolean = isPartial });
    return metadata;
}

test "getDatabaseSummary reports partial mode when the tree says the database is partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const dir = try temp_dirs.makeTempDir(allocator, io, "summary-partial");
    defer temp_dirs.removeTempDir(io, dir);
    const storage = try buildSummaryDatabase(allocator, io, dir, try summaryMetadata(allocator, true));

    const summary = try media_file_database.getDatabaseSummary(allocator, io, storage);

    try std.testing.expectEqual(media_file_database.DatabaseMode.partial, summary.mode);
}

test "getDatabaseSummary reports full mode when the tree says the database is not partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const dir = try temp_dirs.makeTempDir(allocator, io, "summary-full");
    defer temp_dirs.removeTempDir(io, dir);
    const storage = try buildSummaryDatabase(allocator, io, dir, try summaryMetadata(allocator, false));

    const summary = try media_file_database.getDatabaseSummary(allocator, io, storage);

    try std.testing.expectEqual(media_file_database.DatabaseMode.full, summary.mode);
}

test "getDatabaseSummary reports full mode when the tree has no database metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const dir = try temp_dirs.makeTempDir(allocator, io, "summary-no-metadata");
    defer temp_dirs.removeTempDir(io, dir);
    const storage = try buildSummaryDatabase(allocator, io, dir, null);

    const summary = try media_file_database.getDatabaseSummary(allocator, io, storage);

    try std.testing.expectEqual(media_file_database.DatabaseMode.full, summary.mode);
}

test "getDatabaseSummary reads the counts and hashes of test/dbs/v6" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const storage = try test_files.directoryStorage(allocator, io, "../test/dbs/v6");

    const summary = try media_file_database.getDatabaseSummary(allocator, io, storage);

    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(media_file_database.DatabaseMode.full, summary.mode);
    // README.md and the asset, display and thumb files of its one asset: 913 + 2,049,800 + 696,014 + 130,591
    // bytes in a tree of 7 nodes (the numbers psi verify reports for it).
    try std.testing.expectEqual(@as(u64, 1), summary.totalImports);
    try std.testing.expectEqual(@as(u64, 7), summary.totalNodes);
    try std.testing.expectEqual(@as(u64, 4), summary.totalFiles);
    try std.testing.expectEqual(@as(u64, 2_877_318), summary.totalSize);
    try std.testing.expectEqual(@as(u32, 6), summary.databaseVersion);
    const filesHash = try std.fmt.allocPrint(allocator, "{x}", .{filesTree.merkle.?.hash});
    try std.testing.expectEqualStrings(filesHash, summary.filesHash.?);
    const databaseHash = (try @import("bdb-zig").merkle_tree.getDatabaseRootHash(allocator, io, storage, ".db/bson")).?;
    const combined = merkle_tree_zig.merkle_tree.combineHashes(filesTree.merkle.?.hash, databaseHash);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{x}", .{&combined}), summary.fullHash);
}

//
// The id of the one asset in test/dbs/v6.
//
const V6_ASSET_ID = "89171cd9-a652-4047-b869-1154bf2c95a1";

test "removeAsset removes the files, the tree entries and the record of an asset and records its id as deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());

    try media_file_database.removeAsset(allocator, io, storage, storage, "session", database.bsonDatabase, database.metadataCollection, V6_ASSET_ID, true);

    for ([_][]const u8{ "asset", "display", "thumb" }) |directory| {
        const filePath = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ databaseDir, directory, V6_ASSET_ID });
        try std.testing.expect(!test_files.fileExists(io, filePath));
    }
    try std.testing.expect(!test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/write.lock", .{databaseDir})));

    // The tree holds only the README, and its metadata counts no imports and names the asset as deleted.
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(u32, 1), filesTree.sort.?.leafCount);
    try std.testing.expectEqual(@as(u64, 0), media_file_database.getFilesImported(filesTree.databaseMetadata));
    const deletedAssetIds = filesTree.databaseMetadata.?.get("deletedAssetIds").?.array;
    try std.testing.expectEqual(@as(usize, 1), deletedAssetIds.len);
    try std.testing.expectEqualStrings(V6_ASSET_ID, deletedAssetIds[0].string);

    // The record is gone from a fresh read of the collection.
    const reloaded = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try std.testing.expect((try reloaded.metadataCollection.getOne(io, V6_ASSET_ID)) == null);

    // Removing it again finds no record, so the metadata is left as it is.
    try media_file_database.removeAsset(allocator, io, storage, storage, "session", reloaded.bsonDatabase, reloaded.metadataCollection, V6_ASSET_ID, true);
    const again = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(usize, 1), again.databaseMetadata.?.get("deletedAssetIds").?.array.len);
}

test "removeAsset leaves deletedAssetIds alone when the removal is not to be recorded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());

    try media_file_database.removeAsset(allocator, io, storage, storage, "session", database.bsonDatabase, database.metadataCollection, V6_ASSET_ID, false);

    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(u64, 0), media_file_database.getFilesImported(filesTree.databaseMetadata));
    try std.testing.expect(filesTree.databaseMetadata.?.get("deletedAssetIds") == null);
}

test "removeAsset throws when another session holds the write lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    const generators = try makeGenerators(allocator, io);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, ".db/write.lock", "another-session"));
    // Waiting for the lock logs the failure; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();

    try std.testing.expectError(error.Thrown, media_file_database.removeAsset(allocator, io, storage, storage, "session", database.bsonDatabase, database.metadataCollection, V6_ASSET_ID, true));
    try std.testing.expectEqualStrings("Failed to acquire write lock.", errors.lastErrorMessage());
    try std.testing.expect(test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ databaseDir, V6_ASSET_ID })));
}

//
// Points the config dir at a new directory holding a databases.toml that registers the path with an
// encryption key the vault does not have, so opening storage for the path fails. Returns the config dir it
// replaced, which restoreConfigDir puts back so later tests see the config dir they expect.
//
fn registerPathWithMissingKey(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8) !ConfigDirs {
    _ = try test_environment.setupEnvironment(io);
    // Copied, because setEnv frees the value the environment held.
    const previous = try allocator.dupe(u8, test_environment.getEnvironment().get("PHOTOSPHERE_CONFIG_DIR").?);
    const configDir = try temp_dirs.makeTempDir(allocator, io, "check-database-exists-config");
    // The path is a TOML literal string (single quotes) because a Windows path holds backslashes, which a basic
    // string reads as escapes. The Windows job failed in "checkDatabaseExists does not catch a storage error" with
    // "Invalid TOML document: unrecognized escape sequence" instead of the missing key message.
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), try std.fmt.allocPrint(allocator, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = '{s}'\nencryption_key = \"missing-enc\"\n", .{databasePath}));
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    return .{
        .previous = previous,
        .current = configDir,
    };
}

//
// The config dir a test replaced and the one it made.
//
const ConfigDirs = struct {
    // The config dir to put back.
    previous: []const u8,

    // The config dir the test made.
    current: []const u8,
};

//
// Puts the config dir back and removes the one the test made.
//
fn restoreConfigDir(io: std.Io, dirs: ConfigDirs) void {
    test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", dirs.previous) catch {};
    temp_dirs.removeTempDir(io, dirs.current);
}

test "checkDatabaseExists is true when the database has a merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    try std.testing.expect(try media_file_database.checkDatabaseExists(allocator, io, databaseDir));
}

test "checkDatabaseExists is false when the directory exists but holds no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "check-database-exists-empty");
    defer temp_dirs.removeTempDir(io, emptyDir);

    try std.testing.expect(!try media_file_database.checkDatabaseExists(allocator, io, emptyDir));
}

test "checkDatabaseExists is false when the path does not exist at all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "check-database-exists-missing");
    defer temp_dirs.removeTempDir(io, tempDir);

    try std.testing.expect(!try media_file_database.checkDatabaseExists(allocator, io, try std.fmt.allocPrint(allocator, "{s}/does-not-exist", .{tempDir})));
}

test "checkDatabaseExists does not catch a storage error: it is not reported as no database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    _ = try test_environment.setupEnvironment(io);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const dirs = try registerPathWithMissingKey(allocator, io, databaseDir);
    defer restoreConfigDir(io, dirs);

    try std.testing.expectError(error.Thrown, media_file_database.checkDatabaseExists(allocator, io, databaseDir));
    try std.testing.expectEqualStrings("Encryption key \"missing-enc\" not found in vault", errors.lastErrorMessage());
}

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
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
    _ = try helpers.setupEnvironment(io);
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
    const readme = try helpers.readFile(arena.allocator(), std.testing.io, helpers.TEST_DBS_DIR ++ "/v6/README.md");
    try std.testing.expectEqualStrings(readme, media_file_database.DATABASE_README_CONTENT);
}

test "createMediaFileDatabase creates the BSON database under .db/bson with the metadata collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const generators = try makeGenerators(allocator, io);
    const storage = try helpers.directoryStorage(allocator, io, helpers.TEST_DBS_DIR ++ "/v6");
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
    const io = std.testing.io;
    const generators = try makeGenerators(allocator, io);
    const dir = try helpers.makeTempDir(allocator, io, "create-database");
    defer helpers.removeTempDir(io, dir);
    const created = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());

    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, generators.uuidGenerator.uuidGenerator(), database.metadataCollection, "12345678-1234-4678-8abc-123456789abc");

    try std.testing.expectEqualStrings(media_file_database.DATABASE_README_CONTENT, try helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/README.md", .{dir})));
    try std.testing.expectEqualStrings("{}", try helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/.db/config.json", .{dir})));
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/hash_asc/tree.dat", .{dir})));
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/photoDate_desc/tree.dat", .{dir})));

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
    const io = std.testing.io;
    const generators = try makeGenerators(allocator, io);
    const dir = try helpers.makeTempDir(allocator, io, "create-database-id");
    defer helpers.removeTempDir(io, dir);
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
    const io = std.testing.io;
    const generators = try makeGenerators(allocator, io);
    const dir = try helpers.makeTempDir(allocator, io, "create-database-full");
    defer helpers.removeTempDir(io, dir);
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/something.txt", .{dir}), "x");
    const created = try node_api.open_storage.openStorage(allocator, io, dir, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try std.testing.expectError(error.Thrown, media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, generators.uuidGenerator.uuidGenerator(), database.metadataCollection, null));
    const expected = try std.fmt.allocPrint(allocator, "Cannot create new media file database in fs:{s}. This storage location already contains files! Please create your database in a new empty directory.", .{dir});
    try std.testing.expectEqualStrings(expected, errors.lastErrorMessage());
}

test "createReadme writes README.md and adds it to the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "create-readme");
    defer helpers.removeTempDir(io, dir);
    const storage = try helpers.directoryStorage(allocator, io, dir);
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
    const io = std.testing.io;
    const generators = try makeGenerators(allocator, io);
    const databaseDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.Io.Dir.cwd().deleteTree(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes", .{databaseDir}));
    const storage = try helpers.directoryStorage(allocator, io, databaseDir);
    const database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try media_file_database.ensureSortIndex(io, database.metadataCollection);
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/hash_asc/tree.dat", .{databaseDir})));
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/indexes/metadata/photoDate_desc/tree.dat", .{databaseDir})));
}

test "loadSortIndexes succeeds for an existing database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const generators = try makeGenerators(allocator, io);
    const storage = try helpers.directoryStorage(allocator, io, helpers.TEST_DBS_DIR ++ "/v6");
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

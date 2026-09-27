const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const media_file_database = node_api.media_file_database;
const repair = node_api.repair.repair;

//
// Valid BSON document id (uuid) for tests that hit the real collection implementation.
//
const ASSET_ID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";

//
// The generators given to the databases the tests create (TypeScript: TestUuidGenerator and TestTimestampProvider).
//
const Generators = struct {
    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // A fixed clock.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,
};

//
// A database created in a temporary directory (TypeScript: createStorage, createMediaFileDatabase and
// createDatabase in the test).
//
const TestDatabase = struct {
    // The temporary directory the database is in.
    dir: []const u8,

    // The storage of the database.
    assetStorage: @import("storage-zig").storage.IStorage,

    // The raw storage of the database.
    rawStorage: @import("storage-zig").storage.IStorage,

    // The BSON database and its metadata collection.
    database: media_file_database.IMediaFileDatabase,
};

//
// Creates a new database in a temporary directory.
//
fn createTestDatabase(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !TestDatabase {
    _ = try helpers.setupEnvironment(io);
    const generators = try allocator.create(Generators);
    generators.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
    };
    const dir = try helpers.makeTempDir(allocator, io, name);
    const created = try @import("storage-zig").storage_factory.createStorage(allocator, io, dir, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider());
    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, generators.uuidGenerator.uuidGenerator(), database.metadataCollection, null);
    return .{ .dir = dir, .assetStorage = created.storage, .rawStorage = created.rawStorage, .database = database };
}

test "bumps lastModifiedAt when records are repaired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const testDatabase = try createTestDatabase(allocator, io, "repair-bump");
    defer helpers.removeTempDir(io, testDatabase.dir);
    const assetStorage = testDatabase.assetStorage;

    //
    // Write an asset file and add it to the merkle tree without inserting a metadata record.
    // Repair should detect the missing record and synthesize one.
    //
    const assetFileName = "asset/" ++ ASSET_ID;
    try assetStorage.write(allocator, io, assetFileName, "application/octet-stream", "fake asset bytes for repair test");
    const assetInfo = (try assetStorage.info(allocator, io, assetFileName)).?;
    const stream = try assetStorage.readStream(allocator, io, assetFileName);
    const assetHash = try node_api.hash.computeHash(stream.reader());
    stream.destroy(io);

    var merkleTree = (try node_api.tree.loadMerkleTree(allocator, io, assetStorage)).?;
    merkleTree = try merkle_tree_zig.merkle_tree.addItem(allocator, &merkleTree, .{
        .name = assetFileName,
        .hash = &assetHash,
        .length = assetInfo.length,
        .lastModified = assetInfo.lastModified,
    });
    try node_api.tree.saveMerkleTree(allocator, io, &merkleTree, assetStorage);

    const result = try repair(allocator, io, assetStorage, testDatabase.rawStorage, assetStorage, testDatabase.database.bsonDatabase, testDatabase.database.metadataCollection, .{
        .source = testDatabase.dir,
    }, null);

    var found = false;
    for (result.recordsRepaired) |recordRepaired| {
        if (std.mem.eql(u8, recordRepaired, assetFileName)) {
            found = true;
        }
    }
    try std.testing.expect(found);

    const state = (try api.database_state.loadDatabaseState(allocator, io, testDatabase.rawStorage)).?;
    try std.testing.expect(state.lastModifiedAt != null);
    try std.testing.expect(!std.math.isNan(@import("serialization-zig").js_date.parseDate(state.lastModifiedAt.?)));
}

test "does not bump lastModifiedAt when no repairs were needed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const testDatabase = try createTestDatabase(allocator, io, "repair-no-bump");
    defer helpers.removeTempDir(io, testDatabase.dir);

    const before = try api.database_state.loadDatabaseState(allocator, io, testDatabase.rawStorage);
    try std.testing.expect(before == null or before.?.lastModifiedAt == null);

    const result = try repair(allocator, io, testDatabase.assetStorage, testDatabase.rawStorage, testDatabase.assetStorage, testDatabase.database.bsonDatabase, testDatabase.database.metadataCollection, .{
        .source = testDatabase.dir,
    }, null);

    try std.testing.expectEqual(@as(usize, 0), result.recordsRepaired.len);
    try std.testing.expectEqual(@as(usize, 0), result.repaired.len);

    const after = try api.database_state.loadDatabaseState(allocator, io, testDatabase.rawStorage);
    try std.testing.expect(after == null or after.?.lastModifiedAt == null);
}

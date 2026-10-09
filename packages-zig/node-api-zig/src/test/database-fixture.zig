//
// A new, empty media file database in a directory of its own, with the generators the tests give to the code under test.
// (No TypeScript counterpart: the TypeScript tests make the same database inline, with fs.mkdtempSync and createDatabase.)
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const media_file_database = node_api.media_file_database;

//
// The database and what the tests need to reach it.
//
pub const DatabaseFixture = struct {
    // The directory of the database.
    dir: []const u8,

    // The storage of the database's assets, and the BSON database over it.
    database: media_file_database.IMediaFileDatabase,

    // The raw storage of the database.
    rawStorage: storage_zig.storage.IStorage,

    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // The real clock.
    timestampProvider: utils.timestamp_provider.TimestampProvider,

    //
    // Creates the database.
    //
    pub fn init(fixture: *DatabaseFixture, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
        _ = try test_environment.setupEnvironment(io);
        fixture.uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
        fixture.timestampProvider = .{};
        fixture.dir = try temp_dirs.makeTempDir(allocator, io, name);
        const created = try node_api.open_storage.openStorage(allocator, io, fixture.dir, null, null);
        fixture.rawStorage = created.rawStorage;
        fixture.database = try media_file_database.createMediaFileDatabase(allocator, created.storage, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());
        try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, fixture.uuidGenerator.uuidGenerator(), fixture.database.metadataCollection, null);
    }

    //
    // Deletes the directory of the database.
    //
    pub fn deinit(fixture: *DatabaseFixture, io: std.Io) void {
        temp_dirs.removeTempDir(io, fixture.dir);
    }
};

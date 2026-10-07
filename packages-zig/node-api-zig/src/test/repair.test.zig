const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const console_capture = @import("console-capture.zig");
const test_environment = @import("test-environment.zig");
const progress_recorder = @import("progress-recorder.zig");
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
    _ = try test_environment.setupEnvironment(io);
    const generators = try allocator.create(Generators);
    generators.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
    };
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
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
    defer temp_dirs.removeTempDir(io, testDatabase.dir);
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
    defer temp_dirs.removeTempDir(io, testDatabase.dir);

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

//
// The id of the one asset in test/dbs/v6.
//
const V6_ASSET_ID = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// A copy of test/dbs/v6 opened for repair.
//
const IV6Copy = struct {
    // The directory of the copy.
    dir: []const u8,

    // Its storage.
    storage: @import("storage-zig").storage.IStorage,

    // Its BSON database and metadata collection.
    database: media_file_database.IMediaFileDatabase,
};

//
// Copies test/dbs/v6 into a temporary directory and opens it.
//
fn copyV6(allocator: std.mem.Allocator, io: std.Io) !IV6Copy {
    _ = try test_environment.setupEnvironment(io);
    const generators = try allocator.create(Generators);
    generators.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
    };
    const dir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    const storage = try test_files.directoryStorage(allocator, io, dir);
    return .{
        .dir = dir,
        .storage = storage,
        .database = try media_file_database.createMediaFileDatabase(allocator, storage, generators.uuidGenerator.uuidGenerator(), generators.timestampProvider.timestampProvider()),
    };
}

//
// Records the progress messages of a repair.
//
fn recordProgress(context: ?*anyopaque, message: ?[]const u8) void {
    const recorder: *progress_recorder.ProgressRecorder = @ptrCast(@alignCast(context.?));
    recorder.record(message.?);
}

//
// True when the list holds the name.
//
fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }
    return false;
}

test "restores a missing file and a corrupted one from the source database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const target = try copyV6(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(target.dir).?);
    const source = try copyV6(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(source.dir).?);

    // The asset goes missing and the display file is overwritten with other bytes.
    const assetPath = "asset/" ++ V6_ASSET_ID;
    const displayPath = "display/" ++ V6_ASSET_ID;
    try target.storage.deleteFile(allocator, io, assetPath);
    try target.storage.write(allocator, io, displayPath, "image/jpeg", "corrupted bytes");

    var recorder: progress_recorder.ProgressRecorder = .{ .allocator = allocator };
    const result = try repair(allocator, io, target.storage, target.storage, source.storage, target.database.bsonDatabase, target.database.metadataCollection, .{
        .source = source.dir,
    }, .{ .context = &recorder, .function = recordProgress });

    try std.testing.expect(containsName(result.repaired, assetPath));
    try std.testing.expect(containsName(result.repaired, displayPath));
    try std.testing.expectEqual(@as(usize, 0), result.unrepaired.len);
    try std.testing.expectEqualSlices(u8, try test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source.dir, displayPath })), try test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target.dir, displayPath })));
    try std.testing.expect(containsName(recorder.messages.items, "Repairing missing file: " ++ assetPath));
    try std.testing.expect(containsName(recorder.messages.items, "Repairing corrupted file: " ++ displayPath));

    // A repair was made, so the database is stamped as modified.
    try std.testing.expect((try api.database_state.loadDatabaseState(allocator, io, target.storage)).?.lastModifiedAt != null);
}

test "reports what the source cannot restore: a file it does not have, or has with other bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const target = try copyV6(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(target.dir).?);
    const source = try copyV6(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(source.dir).?);

    // The asset is missing from both, and the thumb is corrupted in both.
    const assetPath = "asset/" ++ V6_ASSET_ID;
    const thumbPath = "thumb/" ++ V6_ASSET_ID;
    try target.storage.deleteFile(allocator, io, assetPath);
    try source.storage.deleteFile(allocator, io, assetPath);
    try target.storage.write(allocator, io, thumbPath, "image/jpeg", "corrupted bytes");
    try source.storage.write(allocator, io, thumbPath, "image/jpeg", "other corrupted bytes");

    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    console_capture.captureStderr(&stderr_capture.writer);
    defer console_capture.endConsoleCapture();

    const result = try repair(allocator, io, target.storage, target.storage, source.storage, target.database.bsonDatabase, target.database.metadataCollection, .{
        .source = source.dir,
    }, null);

    try std.testing.expect(containsName(result.removed, assetPath));
    try std.testing.expect(containsName(result.modified, thumbPath));
    try std.testing.expect(containsName(result.unrepaired, assetPath));
    try std.testing.expect(containsName(result.unrepaired, thumbPath));
    try std.testing.expectEqual(@as(usize, 0), result.repaired.len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "Source file not found for repair: " ++ assetPath) != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "Source file hash mismatch for: " ++ thumbPath) != null);
}

test "a full repair hashes every file, and puts right the hash of a record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const target = try copyV6(allocator, io);
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(target.dir).?);

    // The record's hash is wrong.
    var updates: @import("serialization-zig").bson.BsonDocument = .empty;
    try updates.put(allocator, "hash", .{ .string = "0000" });
    try std.testing.expect(try target.database.metadataCollection.updateOne(io, V6_ASSET_ID, updates, .{}));
    try target.database.bsonDatabase.commit(io);

    // The thumb's bytes change while its size and modification time stay as the tree has them, which only a
    // full repair notices.
    const thumbName = "thumb/" ++ V6_ASSET_ID;
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, target.storage)).?;
    const thumbNode = merkle_tree_zig.merkle_tree.findItemInTree(filesTree.sort, thumbName).?;
    const thumbPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target.dir, thumbName });
    const thumb = try test_files.readFile(allocator, io, thumbPath);
    @memset(thumb[0..16], 0);
    try test_files.writeFile(io, thumbPath, thumb);
    const thumbFile = try std.Io.Dir.cwd().openFile(io, thumbPath, .{ .mode = .read_write });
    try thumbFile.setTimestamps(io, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(@as(i96, thumbNode.lastModified.?) * std.time.ns_per_ms) } });
    thumbFile.close(io);

    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    console_capture.captureStderr(&stderr_capture.writer);
    defer console_capture.endConsoleCapture();

    const result = try repair(allocator, io, target.storage, target.storage, target.storage, target.database.bsonDatabase, target.database.metadataCollection, .{
        .source = target.dir,
        .full = true,
    }, null);

    try std.testing.expectEqual(result.filesProcessed - 1, result.numUnmodified);
    try std.testing.expect(containsName(result.modified, thumbName));
    try std.testing.expect(containsName(result.recordsRepaired, "asset/" ++ V6_ASSET_ID));
    const record = (try target.database.metadataCollection.getOne(io, V6_ASSET_ID)).?;
    try std.testing.expect(!std.mem.eql(u8, "0000", record.get("hash").?.string));
}

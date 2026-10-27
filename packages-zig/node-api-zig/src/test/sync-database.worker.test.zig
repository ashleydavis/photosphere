const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const test_files = @import("test-files.zig");
const database_fixture = @import("database-fixture.zig");
const sync_helpers = @import("sync-test-helpers.zig");
const recording_task_context = @import("recording-task-context.zig");
const errors = utils.errors;
const syncDatabaseHandler = node_api.sync_database_worker.syncDatabaseHandler;
const replicateDatabaseHandler = node_api.replicate_database_worker.replicateDatabaseHandler;
const media_file_database = node_api.media_file_database;
const DatabaseFixture = database_fixture.DatabaseFixture;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;
const BsonDocument = serialization_zig.bson.BsonDocument;

//
// The id of the asset the origin and its replica both hold (record ids are UUIDs).
//
const SHARED_ASSET_ID = "00000000-0000-4000-8000-000000000001";

//
// The id of an asset only the origin holds.
//
const ORIGIN_ASSET_ID = "00000000-0000-4000-8000-000000000002";

//
// The id of an asset only the local database holds.
//
const LOCAL_ASSET_ID = "00000000-0000-4000-8000-000000000003";

//
// Builds the sync-database task data for a database path, with the job tag when one is given.
//
fn makeData(allocator: std.mem.Allocator, databasePath: []const u8, includeJob: bool) !std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "databasePath", .{ .string = databasePath });
    if (includeJob) {
        var job: std.json.ObjectMap = .empty;
        try job.put(allocator, "id", .{ .string = "sync:/fake/local" });
        try job.put(allocator, "name", .{ .string = "Syncing database" });
        try data.put(allocator, "job", .{ .object = job });
    }
    return .{ .object = data };
}

//
// Opens the database at a path, with a real clock and generators.
//
fn openDatabase(allocator: std.mem.Allocator, io: std.Io, log: ILog, databasePath: []const u8) !media_file_database.IMediaFileDatabase {
    const opened = try node_api.open_storage.openStorage(allocator, io, log, databasePath, null, null, null);
    const uuidGenerator = try allocator.create(utils.random_uuid_generator.RandomUuidGenerator);
    uuidGenerator.* = .{};
    const timestampProvider = try allocator.create(utils.timestamp_provider.TimestampProvider);
    timestampProvider.* = .{};
    return media_file_database.createMediaFileDatabase(allocator, opened.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
}

//
// Adds an asset record to the database at a path and stamps the database as modified, so that a sync does not take the two
// databases for identical.
//
fn addAsset(allocator: std.mem.Allocator, io: std.Io, log: ILog, databasePath: []const u8, assetId: []const u8) !void {
    const opened = try node_api.open_storage.openStorage(allocator, io, log, databasePath, null, null, null);
    const database = try openDatabase(allocator, io, log, databasePath);
    if (!try api.write_lock.acquireWriteLock(allocator, io, log, opened.rawStorage, "session-test", 3)) {
        return error.FailedToAcquireWriteLock;
    }
    var record = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = assetId },
        },
        .{
            .key = "origFileName",
            .value = .{ .string = try std.fmt.allocPrint(allocator, "{s}.jpg", .{assetId}) },
        },
        .{
            .key = "contentType",
            .value = .{ .string = "image/jpeg" },
        },
        .{
            .key = "photoDate",
            .value = .{ .string = "2026-01-01T00:00:00.000Z" },
        },
    });
    try database.metadataCollection.insertOne(io, log, &record, null);
    try database.bsonDatabase.commit(io, log);
    try node_api.tree.stampDatabaseModified(allocator, io, log, opened.storage, opened.rawStorage);
    try api.write_lock.releaseWriteLock(allocator, io, log, opened.rawStorage);
    try database.bsonDatabase.flush();
}

//
// Whether the database at a path holds a record with the given id, read with a database of its own so that nothing cached by
// the sync can answer.
//
fn hasAsset(allocator: std.mem.Allocator, io: std.Io, log: ILog, databasePath: []const u8, assetId: []const u8) !bool {
    const database = try openDatabase(allocator, io, log, databasePath);
    const record = try database.metadataCollection.getOne(io, log, assetId);
    try database.bsonDatabase.flush();
    return record != null;
}

//
// An origin database and a replica of it (the local database the handler syncs), which names the origin as its origin.//
const Scenario = struct {
    // The origin, whose assets the tests add to.
    origin: DatabaseFixture,

    // The path of the replica of the origin.
    localPath: []const u8,

    // The context the handler runs with.
    context: RecordingTaskContext,

    //
    // Creates the origin, holding one asset, and replicates it. The scenario must not move afterwards.
    //
    fn init(self: *Scenario, allocator: std.mem.Allocator, io: std.Io, log: ILog, name: []const u8, cancelAfterCalls: ?u64) !void {
        try self.origin.init(allocator, io, log, name);
        try self.context.init(allocator, cancelAfterCalls, null);
        try addAsset(allocator, io, log, self.origin.dir, SHARED_ASSET_ID);
        self.localPath = try std.fmt.allocPrint(allocator, "{s}-local", .{self.origin.dir});
        var replicateData: std.json.ObjectMap = .empty;
        try replicateData.put(allocator, "sourcePath", .{ .string = self.origin.dir });
        try replicateData.put(allocator, "destPath", .{ .string = self.localPath });
        try replicateData.put(allocator, "partial", .{ .bool = false });
        try replicateData.put(allocator, "force", .{ .bool = false });
        _ = try replicateDatabaseHandler(allocator, io, test_timers.timers(), log, .{ .object = replicateData }, self.context.taskContext());
        self.context.messages.clearRetainingCapacity();
    }

    //
    // Deletes the directories of the scenario.
    //
    fn deinit(self: *Scenario, io: std.Io, log: ILog) void {
        self.origin.deinit(io, log);
        temp_dirs.removeTempDir(io, self.localPath);
    }

    //
    // Runs the handler on the local database.
    //
    fn run(self: *Scenario, allocator: std.mem.Allocator, io: std.Io, log: ILog, includeJob: bool) !std.json.Value {
        return syncDatabaseHandler(allocator, io, test_timers.timers(), log, try makeData(allocator, self.localPath, includeJob), self.context.taskContext());
    }

    //
    // The types of the events sent so far, in order.
    //
    fn messageTypes(self: *Scenario, allocator: std.mem.Allocator) ![]const []const u8 {
        var types: std.ArrayList([]const u8) = .empty;
        for (self.context.messages.items) |message| {
            try types.append(allocator, message.object.get("type").?.string);
        }
        return types.items;
    }
};

//
// Checks the types of the messages a scenario's handler sent.
//
fn expectMessageTypes(allocator: std.mem.Allocator, scenario: *Scenario, expected: []const []const u8) !void {
    const actual = try scenario.messageTypes(allocator);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedType, actualType| {
        try std.testing.expectEqualStrings(expectedType, actualType);
    }
}

test "syncs the local database against its origin" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-both", null);
    defer scenario.deinit(io, log);
    // Source is the local database, target is the origin: each ends up with the other's record.
    try addAsset(allocator, io, log, scenario.origin.dir, ORIGIN_ASSET_ID);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);

    _ = try scenario.run(allocator, io, log, false);

    try std.testing.expect(try hasAsset(allocator, io, log, scenario.localPath, ORIGIN_ASSET_ID));
    try std.testing.expect(try hasAsset(allocator, io, log, scenario.origin.dir, LOCAL_ASSET_ID));
}

test "skips sync when the origin storage has no merkle tree" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-no-tree", null);
    defer scenario.deinit(io, log);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ scenario.origin.dir, ".db", "files.dat" }));

    _ = try scenario.run(allocator, io, log, false);

    // Nothing was synced, so the origin did not receive the local record.
    try std.testing.expect(!try hasAsset(allocator, io, log, scenario.origin.dir, LOCAL_ASSET_ID));
    try expectMessageTypes(allocator, &scenario, &.{"sync-skipped"});
}

test "reports a sync-skipped message when the origin storage has no merkle tree" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-skipped", null);
    defer scenario.deinit(io, log);
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ scenario.origin.dir, ".db", "files.dat" }));

    _ = try scenario.run(allocator, io, log, false);

    const message = scenario.context.messages.items[0].object;
    try std.testing.expectEqual(@as(u32, 3), message.count());
    try std.testing.expectEqualStrings("sync-skipped", message.get("type").?.string);
    try std.testing.expectEqualStrings(scenario.localPath, message.get("databasePath").?.string);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "origin not accessible ({s})", .{scenario.origin.dir}), message.get("reason").?.string);
}

test "reports a sync-skipped message when the database has no origin configured" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-no-origin", null);
    defer scenario.deinit(io, log);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);
    // The replica no longer names an origin.
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ scenario.localPath, ".db", "config.json" }));

    _ = try scenario.run(allocator, io, log, false);

    // The origin did not receive the local record, so no sync ran.
    try std.testing.expect(!try hasAsset(allocator, io, log, scenario.origin.dir, LOCAL_ASSET_ID));
    const message = scenario.context.messages.items[0].object;
    try std.testing.expectEqual(@as(usize, 1), scenario.context.messages.items.len);
    try std.testing.expectEqualStrings("sync-skipped", message.get("type").?.string);
    try std.testing.expectEqualStrings(scenario.localPath, message.get("databasePath").?.string);
    try std.testing.expectEqualStrings("no origin configured", message.get("reason").?.string);
}

test "sends sync-started and sync-completed around a sync that runs" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-started", null);
    defer scenario.deinit(io, log);
    // Only the local database has something new, so it pulls nothing and no batch is sent.
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);

    _ = try scenario.run(allocator, io, log, false);

    try expectMessageTypes(allocator, &scenario, &.{ "sync-started", "sync-completed" });
    try std.testing.expectEqualStrings(scenario.localPath, scenario.context.messages.items[0].object.get("databasePath").?.string);
}

test "the sync-completed message reports synced true when records were transferred" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-synced", null);
    defer scenario.deinit(io, log);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);

    _ = try scenario.run(allocator, io, log, false);

    const completed = (try scenario.context.messagesOfType("sync-completed"))[0].object;
    try std.testing.expectEqual(@as(u32, 3), completed.count());
    try std.testing.expectEqualStrings(scenario.localPath, completed.get("databasePath").?.string);
    try std.testing.expect(completed.get("synced").?.bool);
}

test "the sync-completed message reports synced false when both sides were already identical" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-identical", null);
    defer scenario.deinit(io, log);
    _ = try scenario.run(allocator, io, log, false);

    const completed = (try scenario.context.messagesOfType("sync-completed"))[0].object;
    try std.testing.expectEqualStrings(scenario.localPath, completed.get("databasePath").?.string);
    try std.testing.expect(!completed.get("synced").?.bool);
}

test "reports its job once the sync actually starts, carrying the tag it was queued with" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-job", null);
    defer scenario.deinit(io, log);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);

    _ = try scenario.run(allocator, io, log, true);

    const jobMessages = try scenario.context.messagesOfType("job-progress");
    try std.testing.expectEqual(@as(usize, 1), jobMessages.len);
    const job = jobMessages[0].object.get("job").?.object;
    try std.testing.expectEqualStrings("sync:/fake/local", job.get("id").?.string);
    try std.testing.expectEqualStrings("Syncing database", job.get("name").?.string);
    // No cancel source: the interface lists a sync but must not be able to stop it.
    try std.testing.expect(job.get("cancelSource") == null);
    // After sync-started, so the row appears only once the sync is really under way.
    const types = try scenario.messageTypes(allocator);
    try std.testing.expectEqualStrings("sync-started", types[0]);
    try std.testing.expectEqualStrings("job-progress", types[1]);
}

test "reports no job when the sync returns early without an origin" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-early-job", null);
    defer scenario.deinit(io, log);
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ scenario.localPath, ".db", "config.json" }));

    _ = try scenario.run(allocator, io, log, true);

    // A sync that did nothing must not put a row up saying it is running.
    try std.testing.expectEqual(@as(usize, 0), (try scenario.context.messagesOfType("job-progress")).len);
}

test "reports no job when the sync was queued without a tag" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-no-tag", null);
    defer scenario.deinit(io, log);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);

    _ = try scenario.run(allocator, io, log, false);

    try std.testing.expectEqual(@as(usize, 0), (try scenario.context.messagesOfType("job-progress")).len);
}

test "throws when databasePath is empty" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, syncDatabaseHandler(allocator, io, test_timers.timers(), log, try makeData(allocator, "", false), context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
    try std.testing.expectEqual(@as(usize, 0), context.messages.items.len);
}

test "sends the assets pulled from the origin as sync-batch messages of at most 50 changes, and reports the job after each" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-batches", null);
    defer scenario.deinit(io, log);
    // The origin gains 51 assets, so the local database pulls a full batch of 50 and a batch of 1.
    const originOpened = try node_api.open_storage.openStorage(allocator, io, log, scenario.origin.dir, null, null, null);
    const originDatabase = try openDatabase(allocator, io, log, scenario.origin.dir);
    for (0..51) |index| {
        var record = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "_id",
                .value = .{ .string = try std.fmt.allocPrint(allocator, "{x:0>2}000000-0000-4000-8000-000000000100", .{index}) },
            },
            .{
                .key = "origFileName",
                .value = .{ .string = try std.fmt.allocPrint(allocator, "pulled-{d}.jpg", .{index}) },
            },
            .{
                .key = "photoDate",
                .value = .{ .string = "2026-01-01T00:00:00.000Z" },
            },
        });
        try originDatabase.metadataCollection.insertOne(io, log, &record, null);
        // Committed after each record: a collection drops the shard it has just opened when eight others are waiting to be committed, and the record inserted into it is lost.
        try originDatabase.bsonDatabase.commit(io, log);
    }
    try originDatabase.bsonDatabase.commit(io, log);
    try node_api.tree.stampDatabaseModified(allocator, io, log, originOpened.storage, originOpened.rawStorage);
    try originDatabase.bsonDatabase.flush();

    _ = try scenario.run(allocator, io, log, true);

    const batches = try scenario.context.messagesOfType("sync-batch");
    try std.testing.expectEqual(@as(usize, 2), batches.len);
    try std.testing.expectEqual(@as(usize, 50), batches[0].object.get("added").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), batches[1].object.get("added").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), batches[0].object.get("updated").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), batches[0].object.get("deletedIds").?.array.items.len);
    try std.testing.expectEqualStrings(scenario.localPath, batches[0].object.get("databasePath").?.string);
    const firstAdded = batches[0].object.get("added").?.array.items[0].object;
    try std.testing.expect(std.mem.endsWith(u8, firstAdded.get("_id").?.string, "000000-0000-4000-8000-000000000100"));
    try std.testing.expect(std.mem.startsWith(u8, firstAdded.get("origFileName").?.string, "pulled-"));

    // The started row, then one report per batch with the running count.
    const jobMessages = try scenario.context.messagesOfType("job-progress");
    try std.testing.expectEqual(@as(usize, 3), jobMessages.len);
    try std.testing.expect(jobMessages[0].object.get("progressMessage") == null);
    try std.testing.expectEqualStrings("50 changes synced", jobMessages[1].object.get("progressMessage").?.string);
    try std.testing.expectEqualStrings("51 changes synced", jobMessages[2].object.get("progressMessage").?.string);
    try expectMessageTypes(allocator, &scenario, &.{ "sync-started", "job-progress", "sync-batch", "job-progress", "sync-batch", "job-progress", "sync-completed" });
}

test "sends the id of an asset the local database deleted, that the origin still holds, as a deleted id" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-deleted", null);
    defer scenario.deinit(io, log);
    const localOpened = try node_api.open_storage.openStorage(allocator, io, log, scenario.localPath, null, null, null);
    const localDatabase = try openDatabase(allocator, io, log, scenario.localPath);
    try media_file_database.removeAsset(allocator, io, log, localOpened.storage, localOpened.rawStorage, "session-test", localDatabase.bsonDatabase, localDatabase.metadataCollection, SHARED_ASSET_ID, true);
    try localDatabase.bsonDatabase.flush();
    // The local database also gains an asset, so the two sides no longer hold the same content and the sync does not stop early.
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);

    _ = try scenario.run(allocator, io, log, false);

    const batches = try scenario.context.messagesOfType("sync-batch");
    try std.testing.expectEqual(@as(usize, 1), batches.len);
    try std.testing.expectEqual(@as(usize, 0), batches[0].object.get("added").?.array.items.len);
    const deletedIds = batches[0].object.get("deletedIds").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), deletedIds.len);
    try std.testing.expectEqualStrings(SHARED_ASSET_ID, deletedIds[0].string);
}

test "throws the error of a sync that fails, after sending sync-started" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-fails", null);
    defer scenario.deinit(io, log);
    try addAsset(allocator, io, log, scenario.localPath, LOCAL_ASSET_ID);
    // The origin's merkle tree file exists but cannot be read.
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ scenario.origin.dir, ".db", "files.dat" }), "not a merkle tree");

    try std.testing.expectError(error.Thrown, scenario.run(allocator, io, log, false));

    try expectMessageTypes(allocator, &scenario, &.{"sync-started"});
}

test "sends an asset the origin changed, that the local database also holds, as an updated asset" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    var scenario: Scenario = undefined;
    try scenario.init(allocator, io, log, "sync-database-updated", null);
    defer scenario.deinit(io, log);
    // The origin changes the record both sides hold.
    const originOpened = try node_api.open_storage.openStorage(allocator, io, log, scenario.origin.dir, null, null, null);
    const originDatabase = try openDatabase(allocator, io, log, scenario.origin.dir);
    const updates = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "description",
            .value = .{ .string = "Changed at the origin" },
        },
    });
    try std.testing.expect(try originDatabase.metadataCollection.updateOne(io, log, SHARED_ASSET_ID, updates, .{}));
    try originDatabase.bsonDatabase.commit(io, log);
    try node_api.tree.stampDatabaseModified(allocator, io, log, originOpened.storage, originOpened.rawStorage);
    try originDatabase.bsonDatabase.flush();

    _ = try scenario.run(allocator, io, log, false);

    const batches = try scenario.context.messagesOfType("sync-batch");
    try std.testing.expectEqual(@as(usize, 1), batches.len);
    try std.testing.expectEqual(@as(usize, 0), batches[0].object.get("added").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), batches[0].object.get("deletedIds").?.array.items.len);
    const updated = batches[0].object.get("updated").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqualStrings(SHARED_ASSET_ID, updated[0].object.get("_id").?.string);
    try std.testing.expectEqualStrings("Changed at the origin", updated[0].object.get("description").?.string);
}

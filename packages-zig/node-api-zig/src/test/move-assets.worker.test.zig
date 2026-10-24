const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const database_fixture = @import("database-fixture.zig");
const sequence_uuid_generator = @import("sequence-uuid-generator.zig");
const test_task_context = @import("test-task-context.zig");
const moveAssetsHandler = node_api.move_assets_worker.moveAssetsHandler;
const IMoveAssetsResult = node_api.move_assets_worker.IMoveAssetsResult;
const media_file_database = node_api.media_file_database;
const DatabaseFixture = database_fixture.DatabaseFixture;
const SequenceUuidGenerator = sequence_uuid_generator.SequenceUuidGenerator;
const TestTaskContext = test_task_context.TestTaskContext;
const errors = utils.errors;

// Record ids must be uuids.
const ASSET_ONE = "11111111-1111-4111-8111-111111111111";
const ASSET_TWO = "22222222-2222-4222-8222-222222222222";
const NEW_ASSET_ID = "33333333-3333-4333-8333-333333333333";
const NEW_ONE = "44444444-4444-4444-8444-444444444444";
const NEW_TWO = "55555555-5555-4555-8555-555555555555";
const BsonDocument = serialization_zig.bson.BsonDocument;

//
// These tests build two real databases in directories of their own, put the assets
// the test describes in the source, and check what ended up in each.
//

//
// A log that counts the messages loadSortIndexes writes.
//
const LoadCountingLog = struct {
    // How many "Loaded existing media file database" messages were logged.
    loadedCount: usize = 0,

    // The log that was active before this one was installed.
    previousLog: ?utils.log.ILog = null,

    //
    // Makes this the global log.
    //
    fn install(self: *LoadCountingLog) void {
        self.previousLog = utils.log.currentLog();
        utils.log.setLog(.{
            .ptr = self,
            .vtable = &vtable,
        });
    }

    //
    // Restores the log that was active before install.
    //
    fn uninstall(self: *LoadCountingLog) void {
        utils.log.setLog(self.previousLog.?);
    }

    //
    // The ILog functions of this log.
    //
    const vtable: utils.log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = countVerbose,
        .@"error" = ignoreMessage,
        .exception = ignoreException,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = ignoreTool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = logDetails,
    };

    //
    // Counts a verbose message when loadSortIndexes wrote it.
    //
    fn countVerbose(ptr: *anyopaque, message: []const u8) void {
        const self: *LoadCountingLog = @ptrCast(@alignCast(ptr));
        if (std.mem.startsWith(u8, message, "Loaded existing media file database from: ")) {
            self.loadedCount += 1;
        }
    }

    //
    // Drops a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Drops an exception.
    //
    fn ignoreException(_: *anyopaque, _: []const u8, _: anyerror) void {}

    //
    // Drops tool output.
    //
    fn ignoreTool(ptr: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
        _ = ptr;
        _ = toolName;
        _ = data;
    }

    //
    // Verbose logging is off.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    //
    // Returns the placeholder log details.
    //
    fn logDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return utils.log.noLogDetails;
    }
};

//
// The source and destination databases and the context the handler runs with.
//
const World = struct {
    // The source database.
    source: DatabaseFixture,

    // The destination database.
    dest: DatabaseFixture,

    // Hands the new asset ids to the handler.
    newIds: SequenceUuidGenerator,

    // The task context.
    testContext: TestTaskContext,

    //
    // Creates the databases. The handler is given the new ids in order.
    //
    fn init(world: *World, allocator: std.mem.Allocator, io: std.Io, newIds: []const []const u8) !void {
        try world.source.init(allocator, io, "move-assets-source");
        try world.dest.init(allocator, io, "move-assets-dest");
        world.newIds = .{
            .ids = newIds,
        };
        world.testContext.init(world.newIds.uuidGenerator());
    }

    //
    // Deletes the directories.
    //
    fn deinit(world: *World, io: std.Io) void {
        world.source.deinit(io);
        world.dest.deinit(io);
    }

    //
    // Puts an asset's metadata record in the source database.
    //
    fn addSourceMetadata(world: *World, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8) !void {
        var record: BsonDocument = .empty;
        try record.put(allocator, "_id", .{ .string = assetId });
        try record.put(allocator, "hash", .{ .string = "abc123" });
        try record.put(allocator, "photoDate", .{ .string = "2024-01-01" });
        try world.source.database.metadataCollection.insertOne(io, &record, null);
        try world.source.database.bsonDatabase.commit(io);
    }

    //
    // Puts an asset file in the source database, recorded in its merkle tree.
    //
    fn addSourceFile(world: *World, allocator: std.mem.Allocator, io: std.Io, assetType: []const u8, assetId: []const u8, content: []const u8) !void {
        try media_file_database.writeAsset(allocator, io, world.source.database.assetStorage, world.source.rawStorage, "test-session", assetId, assetType, null, content);
    }

    //
    // Runs the handler for the asset ids.
    //
    fn run(world: *World, allocator: std.mem.Allocator, io: std.Io, assetIds: []const []const u8) !IMoveAssetsResult {
        var items: std.json.Array = .init(allocator);
        for (assetIds) |assetId| {
            try items.append(.{ .string = assetId });
        }
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "sourceDatabasePath", .{ .string = world.source.dir });
        try object.put(allocator, "destDatabasePath", .{ .string = world.dest.dir });
        try object.put(allocator, "assetIds", .{ .array = items });
        const output = try moveAssetsHandler(allocator, io, test_timers.timers(), .{ .object = object }, world.testContext.context.taskContext());
        return std.json.parseFromValueLeaky(IMoveAssetsResult, allocator, output, .{});
    }

    //
    // Opens a database afresh from its storage, so that what the handler committed is read back from disk.
    //
    fn reopen(fixture: *DatabaseFixture, allocator: std.mem.Allocator, uuidGenerator: utils.uuid_generator.IUuidGenerator) !media_file_database.IMediaFileDatabase {
        var timestampProvider: utils.timestamp_provider.TimestampProvider = .{};
        return media_file_database.createMediaFileDatabase(allocator, fixture.database.assetStorage, uuidGenerator, timestampProvider.timestampProvider());
    }
};

test "opens source storage with sourceDatabasePath" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    // The record that was in the source database is no longer there, so the handler read and emptied that one.
    const sourceDb = try World.reopen(&world.source, allocator, world.source.uuidGenerator.uuidGenerator());
    try std.testing.expect(try sourceDb.metadataCollection.getOne(io, ASSET_ONE) == null);
}

test "opens dest storage with destDatabasePath" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    const destDb = try World.reopen(&world.dest, allocator, world.dest.uuidGenerator.uuidGenerator());
    try std.testing.expect(try destDb.metadataCollection.getOne(io, NEW_ASSET_ID) != null);
}

test "calls loadSortIndexes for both source and dest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);
    var countingLog: LoadCountingLog = .{};
    countingLog.install();
    defer countingLog.uninstall();

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    try std.testing.expectEqual(@as(usize, 2), countingLog.loadedCount);
}

test "throws when asset is not found in source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);

    try std.testing.expectError(error.Thrown, world.run(allocator, io, &.{ASSET_ONE}));
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "Asset \"" ++ ASSET_ONE ++ "\" not found in source database \"{s}\".", .{world.source.dir}),
        errors.lastErrorMessage(),
    );
}

test "skips writing binary file when it does not exist in source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    const destStorage = world.dest.database.assetStorage;
    try std.testing.expect(!try destStorage.fileExists(allocator, io, "thumb/" ++ NEW_ASSET_ID));
    try std.testing.expect(!try destStorage.fileExists(allocator, io, "display/" ++ NEW_ASSET_ID));
    try std.testing.expect(!try destStorage.fileExists(allocator, io, "asset/" ++ NEW_ASSET_ID));
}

test "copies existing binary files to destination via writeAssetStreamVerified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);
    try world.addSourceFile(allocator, io, "thumb", ASSET_ONE, "the thumbnail bytes");

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    const destStorage = world.dest.database.assetStorage;
    const copied = (try destStorage.read(allocator, io, "thumb/" ++ NEW_ASSET_ID)).?;
    try std.testing.expectEqualStrings("the thumbnail bytes", copied);
    try std.testing.expect(!try destStorage.fileExists(allocator, io, "asset/" ++ NEW_ASSET_ID));
}

test "copies the thumbnail, the display copy and the original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);
    try world.addSourceFile(allocator, io, "thumb", ASSET_ONE, "thumb bytes");
    try world.addSourceFile(allocator, io, "display", ASSET_ONE, "display bytes");
    try world.addSourceFile(allocator, io, "asset", ASSET_ONE, "original bytes");

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    const destStorage = world.dest.database.assetStorage;
    try std.testing.expectEqualStrings("thumb bytes", (try destStorage.read(allocator, io, "thumb/" ++ NEW_ASSET_ID)).?);
    try std.testing.expectEqualStrings("display bytes", (try destStorage.read(allocator, io, "display/" ++ NEW_ASSET_ID)).?);
    try std.testing.expectEqualStrings("original bytes", (try destStorage.read(allocator, io, "asset/" ++ NEW_ASSET_ID)).?);
}

test "writes metadata to destination with new asset ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    const destDb = try World.reopen(&world.dest, allocator, world.dest.uuidGenerator.uuidGenerator());
    const record = (try destDb.metadataCollection.getOne(io, NEW_ASSET_ID)).?;
    try std.testing.expectEqualStrings(NEW_ASSET_ID, record.get("_id").?.string);
    try std.testing.expectEqualStrings("abc123", record.get("hash").?.string);
    try std.testing.expectEqualStrings("2024-01-01", record.get("photoDate").?.string);
    try std.testing.expect(try destDb.metadataCollection.getOne(io, ASSET_ONE) == null);
}

test "commits the dest bsonDatabase after writing metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    // A database opened afresh reads only what was committed to disk.
    const destDb = try World.reopen(&world.dest, allocator, world.dest.uuidGenerator.uuidGenerator());
    try std.testing.expect(try destDb.metadataCollection.getOne(io, NEW_ASSET_ID) != null);
}

test "hard-deletes the original asset from source after copying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);
    try world.addSourceFile(allocator, io, "thumb", ASSET_ONE, "the thumbnail bytes");

    _ = try world.run(allocator, io, &.{ASSET_ONE});

    const sourceStorage = world.source.database.assetStorage;
    try std.testing.expect(!try sourceStorage.fileExists(allocator, io, "thumb/" ++ ASSET_ONE));
    const sourceDb = try World.reopen(&world.source, allocator, world.source.uuidGenerator.uuidGenerator());
    try std.testing.expect(try sourceDb.metadataCollection.getOne(io, ASSET_ONE) == null);
    // The id is recorded as deleted, because the handler removes the asset with recordDeleted set.
    const sourceTree = (try node_api.tree.loadMerkleTree(allocator, io, sourceStorage)).?;
    const deletedAssetIds = sourceTree.databaseMetadata.?.get("deletedAssetIds").?.array;
    try std.testing.expectEqual(@as(usize, 1), deletedAssetIds.len);
    try std.testing.expectEqualStrings(ASSET_ONE, deletedAssetIds[0].string);
}

test "returns movedCount equal to the number of asset IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{ NEW_ONE, NEW_TWO });
    defer world.deinit(io);
    try world.addSourceMetadata(allocator, io, ASSET_ONE);
    try world.addSourceMetadata(allocator, io, ASSET_TWO);

    const result = try world.run(allocator, io, &.{ ASSET_ONE, ASSET_TWO });

    try std.testing.expectEqual(@as(u64, 2), result.movedCount);
    const destDb = try World.reopen(&world.dest, allocator, world.dest.uuidGenerator.uuidGenerator());
    try std.testing.expect(try destDb.metadataCollection.getOne(io, NEW_ONE) != null);
    try std.testing.expect(try destDb.metadataCollection.getOne(io, NEW_TWO) != null);
}

test "throws a descriptive error when the task data is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io, &.{NEW_ASSET_ID});
    defer world.deinit(io);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "sourceDatabasePath", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, moveAssetsHandler(allocator, io, test_timers.timers(), .{ .object = object }, world.testContext.context.taskContext()));
    try std.testing.expectEqualStrings("The move-assets task data is not valid: sourceDatabasePath and destDatabasePath must be strings, and assetIds must be a list of strings", errors.lastErrorMessage());
}

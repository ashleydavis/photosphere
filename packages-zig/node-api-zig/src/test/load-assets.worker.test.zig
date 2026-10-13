const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy-core").task_queue;
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const database_fixture = @import("database-fixture.zig");
const recording_task_context = @import("recording-task-context.zig");
const recording_queue_backend = @import("recording-queue-backend.zig");
const errors = utils.errors;
const loadAssetsHandler = node_api.load_assets_worker.loadAssetsHandler;
const replicateDatabaseHandler = node_api.replicate_database_worker.replicateDatabaseHandler;
const DatabaseFixture = database_fixture.DatabaseFixture;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;
const RecordingQueueBackend = recording_queue_backend.RecordingQueueBackend;
const BsonDocument = serialization_zig.bson.BsonDocument;
const TaskPriority = task_queue_zig.types.TaskPriority;

//
// Builds the load-assets task data for a database path, with the job tag when one is given.
//
fn makeData(allocator: std.mem.Allocator, databasePath: []const u8, includeJob: bool) !std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "databasePath", .{ .string = databasePath });
    if (includeJob) {
        var job: std.json.ObjectMap = .empty;
        try job.put(allocator, "id", .{ .string = "load:/test/db" });
        try job.put(allocator, "name", .{ .string = "Loading assets" });
        try job.put(allocator, "cancelSource", .{ .string = "/test/db" });
        try data.put(allocator, "job", .{ .object = job });
    }
    return .{ .object = data };
}

//
// The id of the asset at an index (record ids are UUIDs).
//
fn assetIdFor(allocator: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "00000000-0000-4000-8000-{x:0>12}", .{index});
}

//
// Inserts the given number of assets into a database, each with a photo date a day after the one before and with EXIF
// properties (which the handler must not send), and commits them.
//
fn insertAssets(allocator: std.mem.Allocator, io: std.Io, fixture: *DatabaseFixture, assetCount: usize) !void {
    for (0..assetCount) |index| {
        var properties = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "exif",
                .value = .{ .string = "large exif object" },
            },
        });
        _ = &properties;
        var record = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "_id",
                .value = .{ .string = try assetIdFor(allocator, index) },
            },
            .{
                .key = "origFileName",
                .value = .{ .string = try std.fmt.allocPrint(allocator, "photo-{d}.jpg", .{index}) },
            },
            .{
                .key = "contentType",
                .value = .{ .string = "image/jpeg" },
            },
            .{
                .key = "width",
                .value = .{ .number = 640 },
            },
            .{
                .key = "photoDate",
                .value = .{ .string = try std.fmt.allocPrint(allocator, "2026-01-{d:0>2}T00:00:00.000Z", .{index + 1}) },
            },
            .{
                .key = "properties",
                .value = .{ .document = properties },
            },
        });
        try fixture.database.metadataCollection.insertOne(io, &record, null);
    }
    try fixture.database.bsonDatabase.commit(io);
    try fixture.database.bsonDatabase.flush();
}

//
// Replicates a database as a partial replica, which names the database as its origin, and returns the replica's path.
//
fn makePartialReplica(allocator: std.mem.Allocator, io: std.Io, sourcePath: []const u8, context: *RecordingTaskContext) ![]const u8 {
    const replicaPath = try std.fmt.allocPrint(allocator, "{s}-replica", .{sourcePath});
    var replicateData: std.json.ObjectMap = .empty;
    try replicateData.put(allocator, "sourcePath", .{ .string = sourcePath });
    try replicateData.put(allocator, "destPath", .{ .string = replicaPath });
    try replicateData.put(allocator, "partial", .{ .bool = true });
    try replicateData.put(allocator, "force", .{ .bool = false });
    _ = try replicateDatabaseHandler(allocator, io, .{ .object = replicateData }, context.taskContext());
    return replicaPath;
}

//
// Installs a backend that records the tasks added to it, for the test to read, and puts the test environment's backend
// back when the test ends.
//
const BackendInstaller = struct {
    // The backend.
    backend: RecordingQueueBackend,

    //
    // Installs the backend.
    //
    fn install(self: *BackendInstaller, allocator: std.mem.Allocator) void {
        self.backend = RecordingQueueBackend.init(allocator);
        task_queue_zig.queue_backend.setQueueBackend(self.backend.queueBackend());
    }

    //
    // Puts the test environment's backend back.
    //
    fn uninstall(self: *BackendInstaller) void {
        _ = self;
        test_environment.restoreQueueBackend();
    }
};

test "queues the thumbnail prefetch of a partial database as background work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-partial");
    defer fixture.deinit(io);
    try insertAssets(allocator, io, &fixture, 3);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const replicaPath = try makePartialReplica(allocator, io, fixture.dir, &context);
    defer temp_dirs.removeTempDir(io, replicaPath);
    var installer: BackendInstaller = undefined;
    installer.install(allocator);
    defer installer.uninstall();

    _ = try loadAssetsHandler(allocator, io, try makeData(allocator, replicaPath, false), context.taskContext());

    try std.testing.expectEqual(@as(usize, 1), installer.backend.countOfType("prefetch-database"));
    // Explicitly background: without it the prefetch inherits this task's interactive priority
    // and holds a worker for as long as it takes to pull down every thumbnail.
    try std.testing.expectEqual(TaskPriority.Background, installer.backend.addedTasks.items[0].priority.?);
}

test "queues no prefetch for a database that is not partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-full");
    defer fixture.deinit(io);
    try insertAssets(allocator, io, &fixture, 3);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    var installer: BackendInstaller = undefined;
    installer.install(allocator);
    defer installer.uninstall();

    _ = try loadAssetsHandler(allocator, io, try makeData(allocator, fixture.dir, false), context.taskContext());

    try std.testing.expectEqual(@as(usize, 0), installer.backend.countOfType("prefetch-database"));
}

test "reports its job as it streams assets, carrying the tag it was queued with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-job");
    defer fixture.deinit(io);
    try insertAssets(allocator, io, &fixture, 3);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    _ = try loadAssetsHandler(allocator, io, try makeData(allocator, fixture.dir, true), context.taskContext());

    const jobMessages = try context.messagesOfType("job-progress");
    try std.testing.expectEqual(@as(usize, 1), jobMessages.len);
    const job = jobMessages[0].object.get("job").?.object;
    try std.testing.expectEqualStrings("load:/test/db", job.get("id").?.string);
    try std.testing.expectEqualStrings("Loading assets", job.get("name").?.string);
    // The source the load was queued under, so Cancel stops this load and nothing else.
    try std.testing.expectEqualStrings("/test/db", job.get("cancelSource").?.string);
    try std.testing.expectEqualStrings("3 assets loaded", jobMessages[0].object.get("progressMessage").?.string);
}

test "reports no job when the load was queued without a tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-no-job");
    defer fixture.deinit(io);
    try insertAssets(allocator, io, &fixture, 3);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    _ = try loadAssetsHandler(allocator, io, try makeData(allocator, fixture.dir, false), context.taskContext());

    try std.testing.expectEqual(@as(usize, 0), (try context.messagesOfType("job-progress")).len);
}

test "throws when databasePath is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, loadAssetsHandler(allocator, io, try makeData(allocator, "", false), context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "sends the assets as an asset-page message holding only the fields the gallery needs, newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-page");
    defer fixture.deinit(io);
    try insertAssets(allocator, io, &fixture, 3);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    const result = try loadAssetsHandler(allocator, io, try makeData(allocator, fixture.dir, false), context.taskContext());

    try std.testing.expectEqual(@as(i64, 3), result.object.get("totalAssets").?.integer);
    try std.testing.expectEqual(@as(i64, 1), result.object.get("batchesSent").?.integer);
    const pages = try context.messagesOfType("asset-page");
    try std.testing.expectEqual(@as(usize, 1), pages.len);
    try std.testing.expectEqualStrings(fixture.dir, pages[0].object.get("databasePath").?.string);
    const batch = pages[0].object.get("batch").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), batch.len);
    try std.testing.expectEqualStrings(try assetIdFor(allocator, 2), batch[0].object.get("_id").?.string);
    try std.testing.expectEqualStrings(try assetIdFor(allocator, 1), batch[1].object.get("_id").?.string);
    try std.testing.expectEqualStrings(try assetIdFor(allocator, 0), batch[2].object.get("_id").?.string);
    try std.testing.expectEqualStrings("photo-2.jpg", batch[0].object.get("origFileName").?.string);
    try std.testing.expectEqual(@as(i64, 640), batch[0].object.get("width").?.integer);
    // The EXIF properties are left out, and so is any field the record does not hold.
    try std.testing.expect(batch[0].object.get("properties") == null);
    try std.testing.expect(batch[0].object.get("micro") == null);
}

test "sends nothing and returns zero counts when the task is already cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-cancelled");
    defer fixture.deinit(io);
    try insertAssets(allocator, io, &fixture, 3);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 0, null);

    const result = try loadAssetsHandler(allocator, io, try makeData(allocator, fixture.dir, false), context.taskContext());

    try std.testing.expectEqual(@as(i64, 0), result.object.get("totalAssets").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.object.get("batchesSent").?.integer);
    try std.testing.expectEqual(@as(usize, 0), (try context.messagesOfType("asset-page")).len);
}

test "sends no pages for a database with no assets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    _ = try test_environment.setupEnvironment(io);
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "load-assets-empty");
    defer fixture.deinit(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    const result = try loadAssetsHandler(allocator, io, try makeData(allocator, fixture.dir, false), context.taskContext());

    try std.testing.expectEqual(@as(i64, 0), result.object.get("totalAssets").?.integer);
    try std.testing.expectEqual(@as(i64, 0), result.object.get("batchesSent").?.integer);
    try std.testing.expectEqual(@as(usize, 0), (try context.messagesOfType("asset-page")).len);
}

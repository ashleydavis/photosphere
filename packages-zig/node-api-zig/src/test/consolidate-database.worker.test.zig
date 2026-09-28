const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const errors = utils.errors;
const consolidateDatabaseHandler = node_api.consolidate_database_worker.consolidateDatabaseHandler;
const TaskContext = task_queue_zig.task_context.TaskContext;

//
// The thumbnail of the one asset in test/dbs/1-asset-2, which a database consolidated into it pulls down.
//
const REMOTE_THUMB_PATH = "thumb/476dffbb-af9e-4cda-8006-b02f3851e86c";

//
// A task context that records the messages sent through it (TypeScript: makeContext, whose sendMessage pushes to
// sentMessages).
//
const RecordingContext = struct {
    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // Deterministic time.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The task context.
    context: TaskContext,

    // The messages a run streamed, as JSON text, so a test can check what the interface would have been told.
    sentMessages: std.ArrayList([]const u8),

    // Allocates the recorded messages.
    allocator: std.mem.Allocator,

    //
    // Records a message.
    //
    fn sendMessage(context: ?*anyopaque, message: std.json.Value) void {
        const self: *RecordingContext = @ptrCast(@alignCast(context.?));
        const text = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch {
            return;
        };
        self.sentMessages.append(self.allocator, text) catch {};
    }
};

//
// A task context that records the messages sent through it.
//
fn makeContext(allocator: std.mem.Allocator, io: std.Io) !*RecordingContext {
    _ = try helpers.setupEnvironment(io);
    const recording = try allocator.create(RecordingContext);
    recording.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
        .context = undefined,
        .sentMessages = .empty,
        .allocator = allocator,
    };
    recording.context = TaskContext.init(recording.uuidGenerator.uuidGenerator(), recording.timestampProvider.timestampProvider(), "session-1", "consolidate-task-id", .{
        .context = recording,
        .function = RecordingContext.sendMessage,
    }, 10);
    return recording;
}

//
// The directories of a test: a copy of one test database as the local database and a copy of another as the remote.
//
const Directories = struct {
    // The directory holding the local database.
    localRoot: []const u8,

    // The directory holding the remote database.
    remoteRoot: []const u8,

    // The local database.
    local: []const u8,

    // The remote database.
    remote: []const u8,
};

//
// Copies the local and remote test databases.
//
fn makeDirectories(allocator: std.mem.Allocator, io: std.Io, localName: []const u8, remoteName: []const u8) !Directories {
    const local = try helpers.copyTestDatabase(allocator, io, localName);
    const remote = try helpers.copyTestDatabase(allocator, io, remoteName);
    return .{
        .localRoot = std.fs.path.dirname(local).?,
        .remoteRoot = std.fs.path.dirname(remote).?,
        .local = local,
        .remote = remote,
    };
}

//
// Deletes the directories of a test.
//
fn removeDirectories(io: std.Io, dirs: Directories) void {
    helpers.removeTempDir(io, dirs.localRoot);
    helpers.removeTempDir(io, dirs.remoteRoot);
}

//
// The payload a run is asked for (TypeScript: VALID_DATA, with the paths of the test's databases).
//
fn makeData(allocator: std.mem.Allocator, databasePath: []const u8, remotePath: []const u8) !std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "databasePath", .{ .string = databasePath });
    try data.put(allocator, "remotePath", .{ .string = remotePath });
    try data.put(allocator, "sessionId", .{ .string = "session-1" });
    return .{ .object = data };
}

//
// The path of a file in a directory.
//
fn pathIn(allocator: std.mem.Allocator, dir: []const u8, fileName: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, fileName });
}

//
// Reads the merkle tree file of a database, which consolidation rewrites when it acts on the database.
//
fn readTreeFile(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8) ![]const u8 {
    return helpers.readFile(allocator, io, try pathIn(allocator, databaseDir, ".db/files.dat"));
}

test "a missing database path is refused rather than acted on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io, "1-asset", "1-asset-2");
    defer removeDirectories(io, dirs);
    const remoteTree = try readTreeFile(allocator, io, dirs.remote);

    try std.testing.expectError(error.Thrown, consolidateDatabaseHandler(allocator, io, try makeData(allocator, "", dirs.remote), recording.context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
    try std.testing.expectEqualStrings(remoteTree, try readTreeFile(allocator, io, dirs.remote));
}

test "a missing remote path is refused rather than acted on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io, "1-asset", "1-asset-2");
    defer removeDirectories(io, dirs);
    const localTree = try readTreeFile(allocator, io, dirs.local);

    try std.testing.expectError(error.Thrown, consolidateDatabaseHandler(allocator, io, try makeData(allocator, dirs.local, ""), recording.context.taskContext()));
    try std.testing.expectEqualStrings("remotePath is required", errors.lastErrorMessage());
    try std.testing.expectEqualStrings(localTree, try readTreeFile(allocator, io, dirs.local));
}

test "a remote with no database in it is refused, rather than consolidated into nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io, "1-asset", "1-asset-2");
    defer removeDirectories(io, dirs);
    const localTree = try readTreeFile(allocator, io, dirs.local);
    const emptyRemote = try pathIn(allocator, dirs.remoteRoot, "empty");

    try std.testing.expectError(error.Thrown, consolidateDatabaseHandler(allocator, io, try makeData(allocator, dirs.local, emptyRemote), recording.context.taskContext()));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "no database at") != null);
    try std.testing.expectEqualStrings(localTree, try readTreeFile(allocator, io, dirs.local));
}

test "returns what the consolidation did" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);

    // test/dbs/50-assets holds the one photo of test/dbs/1-asset-2 and 59 others, 10 of which have no metadata
    // record and are skipped.
    const dirs = try makeDirectories(allocator, io, "50-assets", "1-asset-2");
    defer removeDirectories(io, dirs);

    const result = try consolidateDatabaseHandler(allocator, io, try makeData(allocator, dirs.local, dirs.remote), recording.context.taskContext());

    try std.testing.expectEqual(@as(i64, 49), result.object.get("pushedCount").?.integer);
    try std.testing.expectEqual(@as(i64, 1), result.object.get("alreadyPresentCount").?.integer);
}

test "pulls the remote's records and thumbnails down afterwards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io, "1-asset", "1-asset-2");
    defer removeDirectories(io, dirs);

    _ = try consolidateDatabaseHandler(allocator, io, try makeData(allocator, dirs.local, dirs.remote), recording.context.taskContext());

    // Without this the local database is a partial replica with nothing local to show, so the
    // gallery is empty until something happens to read each file, and a machine that goes
    // offline straight after consolidating shows nothing at all.
    try std.testing.expectEqualStrings(try helpers.readFile(allocator, io, try pathIn(allocator, dirs.remote, REMOTE_THUMB_PATH)), try helpers.readFile(allocator, io, try pathIn(allocator, dirs.local, REMOTE_THUMB_PATH)));
    const shardPath = ".db/bson/collections/metadata/shards/10";
    try std.testing.expectEqualStrings(try helpers.readFile(allocator, io, try pathIn(allocator, dirs.remote, shardPath)), try helpers.readFile(allocator, io, try pathIn(allocator, dirs.local, shardPath)));
}

test "does not pull anything down when the consolidation failed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io, "1-asset", "1-asset-2");
    defer removeDirectories(io, dirs);

    // Another session holds the remote's write lock, so the push blows up.
    const remoteRawStorage = try helpers.directoryStorage(allocator, io, dirs.remote);
    try std.testing.expect(try api.write_lock.acquireWriteLock(allocator, io, remoteRawStorage, "another-session", 1));

    try std.testing.expectError(error.Thrown, consolidateDatabaseHandler(allocator, io, try makeData(allocator, dirs.local, dirs.remote), recording.context.taskContext()));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "Failed to acquire the write lock on the remote database") != null);

    try std.testing.expect(!helpers.fileExists(io, try pathIn(allocator, dirs.local, REMOTE_THUMB_PATH)));
}

test "streams progress as assets are pushed, so a long upload is not silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);

    // test/dbs/1-asset has one photo test/dbs/1-asset-2 does not, and test/dbs/v6 another, so a copy of 1-asset with
    // v6's photo pushed into it has two to push.
    const dirs = try makeDirectories(allocator, io, "1-asset", "1-asset-2");
    defer removeDirectories(io, dirs);
    const second = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(second).?);
    _ = try consolidateDatabaseHandler(allocator, io, try makeData(allocator, second, dirs.local), recording.context.taskContext());
    recording.sentMessages.clearRetainingCapacity();
    const twoAssets = try pathIn(allocator, dirs.localRoot, "two-assets");
    try helpers.copyDirectory(allocator, io, dirs.local, twoAssets);

    _ = try consolidateDatabaseHandler(allocator, io, try makeData(allocator, twoAssets, dirs.remote), recording.context.taskContext());

    try std.testing.expectEqual(@as(usize, 2), recording.sentMessages.items.len);
    try std.testing.expectEqualStrings("{\"type\":\"consolidate-progress\",\"pushed\":1,\"total\":2}", recording.sentMessages.items[0]);
    try std.testing.expectEqualStrings("{\"type\":\"consolidate-progress\",\"pushed\":2,\"total\":2}", recording.sentMessages.items[1]);
}

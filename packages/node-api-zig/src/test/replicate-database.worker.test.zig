const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const errors = utils.errors;
const replicateDatabaseHandler = node_api.replicate_database_worker.replicateDatabaseHandler;
const TaskContext = task_queue_zig.task_context.TaskContext;
const IReplicateDatabaseData = @import("api-zig").replicate_database_types.IReplicateDatabaseData;

//
// The id of the asset in test/dbs/v6.
//
const ASSET_ID = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// A task context whose sendMessage records the messages (TypeScript: makeContext with a jest.fn sendMessage).
//
const RecordingContext = struct {
    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // Deterministic time.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The task context.
    context: TaskContext,

    // The recorded messages, as JSON text.
    messages: std.ArrayList([]const u8),

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
        self.messages.append(self.allocator, text) catch {};
    }
};

//
// Builds a minimal ITaskContext for testing.
//
fn makeContext(allocator: std.mem.Allocator, io: std.Io) !*RecordingContext {
    _ = try helpers.setupEnvironment(io);
    const recording = try allocator.create(RecordingContext);
    recording.* = .{
        .uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator),
        .timestampProvider = .{},
        .context = undefined,
        .messages = .empty,
        .allocator = allocator,
    };
    recording.context = TaskContext.init(recording.uuidGenerator.uuidGenerator(), recording.timestampProvider.timestampProvider(), "session-1", "replicate-task-id", .{ .context = recording, .function = RecordingContext.sendMessage });
    return recording;
}

//
// The directories of a test: a copy of test/dbs/v6 as the source and a path for the destination.
//
const Directories = struct {
    // The directory holding everything.
    root: []const u8,

    // The source database.
    source: []const u8,

    // The destination database (does not exist yet).
    dest: []const u8,
};

//
// Creates the directories of a test.
//
fn makeDirectories(allocator: std.mem.Allocator, io: std.Io) !Directories {
    const sourceDir = try helpers.copyTestDatabase(allocator, io, "v6");
    const root = std.fs.path.dirname(sourceDir).?;
    return .{ .root = root, .source = sourceDir, .dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root}) };
}

//
// Builds a minimal IReplicateDatabaseData for testing, as the JSON the queue carries.
//
fn makeData(allocator: std.mem.Allocator, data: IReplicateDatabaseData) !std.json.Value {
    return node_api.replicate_database.replicateDatabaseDataToJson(allocator, data);
}

//
// Reads a file of a directory.
//
fn readFileIn(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]const u8 {
    return helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }));
}

test "opens source storage via openStorage with sourcePath and sourceEncryptionKey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);
    const keyFile = helpers.KEYS_DIR ++ "/ts-private.pem";

    // Make an encrypted copy, then replicate the encrypted copy back to a plain database with the source key.
    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .destEncryptionKey = keyFile, .partial = false, .force = false }), recording.context.taskContext());
    const plainDir = try std.fmt.allocPrint(allocator, "{s}/plain", .{dirs.root});
    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.dest, .destPath = plainDir, .sourceEncryptionKey = keyFile, .partial = false, .force = false }), recording.context.taskContext());

    const assetPath = "asset/" ++ ASSET_ID;
    try std.testing.expectEqualStrings(try readFileIn(allocator, io, dirs.source, assetPath), try readFileIn(allocator, io, plainDir, assetPath));
    try std.testing.expect(!std.mem.eql(u8, try readFileIn(allocator, io, dirs.source, assetPath), try readFileIn(allocator, io, dirs.dest, assetPath)));
}

test "opens destination storage via openStorage with destPath, destEncryptionKey and destS3Key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);
    const keyFile = helpers.KEYS_DIR ++ "/ts2-private.pem";

    // destS3Key is only used for s3: destinations (see resolve-storage-credentials tests); here it is ignored.
    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .destEncryptionKey = keyFile, .destS3Key = "dest-s3", .partial = false, .force = false }), recording.context.taskContext());

    const dest = try node_api.open_storage.openStorage(allocator, io, dirs.dest, keyFile, null);
    const assetPath = "asset/" ++ ASSET_ID;
    try std.testing.expectEqualStrings(try readFileIn(allocator, io, dirs.source, assetPath), (try dest.storage.read(allocator, io, assetPath)).?);
}

test "forwards partial flag to replicate() when partial is true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .partial = true, .force = false }), recording.context.taskContext());

    const dest = try node_api.open_storage.openStorage(allocator, io, dirs.dest, null, null);
    const destTree = (try node_api.tree.loadMerkleTree(allocator, io, dest.storage)).?;
    try std.testing.expect(node_api.media_file_database.isPartialDatabase(destTree.databaseMetadata));
    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dirs.dest, ASSET_ID })));
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/collections/metadata/shards/96.dat", .{dirs.dest})));
    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/collections/metadata/shards/96", .{dirs.dest})));
}

test "forwards partial flag to replicate() when partial is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .partial = false, .force = false }), recording.context.taskContext());

    const dest = try node_api.open_storage.openStorage(allocator, io, dirs.dest, null, null);
    const destTree = (try node_api.tree.loadMerkleTree(allocator, io, dest.storage)).?;
    try std.testing.expect(!node_api.media_file_database.isPartialDatabase(destTree.databaseMetadata));
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dirs.dest, ASSET_ID })));
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/bson/collections/metadata/shards/96", .{dirs.dest})));
}

test "forwards pathFilter to replicate() options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    const output = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .partial = false, .force = false, .pathFilter = "display/" ++ ASSET_ID }), recording.context.taskContext());

    try std.testing.expectEqual(@as(i64, 1), output.object.get("copiedFiles").?.integer);
    try std.testing.expect(helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/display/{s}", .{ dirs.dest, ASSET_ID })));
    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/thumb/{s}", .{ dirs.dest, ASSET_ID })));
}

test "emits a replicate-progress task message for each progress callback fired by replicate()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .partial = false, .force = false }), recording.context.taskContext());

    try std.testing.expectEqual(@as(usize, 4), recording.messages.items.len);
    const firstMessage = try std.fmt.allocPrint(allocator, "{{\"type\":\"replicate-progress\",\"databasePath\":\"{s}\",\"progress\":\"Copied 1\"}}", .{dirs.source});
    try std.testing.expectEqualStrings(firstMessage, recording.messages.items[0]);
    const lastMessage = try std.fmt.allocPrint(allocator, "{{\"type\":\"replicate-progress\",\"databasePath\":\"{s}\",\"progress\":\"Copied 3 files, 1 records\"}}", .{dirs.source});
    try std.testing.expectEqualStrings(lastMessage, recording.messages.items[3]);
}

test "writes encryption.pub to dest raw storage when destination is encrypted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .destEncryptionKey = helpers.KEYS_DIR ++ "/ts-private.pem", .partial = true, .force = false }), recording.context.taskContext());

    try std.testing.expectEqualStrings(
        try helpers.readFile(allocator, io, helpers.KEYS_DIR ++ "/ts-public.pem"),
        try readFileIn(allocator, io, dirs.dest, ".db/encryption.pub"),
    );
}

test "does not write encryption.pub when destination is not encrypted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    _ = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .partial = true, .force = false }), recording.context.taskContext());

    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/.db/encryption.pub", .{dirs.dest})));
}

test "returns the IReplicationResult from replicate()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    const dirs = try makeDirectories(allocator, io);
    defer helpers.removeTempDir(io, dirs.root);

    const output = try replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = dirs.source, .destPath = dirs.dest, .partial = false, .force = false }), recording.context.taskContext());

    try std.testing.expectEqualStrings("{\"filesImported\":1,\"copiedFiles\":3,\"copiedRecords\":1,\"prunedFiles\":[]}", try std.json.Stringify.valueAlloc(allocator, output, .{}));
}

test "throws when sourcePath is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    try std.testing.expectError(error.Thrown, replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = "", .destPath = "/fake/dest", .partial = true, .force = false }), recording.context.taskContext()));
    try std.testing.expectEqualStrings("sourcePath is required", errors.lastErrorMessage());
}

test "throws when destPath is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const recording = try makeContext(allocator, io);
    try std.testing.expectError(error.Thrown, replicateDatabaseHandler(allocator, io, try makeData(allocator, .{ .sourcePath = "/fake/source", .destPath = "", .partial = true, .force = false }), recording.context.taskContext()));
    try std.testing.expectEqualStrings("destPath is required", errors.lastErrorMessage());
}

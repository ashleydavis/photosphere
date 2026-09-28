const std = @import("std");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const serialization_zig = @import("serialization-zig");
const storage_zig = @import("storage-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const check_worker = node_api.check_worker;
const checkFileHandler = check_worker.checkFileHandler;
const ICheckFileData = check_worker.ICheckFileData;
const ICheckFileResult = check_worker.ICheckFileResult;
const HashCache = node_api.hash_cache.HashCache;
const TaskContext = task_queue_zig.task_context.TaskContext;
const BsonDocument = serialization_zig.bson.BsonDocument;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const path = node_utils.path;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// (Zig: TypeScript mocks the open-storage, hash, hash-cache and media-file-database modules. The Zig port has no
// modules to mock, so these tests give the handler a real file, a real hash cache and a real database holding the
// records a test says it holds.)
//

//
// A task context whose messages go nowhere.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// 2023-01-01T00:00:00.000Z, the modified time of the file checked.
//
const LAST_MODIFIED: i64 = 1672531200000;

//
// The state each test starts from.
//
const CheckTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The photo that is checked (a real PNG).
    filePath: []const u8,

    // The bytes of the photo.
    contents: []const u8,

    // The directory of the hash cache.
    hashCacheDir: []const u8,

    // The database checked against.
    databaseDir: []const u8,

    // The database.
    database: node_api.media_file_database.IMediaFileDatabase,

    // Generates ids.
    uuidGenerator: TestUuidGenerator,

    // Provides the time.
    timestampProvider: TestTimestampProvider,

    // The task context.
    context: TaskContext,

    //
    // Copies the test photo into a directory of the test's own and creates the database.
    //
    fn init(self: *CheckTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try helpers.setupEnvironment(io);
        self.tempDir = try helpers.makeTempDir(allocator, io, "check-worker");
        self.contents = try helpers.readFile(allocator, io, "../../test/test.png");
        self.filePath = try path.join(allocator, &.{ self.tempDir, "photos", "asset.png" });
        try helpers.writeFile(io, self.filePath, self.contents);
        self.hashCacheDir = try path.join(allocator, &.{ self.tempDir, "hash-cache" });
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        self.databaseDir = try path.join(allocator, &.{ self.tempDir, "db" });
        const created = try storage_zig.storage_factory.createStorage(allocator, io, self.databaseDir, null, null);
        self.database = try node_api.media_file_database.createMediaFileDatabase(allocator, created.storage, self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider());
        try node_api.media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, self.uuidGenerator.uuidGenerator(), self.database.metadataCollection, null);
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "session-1", "check-task-id", .{
            .context = null,
            .function = ignoreMessage,
        }, 10);
    }

    //
    // Removes the directory.
    //
    fn deinit(self: *CheckTest) void {
        helpers.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Builds check-file input for the photo.
    //
    fn makeData(self: *CheckTest) ICheckFileData {
        return .{
            .filePath = self.filePath,
            .fileStat = .{
                .length = self.contents.len,
                .lastModified = LAST_MODIFIED,
            },
            .contentType = "image/png",
            .storageDescriptor = .{
                .databasePath = self.databaseDir,
            },
            .hashCacheDir = self.hashCacheDir,
            .logicalPath = self.filePath,
        };
    }

    //
    // Puts a hash in the cache on disk under the photo's path, matching the photo's stat.
    //
    fn cacheHash(self: *CheckTest, hash: []const u8) !void {
        var cache = try HashCache.init(self.hashCacheDir, false);
        defer cache.deinit();
        _ = try cache.load(std.testing.io);
        try cache.addHash(self.filePath, .{
            .hash = hash,
            .length = self.contents.len,
            .lastModified = LAST_MODIFIED,
        });
        try cache.save(std.testing.io);
    }

    //
    // Puts an asset holding the hash in the database.
    //
    fn holdInDatabase(self: *CheckTest, assetId: []const u8, hashHex: []const u8) !void {
        const allocator = self.arena.allocator();
        var record = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "_id",
                .value = .{
                    .string = assetId,
                },
            },
            .{
                .key = "hash",
                .value = .{
                    .string = hashHex,
                },
            },
        });
        try self.database.metadataCollection.insertOne(std.testing.io, &record, null);
        try self.database.bsonDatabase.commit(std.testing.io);
    }

    //
    // Runs the handler and reads its result.
    //
    fn run(self: *CheckTest, data: ICheckFileData) !ICheckFileResult {
        const allocator = self.arena.allocator();
        const text = try std.json.Stringify.valueAlloc(allocator, data, .{
            .emit_null_optional_fields = false,
        });
        const taskData = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        const output = try checkFileHandler(allocator, std.testing.io, taskData, self.context.taskContext());
        return std.json.parseFromValueLeaky(ICheckFileResult, allocator, output, .{});
    }

    //
    // The hex SHA-256 of the photo.
    //
    fn photoHash(self: *CheckTest) [64]u8 {
        var digest: [32]u8 = undefined;
        Sha256.hash(self.contents, &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }
};

test "uses the cached hash and counts matching database records" {
    var context: CheckTest = undefined;
    try context.init();
    defer context.deinit();
    // Not the photo's own hash, so the result can only have come from the cache.
    const cachedHash = [_]u8{0xab} ** 32;
    const cachedHashHex = std.fmt.bytesToHex(cachedHash, .lower);
    try context.cacheHash(&cachedHash);
    try context.holdInDatabase("a1b2c3d4-e5f6-4890-abcd-ef1234567891", &cachedHashHex);
    try context.holdInDatabase("a1b2c3d4-e5f6-4890-abcd-ef1234567892", &cachedHashHex);

    const result = try context.run(context.makeData());

    try std.testing.expectEqual(true, result.hashFromCache);
    try std.testing.expectEqual(@as(u64, 2), result.matchingRecordsCount);
    try std.testing.expectEqualStrings(&cachedHashHex, result.hashedFile.?.hash);
    try std.testing.expectEqualStrings("2023-01-01T00:00:00.000Z", result.hashedFile.?.lastModified);
    try std.testing.expectEqual(@as(u64, context.contents.len), result.hashedFile.?.length);
}

test "computes the hash on a cache miss and reports hashFromCache false" {
    var context: CheckTest = undefined;
    try context.init();
    defer context.deinit();

    const result = try context.run(context.makeData());

    try std.testing.expectEqual(false, result.hashFromCache);
    try std.testing.expectEqual(@as(u64, 0), result.matchingRecordsCount);
    try std.testing.expectEqualStrings(&context.photoHash(), result.hashedFile.?.hash);
}

test "returns an empty result without opening storage when the file cannot be hashed" {
    var context: CheckTest = undefined;
    try context.init();
    defer context.deinit();
    try helpers.writeFile(std.testing.io, context.filePath, "this is not a png");
    var data = context.makeData();
    data.fileStat.length = 17;
    // A database that cannot be opened: opening it would fail the handler.
    data.storageDescriptor.databasePath = "s3:";

    const result = try context.run(data);

    try std.testing.expect(result.hashedFile == null);
    try std.testing.expectEqual(@as(u64, 0), result.matchingRecordsCount);
    try std.testing.expectEqual(false, result.hashFromCache);
}

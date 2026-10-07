const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const hash_file_worker = node_api.hash_file_worker;
const hashFileHandler = hash_file_worker.hashFileHandler;
const IHashFileData = hash_file_worker.IHashFileData;
const IHashFileResult = hash_file_worker.IHashFileResult;
const HashCache = node_api.hash_cache.HashCache;
const forgetSharedHashCaches = node_api.hash_cache.forgetSharedHashCaches;
const TaskContext = task_queue_zig.task_context.TaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const errors = utils.errors;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// (Zig: TypeScript mocks the hash, hash-cache, storage and media-file-database modules. The Zig port has no
// modules to mock, so these tests give the handler a real file and a real hash cache and check what it made of
// them.)
//

//
// Counts the messages the handler sends.
//
const MessageCounter = struct {
    // How many messages were sent.
    count: usize = 0,

    //
    // Counts one message.
    //
    fn send(context: ?*anyopaque, message: std.json.Value) void {
        _ = message;
        const self: *MessageCounter = @ptrCast(@alignCast(context.?));
        self.count += 1;
    }
};

//
// The state each test starts from.
//
const HandlerTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The photo that is hashed (a real PNG).
    filePath: []const u8,

    // The bytes of the photo.
    contents: []const u8,

    // The directory of the hash cache.
    hashCacheDir: []const u8,

    // Generates ids.
    uuidGenerator: TestUuidGenerator,

    // Provides the time.
    timestampProvider: TestTimestampProvider,

    // Counts the messages sent.
    messages: MessageCounter,

    // The task context.
    context: TaskContext,

    //
    // Copies the test photo into a directory of the test's own.
    //
    fn init(self: *HandlerTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try test_environment.setupEnvironment(io);
        forgetSharedHashCaches();
        self.tempDir = try temp_dirs.makeTempDir(allocator, io, "hash-file-worker");
        self.contents = try test_files.readFile(allocator, io, "../test/test.png");
        self.filePath = try std.fmt.allocPrint(allocator, "{s}/photos/img.png", .{self.tempDir});
        try test_files.writeFile(io, self.filePath, self.contents);
        self.hashCacheDir = try std.fmt.allocPrint(allocator, "{s}/hash-cache", .{self.tempDir});
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        self.messages = .{};
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "session-1", "task-1", .{
            .context = &self.messages,
            .function = MessageCounter.send,
        }, 10);
    }

    //
    // Removes the directory.
    //
    fn deinit(self: *HandlerTest) void {
        forgetSharedHashCaches();
        temp_dirs.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Builds a minimal IHashFileData for testing.
    //
    fn makeData(self: *HandlerTest) IHashFileData {
        return .{
            .filePath = self.filePath,
            .fileStat = .{
                .length = self.contents.len,
                .lastModified = 1704067200000,
            },
            .contentType = "image/png",
            .storageDescriptor = .{
                .databasePath = "/test/db",
            },
            .hashCacheDir = self.hashCacheDir,
            .logicalPath = self.filePath,
            .labels = &.{"photos"},
            .sessionId = "session-1",
            .dryRun = false,
            .assetId = "asset-1",
        };
    }

    //
    // Puts a hash in the cache on disk under a key.
    //
    fn cacheHash(self: *HandlerTest, key: []const u8, hash: []const u8, length: u64, lastModified: i64) !void {
        var cache = try HashCache.init(self.hashCacheDir, false);
        defer cache.deinit();
        _ = try cache.load(std.testing.io);
        try cache.addHash(key, .{
            .hash = hash,
            .length = length,
            .lastModified = lastModified,
        });
        try cache.save(std.testing.io);
    }

    //
    // Runs the handler and reads its result.
    //
    fn run(self: *HandlerTest, data: IHashFileData) !IHashFileResult {
        const allocator = self.arena.allocator();
        const text = try std.json.Stringify.valueAlloc(allocator, data, .{ .emit_null_optional_fields = false });
        const taskData = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        const output = try hashFileHandler(allocator, std.testing.io, taskData, self.context.taskContext());
        return std.json.parseFromValueLeaky(IHashFileResult, allocator, output, .{});
    }

    //
    // The hex SHA-256 of the photo.
    //
    fn photoHash(self: *HandlerTest) [64]u8 {
        var digest: [32]u8 = undefined;
        Sha256.hash(self.contents, &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }
};

test "returns hash from cache when cache hit" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    const data = context.makeData();
    const cachedHash = [_]u8{0xaa} ** 32;
    try context.cacheHash(data.filePath, &cachedHash, data.fileStat.length, data.fileStat.lastModified);

    const result = try context.run(data);

    try std.testing.expectEqual(true, result.hashFromCache);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(cachedHash, .lower), result.hash);
    try std.testing.expectEqual(@as(u64, 0), result.bytesHashed);
}

test "computes hash via validateAndHash when not in cache" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    const data = context.makeData();

    const result = try context.run(data);

    try std.testing.expectEqual(false, result.hashFromCache);
    try std.testing.expectEqualStrings(&context.photoHash(), result.hash);
    try std.testing.expectEqual(@as(u64, data.fileStat.length), result.bytesHashed);
}

test "does not ask the database whether the hash is already there" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    // That question is answered by the orchestrator now, from a map it builds once when the run
    // starts. (Zig: the database named in the data does not exist, so any attempt to open it would fail.)
    const data = context.makeData();

    const result = try context.run(data);

    try std.testing.expectEqualStrings(&context.photoHash(), result.hash);
    try std.testing.expect(!test_files.fileExists(std.testing.io, "/test/db"));
}

test "throws when validateAndHash returns undefined" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    // The validation logs the failure; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    var data = context.makeData();
    // A file that is not the image it claims to be fails its validation.
    try test_files.writeFile(std.testing.io, data.filePath, "not a png at all");
    data.fileStat.length = 16;

    try std.testing.expectError(error.Thrown, context.run(data));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "Failed to validate and hash file") != null);
}

test "dryRun true does not change the return value (hash-file is read-only regardless)" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    const data = context.makeData();
    const cachedHash = [_]u8{0xaa} ** 32;
    try context.cacheHash(data.filePath, &cachedHash, data.fileStat.length, data.fileStat.lastModified);

    const resultNoDryRun = try context.run(data);
    var dryRunData = data;
    dryRunData.dryRun = true;
    const resultDryRun = try context.run(dryRunData);

    try std.testing.expectEqualStrings(resultNoDryRun.hash, resultDryRun.hash);
    try std.testing.expectEqual(resultNoDryRun.hashFromCache, resultDryRun.hashFromCache);
}

test "looks a photo library item up by the identity it was given, not by its temporary path" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    // The temporary copy the item was exported to has a path and a modified time that were both
    // minted by the copy, so looking it up by those would miss every time.
    var data = context.makeData();
    data.cacheIdentity = .{
        .key = "1000000042",
        .length = 4096,
        .lastModified = 1700000000000,
    };
    const cachedHash = [_]u8{0xbb} ** 32;
    var cache = try HashCache.init(context.hashCacheDir, false);
    defer cache.deinit();
    _ = try cache.load(std.testing.io);
    try cache.addSourceHash("1000000042", .{
        .hash = &cachedHash,
        .length = 4096,
        .lastModified = 1700000000000,
    });
    try cache.save(std.testing.io);

    const result = try context.run(data);

    try std.testing.expectEqual(true, result.hashFromCache);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(cachedHash, .lower), result.hash);
}

test "looks an ordinary file up by nothing but its own path, which is what keeps the desktop unchanged" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    const data = context.makeData();
    // An entry under some other key, even with the same size and date, is not this file's.
    const cachedHash = [_]u8{0xcc} ** 32;
    try context.cacheHash("1000000042", &cachedHash, data.fileStat.length, data.fileStat.lastModified);

    const result = try context.run(data);

    try std.testing.expectEqual(false, result.hashFromCache);
    try std.testing.expectEqualStrings(&context.photoHash(), result.hash);
}

test "does not send any messages" {
    var context: HandlerTest = undefined;
    try context.init();
    defer context.deinit();
    const data = context.makeData();
    const cachedHash = [_]u8{0xaa} ** 32;
    try context.cacheHash(data.filePath, &cachedHash, data.fileStat.length, data.fileStat.lastModified);

    _ = try context.run(data);

    try std.testing.expectEqual(@as(usize, 0), context.messages.count);
}

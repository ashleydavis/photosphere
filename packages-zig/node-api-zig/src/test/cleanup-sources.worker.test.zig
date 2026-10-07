const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const cleanup_sources_worker = node_api.cleanup_sources_worker;
const cleanupSourcesHandler = cleanup_sources_worker.cleanupSourcesHandler;
const ICleanupSourcesResult = cleanup_sources_worker.ICleanupSourcesResult;
const registerFolderMediaSourceBuilder = cleanup_sources_worker.registerFolderMediaSourceBuilder;
const HashCache = node_api.hash_cache.HashCache;
const getHashCacheDir = node_api.hash_cache.getHashCacheDir;
const TaskContext = task_queue_zig.task_context.TaskContext;
const BsonDocument = serialization_zig.bson.BsonDocument;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const path = node_utils.path;
const errors = utils.errors;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// (Zig: TypeScript mocks the storage and the database's findByValue. Here the database is a real one in the
// test's directory, holding the records a test says it holds.)
//

//
// A task context that never cancels, and whose messages go nowhere.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const CleanupTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The watched folder.
    photosDir: []const u8,

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
    // Makes the folder, points the temp and cache directories at the test's own and creates the database.
    //
    fn init(self: *CleanupTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try test_environment.setupEnvironment(io);
        try registerFolderMediaSourceBuilder();
        self.tempDir = try temp_dirs.makeTempDir(allocator, io, "cleanup-sources-worker");
        self.photosDir = try path.join(allocator, &.{ self.tempDir, "photos" });
        try std.Io.Dir.cwd().createDirPath(io, self.photosDir);
        try test_environment.setEnv("PHOTOSPHERE_TMP_DIR", self.tempDir);

        // The hash cache this test writes to and reads back lives in the platform's cache location,
        // so pointing that at the test's own directory is what keeps the test off the developer's
        // real cache and out of the way of any other run on the machine.
        try test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", try path.join(allocator, &.{ self.tempDir, "cache" }));

        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        self.databaseDir = try path.join(allocator, &.{ self.tempDir, "db" });
        const created = try @import("storage-zig").storage_factory.createStorage(allocator, io, self.databaseDir, null, null);
        self.database = try node_api.media_file_database.createMediaFileDatabase(allocator, created.storage, self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider());
        try node_api.media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, self.uuidGenerator.uuidGenerator(), self.database.metadataCollection, null);
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "session-1", "cleanup-task", .{
            .context = null,
            .function = ignoreMessage,
        }, 10);
    }

    //
    // Puts the environment back and removes the directory.
    //
    fn deinit(self: *CleanupTest) void {
        test_environment.setEnv("PHOTOSPHERE_TMP_DIR", null) catch {};
        test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", null) catch {};
        temp_dirs.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Writes a photo into the watched folder.
    //
    fn writePhoto(self: *CleanupTest, fileName: []const u8, contents: []const u8) ![]const u8 {
        const filePath = try path.join(self.arena.allocator(), &.{ self.photosDir, fileName });
        try test_files.writeFile(std.testing.io, filePath, contents);
        return filePath;
    }

    //
    // Records against a file what an earlier import would have: the hash of its contents, filed
    // under the source id a folder source gives it, which is its own path.
    //
    fn seedCacheEntry(self: *CleanupTest, filePath: []const u8, contents: []const u8, assetId: ?[]const u8) !void {
        const io = std.testing.io;
        var hash: [32]u8 = undefined;
        Sha256.hash(contents, &hash, .{});
        const fileStat = try std.Io.Dir.cwd().statFile(io, filePath, .{});

        var hashCache = try HashCache.init(try getHashCacheDir(self.arena.allocator(), self.databaseDir), false);
        defer hashCache.deinit();
        _ = try hashCache.load(io);
        try hashCache.addSourceHash(filePath, .{
            .hash = &hash,
            .length = fileStat.size,
            .lastModified = @intCast(@divFloor(fileStat.mtime.nanoseconds, std.time.ns_per_ms)),
        });
        if (assetId) |id| {
            _ = try hashCache.setAssetId(filePath, id);
        }
        try hashCache.save(io);
    }

    //
    // Puts an asset holding the hash of the contents in the database.
    //
    fn holdInDatabase(self: *CleanupTest, contents: []const u8) !void {
        const allocator = self.arena.allocator();
        var hash: [32]u8 = undefined;
        Sha256.hash(contents, &hash, .{});
        var record = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "_id",
                .value = .{ .string = "a1b2c3d4-e5f6-4890-abcd-ef1234567890" },
            },
            .{
                .key = "hash",
                .value = .{ .string = try allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) },
            },
        });
        try self.database.metadataCollection.insertOne(std.testing.io, &record, null);
        try self.database.bsonDatabase.commit(std.testing.io);
    }

    //
    // Runs the handler over the watched folder.
    //
    fn run(self: *CleanupTest, dryRun: bool, withSources: bool) !ICleanupSourcesResult {
        const allocator = self.arena.allocator();
        var descriptor: std.json.ObjectMap = .empty;
        try descriptor.put(allocator, "databasePath", .{ .string = self.databaseDir });
        var sources: std.json.Array = .init(allocator);
        if (withSources) {
            var folder: std.json.ObjectMap = .empty;
            try folder.put(allocator, "type", .{ .string = "folder" });
            try folder.put(allocator, "path", .{ .string = self.photosDir });
            try folder.put(allocator, "recurse", .{ .bool = true });
            try sources.append(.{ .object = folder });
        }
        var settings: std.json.ObjectMap = .empty;
        try settings.put(allocator, "enabled", .{ .bool = true });
        try settings.put(allocator, "sources", .{ .array = sources });
        var data: std.json.ObjectMap = .empty;
        try data.put(allocator, "storageDescriptor", .{ .object = descriptor });
        try data.put(allocator, "settings", .{ .object = settings });
        try data.put(allocator, "dryRun", .{ .bool = dryRun });
        const output = try cleanupSourcesHandler(allocator, std.testing.io, .{ .object = data }, self.context.taskContext());
        return std.json.parseFromValueLeaky(ICleanupSourcesResult, allocator, output, .{});
    }
};

//
// Checks a list of strings.
//
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedString, actualString| {
        try std.testing.expectEqualStrings(expectedString, actualString);
    }
}

test "offers a photo the database holds" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.writePhoto("in-the-database.jpg", "one");
    try context.seedCacheEntry(filePath, "one", "a1b2c3d4-e5f6-4890-abcd-ef1234567890");
    try context.holdInDatabase("one");

    const result = try context.run(true, true);

    try std.testing.expectEqual(@as(u64, 1), result.considered);
    try expectStrings(&.{filePath}, result.deletableSourceIds);
}

test "leaves a photo the database does not hold, whatever the cache says" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    // The cache says this device hashed it and recorded an asset id, but the database is the only
    // thing that counts here: this deletes the user's only copy.
    const filePath = try context.writePhoto("not-in-the-database.jpg", "one");
    try context.seedCacheEntry(filePath, "one", "b1b2c3d4-e5f6-4890-abcd-ef1234567890");

    const result = try context.run(true, true);

    try std.testing.expectEqual(@as(usize, 0), result.deletableSourceIds.len);
}

test "asks the database even when an asset id is recorded" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    // (Zig: TypeScript counts the calls to its mocked findByValue. Here the database holds the photo under an
    // asset id other than the one recorded, and the photo is offered, which only asking the database can find out.)
    const filePath = try context.writePhoto("in-the-database.jpg", "one");
    try context.seedCacheEntry(filePath, "one", "b1b2c3d4-e5f6-4890-abcd-ef1234567890");
    try context.holdInDatabase("one");

    const result = try context.run(true, true);

    try expectStrings(&.{filePath}, result.deletableSourceIds);
}

test "leaves a photo this device has never hashed" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    // A photo imported on another device and synced in. This device has no entry for it, and
    // finding out would mean hashing the whole library, which is the cost this all exists to
    // avoid. So it stays. (Zig: the database holds it, so only the missing cache entry keeps it.)
    _ = try context.writePhoto("from-another-device.jpg", "one");
    try context.holdInDatabase("one");

    const result = try context.run(true, true);

    try std.testing.expectEqual(@as(u64, 1), result.considered);
    try std.testing.expectEqual(@as(usize, 0), result.deletableSourceIds.len);
}

test "leaves a photo whose cache entry no longer describes it" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    // A photo library may hand a deleted item's id to a new one, and deleting the wrong photo is
    // not recoverable.
    const filePath = try context.writePhoto("changed.jpg", "one");
    try context.seedCacheEntry(filePath, "one", "a1b2c3d4-e5f6-4890-abcd-ef1234567890");
    try test_files.writeFile(std.testing.io, filePath, "a completely different photo");
    try context.holdInDatabase("one");

    const result = try context.run(true, true);

    try std.testing.expectEqual(@as(usize, 0), result.deletableSourceIds.len);
}

test "a counting pass deletes nothing" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.writePhoto("in-the-database.jpg", "one");
    try context.seedCacheEntry(filePath, "one", "a1b2c3d4-e5f6-4890-abcd-ef1234567890");
    try context.holdInDatabase("one");

    const result = try context.run(true, true);

    try std.testing.expectEqual(@as(usize, 0), result.deletedSourceIds.len);
    try std.testing.expect(test_files.fileExists(std.testing.io, filePath));
}

test "a deleting pass deletes what it offered" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    const filePath = try context.writePhoto("in-the-database.jpg", "one");
    try context.seedCacheEntry(filePath, "one", "a1b2c3d4-e5f6-4890-abcd-ef1234567890");
    try context.holdInDatabase("one");

    const result = try context.run(false, true);

    try expectStrings(&.{filePath}, result.deletedSourceIds);
    try std.testing.expect(!test_files.fileExists(std.testing.io, filePath));
}

test "a deleting pass leaves the photos it did not offer" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();
    const keptPath = try context.writePhoto("not-in-the-database.jpg", "two");
    const deletedPath = try context.writePhoto("in-the-database.jpg", "one");
    try context.seedCacheEntry(deletedPath, "one", "a1b2c3d4-e5f6-4890-abcd-ef1234567890");
    try context.holdInDatabase("one");

    _ = try context.run(false, true);

    try std.testing.expect(test_files.fileExists(std.testing.io, keptPath));
    try std.testing.expect(!test_files.fileExists(std.testing.io, deletedPath));
}

test "refuses to run with no sources configured, rather than looking nowhere and reporting success" {
    var context: CleanupTest = undefined;
    try context.init();
    defer context.deinit();

    try std.testing.expectError(error.Thrown, context.run(true, false));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "no sources configured") != null);
}

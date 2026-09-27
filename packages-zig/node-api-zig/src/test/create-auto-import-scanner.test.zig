const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const createAutoImportScanner = node_api.create_auto_import_scanner.createAutoImportScanner;
const registerFolderMediaSourceBuilder = node_api.create_auto_import_scanner.registerFolderMediaSourceBuilder;
const IAutoImportScannerProgress = node_api.auto_import_scanner.IAutoImportScannerProgress;
const HashCache = node_api.hash_cache.HashCache;
const IScannedImportFile = node_api.import_scanner.IScannedImportFile;
const ScannerState = node_api.file_scanner.ScannerState;
const createMediaFileDatabase = node_api.media_file_database.createMediaFileDatabase;
const createDatabase = node_api.media_file_database.createDatabase;
const TaskContext = task_queue_zig.task_context.TaskContext;
const BsonDocument = serialization_zig.bson.BsonDocument;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const path = node_utils.path;
const Sha256 = std.crypto.hash.sha2.Sha256;
const storage_factory = @import("storage-zig").storage_factory;

//
// What decides whether a photo already in the database is copied and hashed a second time.
//
// This is the whole cost of a run over a library that has already been imported, on every platform:
// a watched folder on the desktop and the CLI, and the device photo library on a phone. An item the
// cache answers for is never opened, so on a phone it is never copied out of the library and never
// read back, and on the desktop it is never read or hashed.
//
// The tests drive a real folder source and a real hash cache, because the question they are asking
// is whether the identity the import writes into the cache is one a later listing produces again.
// (Zig: the metadata collection is a real one too, holding the assets the test says the database holds, where
// TypeScript answers the one question the scanner asks with an object of its own.)
//

//
// Nothing listening.
//
fn ignoreScannerProgress(context: ?*anyopaque, progress: IAutoImportScannerProgress) void {
    _ = context;
    _ = progress;
}

//
// Nothing listening.
//
fn ignoreScanProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, state: *const ScannerState) void {
    _ = context;
    _ = currentlyScanning;
    _ = state;
}

//
// A task context that never cancels, and whose messages go nowhere.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// Gathers what a scan pushes.
//
const Pushed = struct {
    // Allocates the copies.
    allocator: std.mem.Allocator,

    // What was pushed.
    files: std.ArrayList(IScannedImportFile) = .empty,

    //
    // Records one file.
    //
    fn visit(context: ?*anyopaque, result: IScannedImportFile) anyerror!void {
        const self: *Pushed = @ptrCast(@alignCast(context.?));
        var copy = result;
        copy.filePath = try self.allocator.dupe(u8, result.filePath);
        copy.logicalPath = try self.allocator.dupe(u8, result.logicalPath);
        if (result.cacheIdentity) |identity| {
            copy.cacheIdentity = .{
                .key = try self.allocator.dupe(u8, identity.key),
                .length = identity.length,
                .lastModified = identity.lastModified,
            };
        }
        try self.files.append(self.allocator, copy);
    }
};

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const ScannerTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The watched folder.
    watchedDir: []const u8,

    // The one photo in it.
    photoPath: []const u8,

    // The hash cache the scanner asks.
    hashCache: HashCache,

    // The database the scanner asks when the cache knows a hash but not where it landed.
    database: node_api.media_file_database.IMediaFileDatabase,

    // Generates ids.
    uuidGenerator: TestUuidGenerator,

    // Provides the time.
    timestampProvider: TestTimestampProvider,

    // The task the scanner runs in.
    context: TaskContext,

    //
    // Makes the folder with one photo in it, an empty hash cache and an empty database.
    //
    fn init(self: *ScannerTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try helpers.setupEnvironment(io);
        try registerFolderMediaSourceBuilder();

        self.tempDir = try helpers.makeTempDir(allocator, io, "create-auto-import-scanner");
        self.watchedDir = try path.join(allocator, &.{ self.tempDir, "watched" });
        try std.Io.Dir.cwd().createDirPath(io, self.watchedDir);

        self.photoPath = try path.join(allocator, &.{ self.watchedDir, "photo.jpg" });
        try helpers.writeFile(io, self.photoPath, "the contents of a photo");

        self.hashCache = try HashCache.init(try path.join(allocator, &.{ self.tempDir, "hash-cache" }), false);
        _ = try self.hashCache.load(io);

        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        const databaseDir = try path.join(allocator, &.{ self.tempDir, "database" });
        const created = try createDatabaseStorage(allocator, io, databaseDir);
        self.database = try createMediaFileDatabase(allocator, created.storage, self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider());
        try createDatabase(allocator, io, created.storage, created.rawStorage, self.uuidGenerator.uuidGenerator(), self.database.metadataCollection, null);
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "session", "task", .{
            .context = null,
            .function = ignoreMessage,
        }, 10);
    }

    //
    // Removes the directory.
    //
    fn deinit(self: *ScannerTest) void {
        self.hashCache.deinit();
        helpers.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Records that the database holds an asset with the given content hash.
    //
    fn addAsset(self: *ScannerTest, assetId: []const u8, contentHash: []const u8) !void {
        const allocator = self.arena.allocator();
        var record = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "_id",
                .value = .{ .string = assetId },
            },
            .{
                .key = "hash",
                .value = .{ .string = contentHash },
            },
        });
        try self.database.metadataCollection.insertOne(std.testing.io, &record, null);
        try self.database.bsonDatabase.commit(std.testing.io);
    }

    //
    // Runs one pass over the watched folder and returns the files it pushed at the import.
    //
    // A file that is pushed is one the run is about to open, read and hash. An empty list is a run
    // that recognised everything it saw and did none of that.
    //
    fn runOnePass(self: *ScannerTest) ![]IScannedImportFile {
        const allocator = self.arena.allocator();
        var options: std.json.ObjectMap = .empty;
        try options.put(allocator, "auto", .{ .bool = true });
        var sources: std.json.Array = .init(allocator);
        var folder: std.json.ObjectMap = .empty;
        try folder.put(allocator, "type", .{ .string = "folder" });
        try folder.put(allocator, "path", .{ .string = self.watchedDir });
        try folder.put(allocator, "recurse", .{ .bool = true });
        try sources.append(.{ .object = folder });
        try options.put(allocator, "sources", .{ .array = sources });

        const scanner = try createAutoImportScanner(allocator, .{
            .importOptions = .{ .object = options },
            .storage = self.database.assetStorage,
            .metadataCollection = self.database.metadataCollection,
            .localHashCache = &self.hashCache,
            .sessionTempDir = self.tempDir,
            .context = self.context.taskContext(),
            .onProgress = .{
                .context = null,
                .function = ignoreScannerProgress,
            },
        });

        var pushed: Pushed = .{
            .allocator = allocator,
        };
        try scanner.scan(allocator, std.testing.io, .{
            .context = &pushed,
            .function = Pushed.visit,
        }, .{
            .context = null,
            .function = ignoreScanProgress,
        });
        return pushed.files.items;
    }

    //
    // What the folder listing reports about the photo, which is what the import records against it.
    //
    fn photoIdentity(self: *ScannerTest) !node_api.hash_cache.IHashToCache {
        const stat = try std.Io.Dir.cwd().statFile(std.testing.io, self.photoPath, .{});
        return .{
            .hash = "",
            .length = stat.size,
            .lastModified = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)),
        };
    }

    //
    // Records the photo in the cache the way a finished import does: the content hash under the
    // identity the listing reports, and the id the asset was given in the database.
    //
    fn recordAsImported(self: *ScannerTest, assetId: []const u8) !void {
        var identity = try self.photoIdentity();
        const contentHash = photoHash();
        identity.hash = &contentHash;
        try self.hashCache.addSourceHash(self.photoPath, identity);
        _ = try self.hashCache.setAssetId(self.photoPath, assetId);
    }
};

//
// Makes the storage of a database directory. (No TypeScript counterpart.)
//
fn createDatabaseStorage(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8) !storage_factory.ICreateStorageResult {
    return storage_factory.createStorage(allocator, io, databaseDir, null, null);
}

//
// The content hash of the photo.
//
fn photoHash() [32]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash("the contents of a photo", &digest, .{});
    return digest;
}

test "a photo nothing is known about is pushed to the import" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();

    const pushed = try context.runOnePass();

    try std.testing.expectEqual(@as(usize, 1), pushed.len);
    try std.testing.expectEqualStrings(context.photoPath, pushed[0].filePath);
}

test "a photo with an asset id recorded against it is never pushed" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // Nothing is read at all here: not the file, not the database. This is the state a library
    // that has already been imported is in, and it is why such a run costs almost nothing.
    try context.recordAsImported("asset-1");

    try std.testing.expectEqual(@as(usize, 0), (try context.runOnePass()).len);
}

test "a photo the cache knows the hash of, but not where it landed, is looked up in the database" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // An earlier run hashed it but was stopped before it recorded where it went. The database is
    // asked for that hash, exactly as the import itself would. (Zig: the id is a UUID, because the database is a
    // real one and it takes only UUIDs.)
    var identity = try context.photoIdentity();
    const contentHash = photoHash();
    identity.hash = &contentHash;
    try context.hashCache.addSourceHash(context.photoPath, identity);
    try context.addAsset("a1b2c3d4-e5f6-4890-abcd-ef1234567890", &std.fmt.bytesToHex(contentHash, .lower));

    try std.testing.expectEqual(@as(usize, 0), (try context.runOnePass()).len);

    // And the answer is recorded, so the database is not asked a second time.
    try std.testing.expectEqualStrings("a1b2c3d4-e5f6-4890-abcd-ef1234567890", (try context.hashCache.getHash(allocator, context.photoPath)).?.assetId.?);
}

test "a photo the cache has hashed that the database does not hold is pushed" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    var identity = try context.photoIdentity();
    const contentHash = photoHash();
    identity.hash = &contentHash;
    try context.hashCache.addSourceHash(context.photoPath, identity);

    const pushed = try context.runOnePass();
    try std.testing.expectEqual(@as(usize, 1), pushed.len);
    try std.testing.expectEqualStrings(context.photoPath, pushed[0].filePath);
}

test "a photo whose size no longer matches is pushed, however well known its identity is" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    try context.recordAsImported("asset-1");
    try helpers.writeFile(std.testing.io, context.photoPath, "the contents of a photo, edited and now longer");

    const pushed = try context.runOnePass();
    try std.testing.expectEqual(@as(usize, 1), pushed.len);
    try std.testing.expectEqualStrings(context.photoPath, pushed[0].filePath);
}

test "a photo whose modified time no longer matches is pushed" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    const io = std.testing.io;
    // The same bytes at a different time. A photo library is free to hand a deleted item's
    // identity to a new one, so an entry is only believed when all three parts agree.
    try context.recordAsImported("asset-1");
    const stat = try std.Io.Dir.cwd().statFile(io, context.photoPath, .{});
    const movedOn: std.Io.Timestamp = .{ .nanoseconds = stat.mtime.nanoseconds + 60000 * std.time.ns_per_ms };
    try std.Io.Dir.cwd().setTimestamps(io, context.photoPath, .{
        .access_timestamp = .{ .new = movedOn },
        .modify_timestamp = .{ .new = movedOn },
    });

    const pushed = try context.runOnePass();
    try std.testing.expectEqual(@as(usize, 1), pushed.len);
    try std.testing.expectEqualStrings(context.photoPath, pushed[0].filePath);
}

test "what the import records is an identity the next listing produces again" {
    var context: ScannerTest = undefined;
    try context.init();
    defer context.deinit();
    // The whole thing rests on this. The identity written into the cache when a photo is imported
    // has to be the one a later listing of the same source reports, or the lookup can never
    // match and every photo is copied and hashed again on every run.
    const pushed = try context.runOnePass();

    const identity = try context.photoIdentity();
    try std.testing.expectEqualStrings(context.photoPath, pushed[0].cacheIdentity.?.key);
    try std.testing.expectEqual(identity.length, pushed[0].cacheIdentity.?.length);
    try std.testing.expectEqual(identity.lastModified, pushed[0].cacheIdentity.?.lastModified);
}

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const upload_asset_worker = node_api.upload_asset_worker;
const uploadAssetHandler = upload_asset_worker.uploadAssetHandler;
const IUploadAssetData = upload_asset_worker.IUploadAssetData;
const IUploadAssetResult = upload_asset_worker.IUploadAssetResult;
const decodeAssetRecord = upload_asset_worker.decodeAssetRecord;
const TaskContext = task_queue_zig.task_context.TaskContext;
const BsonDocument = serialization_zig.bson.BsonDocument;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const errors = utils.errors;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// (Zig: TypeScript mocks fs, hash, storage, image, video, node-utils, resolve-storage-credentials,
// media-file-database and utils. The Zig port has no modules to mock, so these tests run the handler over a real
// photo, a real database directory and the real media tools, and check what it wrote and returned.)
//

//
// Records the messages the handler sends.
//
const MessageRecorder = struct {
    // Allocates the copies.
    allocator: std.mem.Allocator,

    // The messages, as JSON text.
    messages: std.ArrayList([]const u8) = .empty,

    //
    // Records one message.
    //
    fn send(context: ?*anyopaque, message: std.json.Value) void {
        const self: *MessageRecorder = @ptrCast(@alignCast(context.?));
        const text = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch {
            return;
        };
        self.messages.append(self.allocator, text) catch {};
    }

    //
    // Whether a message of the given type was sent.
    //
    fn sentType(self: *MessageRecorder, messageType: []const u8) bool {
        for (self.messages.items) |message| {
            const needle = std.fmt.allocPrint(self.allocator, "\"type\":\"{s}\"", .{messageType}) catch {
                return false;
            };
            if (std.mem.indexOf(u8, message, needle) != null) {
                return true;
            }
        }
        return false;
    }
};

//
// The state each test starts from.
//
const UploadTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The database the asset is uploaded into.
    databaseDir: []const u8,

    // The photo that is uploaded (a copy of test.jpg).
    filePath: []const u8,

    // The bytes of the photo.
    contents: []const u8,

    // Generates ids.
    uuidGenerator: TestUuidGenerator,

    // Provides the time.
    timestampProvider: TestTimestampProvider,

    // Records the messages sent.
    messages: MessageRecorder,

    // The task context.
    context: TaskContext,

    //
    // Copies the test photo into a directory of the test's own.
    //
    fn init(self: *UploadTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try helpers.setupEnvironment(io);
        self.tempDir = try helpers.makeTempDir(allocator, io, "upload-asset-worker");
        self.databaseDir = try std.fmt.allocPrint(allocator, "{s}/db", .{self.tempDir});
        try std.Io.Dir.cwd().createDirPath(io, self.databaseDir);
        self.contents = try helpers.readFile(allocator, io, "../../test/test.jpg");
        self.filePath = try std.fmt.allocPrint(allocator, "{s}/photos/img.jpg", .{self.tempDir});
        try helpers.writeFile(io, self.filePath, self.contents);
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        self.messages = .{
            .allocator = allocator,
        };
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "session-1", "task-1", .{
            .context = &self.messages,
            .function = MessageRecorder.send,
        }, 10);
    }

    //
    // Removes the directory.
    //
    fn deinit(self: *UploadTest) void {
        helpers.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Builds a minimal IUploadAssetData for testing.
    //
    fn makeUploadAssetData(self: *UploadTest) IUploadAssetData {
        return .{
            .filePath = self.filePath,
            .fileStat = .{
                .length = self.contents.len,
                .lastModified = 1704067200000,
            },
            .contentType = "image/jpeg",
            .storageDescriptor = .{
                .databasePath = self.databaseDir,
            },
            .logicalPath = "/test/photos/img.jpg",
            .assetId = "asset-1",
            .labels = &.{"photos"},
            .sessionId = "session-1",
            .dryRun = false,
            .expectedHash = "aabbcc",
        };
    }

    //
    // Runs the handler and returns its JSON output.
    //
    fn runRaw(self: *UploadTest, data: IUploadAssetData) !std.json.Value {
        const allocator = self.arena.allocator();
        const text = try std.json.Stringify.valueAlloc(allocator, data, .{ .emit_null_optional_fields = false });
        const taskData = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        return uploadAssetHandler(allocator, std.testing.io, taskData, self.context.taskContext());
    }

    //
    // Runs the handler and reads its result.
    //
    fn run(self: *UploadTest, data: IUploadAssetData) !IUploadAssetResult {
        const output = try self.runRaw(data);
        return std.json.parseFromValueLeaky(IUploadAssetResult, self.arena.allocator(), output, .{});
    }

    //
    // The asset record of a result.
    //
    fn record(self: *UploadTest, result: IUploadAssetResult) !BsonDocument {
        return decodeAssetRecord(self.arena.allocator(), result.assetData.assetRecord);
    }

    //
    // Whether a file exists in the database.
    //
    fn databaseHas(self: *UploadTest, relativePath: []const u8) bool {
        const filePath = std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.databaseDir, relativePath }) catch {
            return false;
        };
        return helpers.fileExists(std.testing.io, filePath);
    }
};

test "returns undefined when cancelled" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    context.context.cancel();

    const output = try context.runRaw(context.makeUploadAssetData());

    try std.testing.expect(output == .null);
}

test "returns IUploadAssetResult with assetData in dry-run mode without writing to storage" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;

    const result = try context.run(data);

    try std.testing.expectEqualStrings("asset-1", result.assetData.assetId);
    try std.testing.expectEqualStrings("asset-1", (try context.record(result)).get("_id").?.string);
    try std.testing.expect(!context.databaseHas("asset/asset-1"));
}

test "sends import-pending message at start" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;

    _ = try context.run(data);

    try std.testing.expectEqualStrings("{\"type\":\"import-pending\",\"assetId\":\"asset-1\",\"logicalPath\":\"/test/photos/img.jpg\"}", context.messages.messages.items[0]);
}

test "does not send import-success or import-skipped messages" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;

    _ = try context.run(data);

    try std.testing.expect(!context.messages.sentType("import-success"));
    try std.testing.expect(!context.messages.sentType("import-skipped"));
}

test "does not acquire write lock or write to database" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();

    _ = try context.run(context.makeUploadAssetData());

    // Storage writes happened, but nothing of the database itself was touched.
    try std.testing.expect(context.databaseHas("asset/asset-1"));
    try std.testing.expect(!context.databaseHas(".db/write.lock"));
    try std.testing.expect(!context.databaseHas(".db/bson"));
    try std.testing.expect(!context.databaseHas(".db/files.dat"));
}

test "returns correct assetRecord hash" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;
    data.expectedHash = "aabbcc";

    const result = try context.run(data);

    try std.testing.expectEqualStrings("aabbcc", (try context.record(result)).get("hash").?.string);
}

test "in non-dry-run mode, storage.writeStream is called for the asset, thumbnail, and display file" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();

    _ = try context.run(context.makeUploadAssetData());

    try std.testing.expect(context.databaseHas("asset/asset-1"));
    try std.testing.expect(context.databaseHas("thumb/asset-1"));
    try std.testing.expect(context.databaseHas("display/asset-1"));
}

test "result.totalSize equals the sum of asset + thumbnail + display byte lengths" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;
    data.fileStat.length = 500;

    const result = try context.run(data);

    // In dry-run mode each of the three uploads uses fileStat.length.
    try std.testing.expectEqual(@as(u64, 500 * 3), result.totalSize);
}

test "returned IAssetDatabaseData includes display fields when a display version is produced" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;

    const result = try context.run(data);

    try std.testing.expect(result.assetData.displayPath != null);
    try std.testing.expect(result.assetData.displayHash != null);
    try std.testing.expect(result.assetData.displayLength != null);
    try std.testing.expect(result.assetData.displayLastModified != null);
}

test "returned IAssetDatabaseData includes thumb fields when a thumbnail is produced" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    // (Zig: a video has a thumbnail and no display version, which is the case TypeScript stages with its mock.)
    var data = context.makeUploadAssetData();
    data.dryRun = true;
    data.contentType = "video/mp4";
    const video = try helpers.readFile(context.arena.allocator(), std.testing.io, "../../test/multiple-files/test.mp4");
    try helpers.writeFile(std.testing.io, context.filePath, video);
    data.fileStat.length = video.len;

    const result = try context.run(data);

    try std.testing.expect(result.assetData.thumbPath != null);
    try std.testing.expect(result.assetData.thumbHash != null);
    try std.testing.expect(result.assetData.thumbLength != null);
    try std.testing.expect(result.assetData.thumbLastModified != null);
    try std.testing.expect(result.assetData.displayPath == null);
}

test "when contentType starts with image/, getImageDetails is called" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;

    const result = try context.run(data);

    // The details of an image: a display version, and no duration.
    try std.testing.expect(result.assetData.displayPath != null);
    try std.testing.expect((try context.record(result)).get("duration") == null);
    try std.testing.expectEqual(false, result.isVideo);
}

test "when contentType starts with video/, getVideoDetails is called" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.dryRun = true;
    data.contentType = "video/mp4";
    const video = try helpers.readFile(context.arena.allocator(), std.testing.io, "../../test/multiple-files/test.mp4");
    try helpers.writeFile(std.testing.io, context.filePath, video);
    data.fileStat.length = video.len;

    const result = try context.run(data);

    // The details of a video: a duration, and no display version.
    try std.testing.expect((try context.record(result)).get("duration") != null);
    try std.testing.expect(result.assetData.displayPath == null);
    try std.testing.expectEqual(true, result.isVideo);
}

test "sends import-failed and cleans up on upload error" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    // A file where the asset directory should be, so writing the asset fails.
    try helpers.writeFile(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset", .{context.databaseDir}), "in the way");
    var data = context.makeUploadAssetData();
    // (Zig: not an image or a video, as TypeScript's getImageDetails mock returns nothing, so the failure is the
    // upload's.)
    data.contentType = "application/octet-stream";

    try std.testing.expectError(error.Thrown, context.run(data));

    try std.testing.expect(context.messages.sentType("import-failed"));
    try std.testing.expect(!context.databaseHas("thumb/asset-1"));
    try std.testing.expect(!context.databaseHas("display/asset-1"));
}

//
// Reading the three copies back out of the store to learn their hashes was the unaccounted half
// of every import into an encrypted database: the bytes came back through the engine's own
// JavaScript decryption and SHA-256 at about a fifth of a megabyte a second on a Pixel 6, seven
// seconds a photo and seven and a half minutes for one 87MB video, as long again as writing them.
//
test "hashes the thumbnail and display from the files on disk, and never reads the store back" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();

    const result = try context.run(context.makeUploadAssetData());

    // The hashes recorded are the hashes of the files as written, which in an unencrypted store are the files.
    var thumbDigest: [32]u8 = undefined;
    Sha256.hash(try helpers.readFile(allocator, std.testing.io, try std.fmt.allocPrint(allocator, "{s}/thumb/asset-1", .{context.databaseDir})), &thumbDigest, .{});
    var displayDigest: [32]u8 = undefined;
    Sha256.hash(try helpers.readFile(allocator, std.testing.io, try std.fmt.allocPrint(allocator, "{s}/display/asset-1", .{context.databaseDir})), &displayDigest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(thumbDigest, .lower), result.assetData.thumbHash.?);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(displayDigest, .lower), result.assetData.displayHash.?);
}

test "the asset's hash is the one the import already had, so its file is not hashed again" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();

    const result = try context.run(context.makeUploadAssetData());

    try std.testing.expectEqualStrings("aabbcc", (try context.record(result)).get("hash").?.string);
    try std.testing.expectEqualStrings("aabbcc", result.assetData.assetHash);
}

//
// What a store can say about the copy without reading it, it is asked: one that hands out what it
// holds is checked by length, and one that cannot say (an encrypted store) is not checked here.
//
test "a store that holds a different length than was written refuses the asset" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    // The stat says 1000 bytes; the store holds what the file really has.
    data.fileStat.length = 1000;

    try std.testing.expectError(error.Thrown, context.run(data));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "asset/asset-1") != null);
}

test "a store that cannot say what length its copy reads is not checked by length" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var data = context.makeUploadAssetData();
    data.fileStat.length = 1000;
    // An encrypted store cannot say what its copy reads without reading it.
    data.storageDescriptor.encryptionKey = helpers.KEYS_DIR ++ "/ts-private.pem";

    const result = try context.run(data);

    try std.testing.expectEqualStrings("aabbcc", (try context.record(result)).get("hash").?.string);
}

//
// A timestamp provider that records, when the upload date is asked for, whether the display file is already in
// the database, which is how a test can tell the date was read after the uploads.
//
const UploadDateWitness = struct {
    // The database the asset is uploaded into.
    databaseDir: []const u8,

    // Whether the display file existed when dateNow was called, or null when it was never called.
    displayExisted: ?bool = null,

    //
    // `Date.now()`.
    //
    fn now(ptr: *anyopaque, io: std.Io) i64 {
        _ = ptr;
        _ = io;
        return 1700000000000;
    }

    //
    // `new Date()`, noting whether the display file had been uploaded yet.
    //
    fn dateNow(ptr: *anyopaque, io: std.Io) utils.timestamp_provider.Date {
        const self: *UploadDateWitness = @ptrCast(@alignCast(ptr));
        var buffer: [4096]u8 = undefined;
        const displayPath = std.fmt.bufPrint(&buffer, "{s}/display/asset-1", .{self.databaseDir}) catch unreachable;
        self.displayExisted = helpers.fileExists(io, displayPath);
        return .{
            .epochMilliseconds = 1700000000000,
        };
    }

    // The provider's functions.
    const vtable: utils.timestamp_provider.ITimestampProvider.VTable = .{
        .now = now,
        .dateNow = dateNow,
    };
};

test "the upload date is read once the files are uploaded, as the TypeScript builds the record after them" {
    var context: UploadTest = undefined;
    try context.init();
    defer context.deinit();
    var witness: UploadDateWitness = .{
        .databaseDir = context.databaseDir,
    };
    context.context = TaskContext.init(context.uuidGenerator.uuidGenerator(), .{
        .ptr = &witness,
        .vtable = &UploadDateWitness.vtable,
    }, "session-1", "task-1", .{
        .context = &context.messages,
        .function = MessageRecorder.send,
    }, 10);

    _ = try context.run(context.makeUploadAssetData());

    try std.testing.expectEqual(@as(?bool, true), witness.displayExisted);
}

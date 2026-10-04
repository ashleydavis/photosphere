//
// Tests for addPaths (import.zig), which the TypeScript tests reach only through the CLI's add command.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const media_file_database = node_api.media_file_database;
const addPaths = node_api.import_module.addPaths;
const IAddSummary = media_file_database.IAddSummary;

//
// What the progress callback of an import saw.
//
const IProgressLog = struct {
    // The number of times the callback was called.
    calls: u32,

    // The number of files added in the last summary it was given.
    lastFilesAdded: f64,
};

//
// Records a progress report of addPaths.
//
fn recordProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, summary: *const IAddSummary) void {
    _ = currentlyScanning;
    const progressLog: *IProgressLog = @ptrCast(@alignCast(context.?));
    progressLog.calls += 1;
    progressLog.lastFilesAdded = summary.filesAdded;
}

test "addPaths imports a file into a new database, then finds it already there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    defer node_utils.termination.clearTerminationCallbacks();
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);

    // A new, empty database and a folder holding one photo.
    const root = try helpers.makeTempDir(allocator, io, "add-paths");
    defer helpers.removeTempDir(io, root);
    const databaseDir = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const created = try @import("storage-zig").storage_factory.createStorage(allocator, io, databaseDir, null, null);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, uuidGenerator.uuidGenerator(), database.metadataCollection, null);
    const photosDir = try std.fmt.allocPrint(allocator, "{s}/photos", .{root});
    try std.Io.Dir.cwd().createDirPath(io, photosDir);
    try std.Io.Dir.cwd().copyFile("../../test/test.jpg", std.Io.Dir.cwd(), try std.fmt.allocPrint(allocator, "{s}/photo.jpg", .{photosDir}), io, .{});

    var progressLog: IProgressLog = .{ .calls = 0, .lastFilesAdded = 0 };
    const summary = try addPaths(allocator, io, uuidGenerator.uuidGenerator(), .{ .databasePath = databaseDir }, &.{photosDir}, null, "session-1", false, .{ .context = &progressLog, .function = recordProgress }, null);

    try std.testing.expectEqual(@as(f64, 1), summary.filesAdded);
    try std.testing.expectEqual(@as(f64, 1), summary.filesProcessed);
    try std.testing.expectEqual(summary.totalSize, summary.averageSize);
    try std.testing.expect(progressLog.calls > 0);
    try std.testing.expectEqual(@as(f64, 1), progressLog.lastFilesAdded);

    // The same folder again: the import record already holds the photo, so the scanner skips it before opening it
    // and no file message is sent for it (as in TypeScript).
    const again = try addPaths(allocator, io, uuidGenerator.uuidGenerator(), .{ .databasePath = databaseDir }, &.{photosDir}, null, "session-2", false, null, null);
    try std.testing.expectEqual(@as(f64, 0), again.filesAdded);
    try std.testing.expectEqual(@as(f64, 0), again.filesAlreadyAdded);
    try std.testing.expectEqual(@as(f64, 0), again.filesProcessed);
    try std.testing.expectEqual(@as(f64, 0), again.averageSize);
}

//
// A new, empty database and the folder of photos to import into it.
//
const IImportFixture = struct {
    // The directory holding the database and the photos.
    root: []const u8,

    // The directory of the database.
    databaseDir: []const u8,

    // The directory the photos are put in.
    photosDir: []const u8,

    // Generates the ids of the import.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,
};

//
// Creates the fixture: a new database and an empty folder for photos.
//
fn createImportFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !*IImportFixture {
    _ = try helpers.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    const fixture = try allocator.create(IImportFixture);
    fixture.uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    fixture.root = try helpers.makeTempDir(allocator, io, name);
    fixture.databaseDir = try std.fmt.allocPrint(allocator, "{s}/db", .{fixture.root});
    fixture.photosDir = try std.fmt.allocPrint(allocator, "{s}/photos", .{fixture.root});
    const created = try @import("storage-zig").storage_factory.createStorage(allocator, io, fixture.databaseDir, null, null);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, fixture.uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, fixture.uuidGenerator.uuidGenerator(), database.metadataCollection, null);
    try std.Io.Dir.cwd().createDirPath(io, fixture.photosDir);
    return fixture;
}

//
// Copies a file of the repository's test directory into a folder.
//
fn copyTestFile(allocator: std.mem.Allocator, io: std.Io, testFile: []const u8, folder: []const u8, fileName: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, folder);
    try std.Io.Dir.cwd().copyFile(try std.fmt.allocPrint(allocator, "../../test/{s}", .{testFile}), std.Io.Dir.cwd(), try std.fmt.allocPrint(allocator, "{s}/{s}", .{ folder, fileName }), io, .{});
}

// TypeScript: the import-skipped branch of the onAnyTaskMessage of addPaths. A photo that the database already holds
// under another path has not been seen by the import record, so it is hashed, found in the database and skipped.
test "addPaths counts a photo whose content the database already holds as already added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    defer node_utils.termination.clearTerminationCallbacks();
    const fixture = try createImportFixture(allocator, io, "add-paths-skipped");
    defer helpers.removeTempDir(io, fixture.root);
    try copyTestFile(allocator, io, "test.jpg", fixture.photosDir, "first.jpg");
    const otherDir = try std.fmt.allocPrint(allocator, "{s}/other", .{fixture.root});
    try copyTestFile(allocator, io, "test.jpg", otherDir, "same-content.jpg");

    // (Each test names its sessions itself: the worker pool keeps a session cancelled for as long as the process runs,
    // so one session name must not be used by two tests.)
    const first = try addPaths(allocator, io, fixture.uuidGenerator.uuidGenerator(), .{ .databasePath = fixture.databaseDir }, &.{fixture.photosDir}, null, "skipped-session-1", false, null, null);
    try std.testing.expectEqual(@as(f64, 1), first.filesAdded);

    // The worker pool the tests use keeps a source cancelled for as long as the process runs (as TypeScript's
    // MockWorkerPool does), and an import's source is its database path. Ending the first import cancelled the
    // path, so the same database is named another way (with its "fs:" prefix) for the second import.
    const prefixedDatabasePath = try std.fmt.allocPrint(allocator, "fs:{s}", .{fixture.databaseDir});
    const second = try addPaths(allocator, io, fixture.uuidGenerator.uuidGenerator(), .{ .databasePath = prefixedDatabasePath }, &.{otherDir}, null, "skipped-session-2", false, null, null);
    try std.testing.expectEqual(@as(f64, 0), second.filesAdded);
    try std.testing.expectEqual(@as(f64, 1), second.filesAlreadyAdded);
    try std.testing.expectEqual(@as(f64, 1), second.filesProcessed);
}

// TypeScript: the file-ignored branch of the onAnyTaskMessage of addPaths. The scanner ignores a file that is not
// media, and tells the import how many it ignored.
test "addPaths counts the files the scanner ignores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    defer node_utils.termination.clearTerminationCallbacks();
    const fixture = try createImportFixture(allocator, io, "add-paths-ignored");
    defer helpers.removeTempDir(io, fixture.root);
    try copyTestFile(allocator, io, "test.jpg", fixture.photosDir, "photo.jpg");
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/notes.txt", .{fixture.photosDir}), "not media");

    const summary = try addPaths(allocator, io, fixture.uuidGenerator.uuidGenerator(), .{ .databasePath = fixture.databaseDir }, &.{fixture.photosDir}, null, "ignored-session-1", false, null, null);

    try std.testing.expectEqual(@as(f64, 1), summary.filesAdded);
    try std.testing.expectEqual(@as(f64, 1), summary.filesIgnored);
}

// TypeScript: the import-failed branch of the onAnyTaskMessage of addPaths. An image that cannot be read fails to
// upload. The upload task sends import-failed itself, and the import sends it again when the task fails, so the
// summary counts both (in TypeScript too: upload-asset.worker.ts and import-assets.worker.ts each send one), unless
// the run ends before the second is delivered, so the test asks for at least one.
test "addPaths counts an image that cannot be read as failed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    defer node_utils.termination.clearTerminationCallbacks();
    const fixture = try createImportFixture(allocator, io, "add-paths-failed");
    defer helpers.removeTempDir(io, fixture.root);
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/broken.jpg", .{fixture.photosDir}), "these bytes are not a jpeg");

    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    helpers.captureStderr(&stderr_capture.writer);
    defer helpers.endConsoleCapture();

    const summary = try addPaths(allocator, io, fixture.uuidGenerator.uuidGenerator(), .{ .databasePath = fixture.databaseDir }, &.{fixture.photosDir}, null, "failed-session-1", false, null, null);

    try std.testing.expectEqual(@as(f64, 0), summary.filesAdded);
    try std.testing.expect(summary.filesFailed >= 1);
}

// The Google API key, the import options and the encryption key of the storage descriptor are queued with the task
// when they are given.
test "addPaths queues the Google API key, the options and the encryption key it is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    defer node_utils.termination.clearTerminationCallbacks();
    const fixture = try createImportFixture(allocator, io, "add-paths-options");
    defer helpers.removeTempDir(io, fixture.root);

    // A png has no coordinates, so the key is never used to look up a place.
    try copyTestFile(allocator, io, "test.png", fixture.photosDir, "photo.png");

    const summary = try addPaths(allocator, io, fixture.uuidGenerator.uuidGenerator(), .{
        .databasePath = fixture.databaseDir,
        .encryptionKey = helpers.KEYS_DIR ++ "/ts-private.pem",
    }, &.{fixture.photosDir}, "a-google-api-key", "options-session-1", false, null, .{
        .auto = false,
        .sources = &.{},
    });

    try std.testing.expectEqual(@as(f64, 1), summary.filesAdded);

    // The key reached the upload, which wrote the asset encrypted.
    const original = try helpers.readFile(allocator, io, "../../test/test.png");
    const assetsDir = try std.fmt.allocPrint(allocator, "{s}/asset", .{fixture.databaseDir});
    var assets = try std.Io.Dir.cwd().openDir(io, assetsDir, .{ .iterate = true });
    defer assets.close(io);
    var iterator = assets.iterate();
    const assetEntry = (try iterator.next(io)).?;
    const stored = try helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetsDir, assetEntry.name }));
    try std.testing.expect(!std.mem.eql(u8, original, stored));
}

// TypeScript: the termination callback of addPaths shuts the queue down, so Ctrl-C reaches the task.
test "the termination callback addPaths registers shuts the queue down without failing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    defer node_utils.termination.clearTerminationCallbacks();
    const fixture = try createImportFixture(allocator, io, "add-paths-termination");
    defer helpers.removeTempDir(io, fixture.root);
    try copyTestFile(allocator, io, "test.jpg", fixture.photosDir, "photo.jpg");

    _ = try addPaths(allocator, io, fixture.uuidGenerator.uuidGenerator(), .{ .databasePath = fixture.databaseDir }, &.{fixture.photosDir}, null, "termination-session-1", false, null, null);

    try node_utils.termination.invokeTerminationCallbacks(io, 130);
}

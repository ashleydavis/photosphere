const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const recording_task_context = @import("recording-task-context.zig");
const errors = utils.errors;
const getImportRecordHandler = node_api.get_import_record_worker.getImportRecordHandler;
const getImportRecordPath = node_api.database_cache_dir.getImportRecordPath;
const addDatabaseEntry = node_api.databases_config.addDatabaseEntry;
const openStorage = node_api.open_storage.openStorage;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;

//
// What each test works in: a cache directory of its own, so the record is read from a real filesystem without any test
// reaching the developer's real record or each other's.
//
const RecordTest = struct {
    // The environment of the test (see test-environment.zig), freed by deinit.
    test_env: *test_environment.TestEnvironment,

    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory the test's files live in.
    runRoot: []const u8,

    // The context the handler is called with. It reads nothing from it.
    context: RecordingTaskContext,

    //
    // Points the cache directory at the test's own.
    //
    fn init(self: *RecordTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        self.test_env = try test_environment.setupEnvironmentWith(io, allocator);
        self.runRoot = try temp_dirs.makeTempDir(allocator, io, "get-import-record-test");
        try test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", try std.fs.path.join(allocator, &.{ self.runRoot, "cache" }));
        try self.context.init(allocator, null, null);
    }

    //
    // Puts the cache directory back the way it was.
    //
    fn deinit(self: *RecordTest) void {
        test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", null) catch |err| {
            std.debug.panic("PHOTOSPHERE_CACHE_DIR could not be put back: {s}", .{@errorName(err)});
        };
        temp_dirs.removeTempDir(std.testing.io, self.runRoot);
        self.test_env.deinitWith(self.arena.allocator());
        self.arena.deinit();
    }

    //
    // Writes the record this machine keeps for a database.
    //
    fn writeRecord(self: *RecordTest, databasePath: []const u8, contents: []const u8) !void {
        const allocator = self.arena.allocator();
        try test_files.writeFile(std.testing.io, try getImportRecordPath(allocator, databasePath), contents);
    }

    //
    // Runs the handler for a path.
    //
    fn run(self: *RecordTest, databasePath: []const u8) !std.json.Value {
        const allocator = self.arena.allocator();
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "databasePath", .{ .string = databasePath });
        return getImportRecordHandler(allocator, std.testing.io, test_timers.timers(), .{ .object = object }, self.context.taskContext());
    }
};

test "returns what this machine recorded" {
    var recordTest: RecordTest = undefined;
    try recordTest.init();
    defer recordTest.deinit();
    try recordTest.writeRecord("db", "{\"entries\":[{\"assetId\":\"a\",\"logicalPath\":\"one.png\",\"outcome\":\"imported\",\"importedAt\":\"\",\"source\":\"automatic\"}],\"truncated\":true}");

    const record = try recordTest.run("db");

    const entries = record.object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("automatic", entries[0].object.get("source").?.string);
    try std.testing.expectEqualStrings("a", entries[0].object.get("assetId").?.string);
    try std.testing.expectEqualStrings("one.png", entries[0].object.get("logicalPath").?.string);
    try std.testing.expectEqualStrings("imported", entries[0].object.get("outcome").?.string);
    try std.testing.expect(entries[0].object.get("micro") == null);
    try std.testing.expectEqual(true, record.object.get("truncated").?.bool);
}

test "a database that has imported nothing comes back empty rather than failing" {
    var recordTest: RecordTest = undefined;
    try recordTest.init();
    defer recordTest.deinit();

    const record = try recordTest.run("db");

    try std.testing.expectEqual(@as(usize, 0), record.object.get("entries").?.array.items.len);
    try std.testing.expectEqual(false, record.object.get("truncated").?.bool);
}

test "a missing database path is refused rather than read as an empty database" {
    var recordTest: RecordTest = undefined;
    try recordTest.init();
    defer recordTest.deinit();
    try recordTest.writeRecord("", "{\"entries\":[{\"assetId\":\"a\",\"logicalPath\":\"one.png\",\"outcome\":\"imported\",\"importedAt\":\"\",\"source\":\"manual\"}],\"truncated\":false}");

    try std.testing.expectError(error.Thrown, recordTest.run(""));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws when the task data has no database path" {
    var recordTest: RecordTest = undefined;
    try recordTest.init();
    defer recordTest.deinit();

    try std.testing.expectError(error.Thrown, getImportRecordHandler(recordTest.arena.allocator(), std.testing.io, test_timers.timers(), .{ .object = .empty }, recordTest.context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws a descriptive error when the database path is not a string" {
    var recordTest: RecordTest = undefined;
    try recordTest.init();
    defer recordTest.deinit();
    const allocator = recordTest.arena.allocator();
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, getImportRecordHandler(allocator, std.testing.io, test_timers.timers(), .{ .object = object }, recordTest.context.taskContext()));
    try std.testing.expectEqualStrings("The get-import-record task data is not valid: databasePath must be a string", errors.lastErrorMessage());
}

test "the record is read for the database path without opening the database" {
    var recordTest: RecordTest = undefined;
    try recordTest.init();
    defer recordTest.deinit();
    const allocator = recordTest.arena.allocator();
    const io = std.testing.io;

    // A database whose credentials are missing: it is listed with the name of an encryption key that the vault does not
    // hold, so opening its storage throws. The record is a local file beside the hash cache, so nothing about the
    // database has to be reachable to read it: an S3 database with no credentials, or one whose remote is down, still
    // answers "what did I import?".
    const configDir = try temp_dirs.makeTempDir(allocator, io, "get-import-record-config");
    defer temp_dirs.removeTempDir(io, configDir);
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    try addDatabaseEntry(allocator, io, .{
        .name = "photos",
        .description = "",
        .path = "s3:bucket:/photos",
        .encryptionKey = "get-import-record-missing-key",
    });
    try std.testing.expectError(error.Thrown, openStorage(allocator, io, "s3:bucket:/photos", null, null, null));
    try recordTest.writeRecord("s3:bucket:/photos", "{\"entries\":[{\"assetId\":\"b\",\"logicalPath\":\"two.png\",\"outcome\":\"skipped\",\"importedAt\":\"\",\"source\":\"manual\"}],\"truncated\":false}");

    const record = try recordTest.run("s3:bucket:/photos");

    const entries = record.object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("two.png", entries[0].object.get("logicalPath").?.string);
}

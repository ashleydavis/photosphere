const std = @import("std");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_environment = @import("test-environment.zig");
const test_task_context = @import("test-task-context.zig");
const resetAppStorageHandler = node_api.reset_app_storage_worker.resetAppStorageHandler;
const IResetAppStorageResult = node_api.reset_app_storage_worker.IResetAppStorageResult;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTaskContext = test_task_context.TestTaskContext;

//
// The handler reads the app's config and cache directories from the environment, so every test
// points both at directories of its own. This is what keeps the test off the developer's real
// settings and caches, and out of the way of any other run on the machine.
//

//
// Copies an optional string, because the environment frees the value it held when the variable is set again.
//
fn copyOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const value = text orelse {
        return null;
    };
    return try allocator.dupe(u8, value);
}

//
// The directories the environment named before a test pointed it at its own, which it puts back at the end.
//
const SavedDirectories = struct {
    // The value of PHOTOSPHERE_CONFIG_DIR before the test.
    configDir: ?[]const u8,

    // The value of PHOTOSPHERE_CACHE_DIR before the test.
    cacheDir: ?[]const u8,

    //
    // Remembers the directories the environment names now.
    //
    fn save(allocator: std.mem.Allocator) !SavedDirectories {
        return .{
            .configDir = try copyOptional(allocator, node_utils.process_env.getEnv("PHOTOSPHERE_CONFIG_DIR")),
            .cacheDir = try copyOptional(allocator, node_utils.process_env.getEnv("PHOTOSPHERE_CACHE_DIR")),
        };
    }

    //
    // Puts the environment variables back the way the test found them, so one test's directories are not
    // still in force for whatever runs next.
    //
    fn restore(self: SavedDirectories) void {
        test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", self.configDir) catch @panic("Could not restore PHOTOSPHERE_CONFIG_DIR.");
        test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", self.cacheDir) catch @panic("Could not restore PHOTOSPHERE_CACHE_DIR.");
    }
};

//
// Points the app's config and cache directories at the given paths.
//
fn useDirectories(configDir: []const u8, cacheDir: []const u8) !void {
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    try test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", cacheDir);
}

//
// Writes a file with the given content, making the directories above it.
//
fn writeTestFile(allocator: std.mem.Allocator, io: std.Io, directoryPath: []const u8, fileName: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, directoryPath);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ directoryPath, fileName }),
        .data = content,
    });
}

//
// Runs the handler and reads its result.
//
fn run(allocator: std.mem.Allocator, io: std.Io, testContext: *TestTaskContext) !IResetAppStorageResult {
    const output = try resetAppStorageHandler(allocator, io, .{ .object = .empty }, testContext.context.taskContext());
    return std.json.parseFromValueLeaky(IResetAppStorageResult, allocator, output, .{});
}

test "empties the config and cache directories and leaves the directories in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const saved = try SavedDirectories.save(allocator);
    defer saved.restore();
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    var testContext: TestTaskContext = undefined;
    testContext.init(uuidGenerator.uuidGenerator());
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "reset-app-storage-worker");
    defer temp_dirs.removeTempDir(io, tempDir);
    const configDir = try std.fs.path.join(allocator, &.{ tempDir, "config" });
    const cacheDir = try std.fs.path.join(allocator, &.{ tempDir, "cache" });
    try writeTestFile(allocator, io, configDir, "databases.toml", "databases = []");
    try writeTestFile(allocator, io, configDir, "config.yaml", "theme: dark\n");
    try writeTestFile(allocator, io, cacheDir, "hashes.dat", "hashes");
    try useDirectories(configDir, cacheDir);

    const result = try run(allocator, io, &testContext);

    try std.testing.expectEqual(@as(usize, 0), (try node_utils.node_fs.readdir(allocator, io, configDir)).len);
    try std.testing.expectEqual(@as(usize, 0), (try node_utils.node_fs.readdir(allocator, io, cacheDir)).len);
    try std.testing.expectEqual(@as(u64, 3), result.entriesRemoved);
    try std.testing.expectEqual(@as(usize, 2), result.directoriesCleared.len);
    try std.testing.expectEqualStrings(configDir, result.directoriesCleared[0]);
    try std.testing.expectEqualStrings(cacheDir, result.directoriesCleared[1]);
}

test "removes nested directory trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const saved = try SavedDirectories.save(allocator);
    defer saved.restore();
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    var testContext: TestTaskContext = undefined;
    testContext.init(uuidGenerator.uuidGenerator());
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "reset-app-storage-worker");
    defer temp_dirs.removeTempDir(io, tempDir);
    const configDir = try std.fs.path.join(allocator, &.{ tempDir, "config" });
    const cacheDir = try std.fs.path.join(allocator, &.{ tempDir, "cache" });
    try std.Io.Dir.cwd().createDirPath(io, cacheDir);
    try writeTestFile(allocator, io, try std.fs.path.join(allocator, &.{ configDir, "a-database", ".db", "bson" }), "metadata.bson", "bytes");
    try useDirectories(configDir, cacheDir);

    const result = try run(allocator, io, &testContext);

    try std.testing.expectEqual(@as(usize, 0), (try node_utils.node_fs.readdir(allocator, io, configDir)).len);
    try std.testing.expectEqual(@as(u64, 1), result.entriesRemoved);
}

test "leaves everything outside the two directories alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const saved = try SavedDirectories.save(allocator);
    defer saved.restore();
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    var testContext: TestTaskContext = undefined;
    testContext.init(uuidGenerator.uuidGenerator());
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "reset-app-storage-worker");
    defer temp_dirs.removeTempDir(io, tempDir);
    const configDir = try std.fs.path.join(allocator, &.{ tempDir, "config" });
    const cacheDir = try std.fs.path.join(allocator, &.{ tempDir, "cache" });
    const photosDir = try std.fs.path.join(allocator, &.{ tempDir, "photos" });
    try std.Io.Dir.cwd().createDirPath(io, cacheDir);
    try writeTestFile(allocator, io, configDir, "databases.toml", "databases = []");
    try writeTestFile(allocator, io, photosDir, "holiday.jpg", "a photo nobody may delete");
    try useDirectories(configDir, cacheDir);

    _ = try run(allocator, io, &testContext);

    try std.testing.expect(node_utils.fs.pathExists(io, try std.fs.path.join(allocator, &.{ photosDir, "holiday.jpg" })));
}

test "empties one directory once when the config and the cache are the same place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const saved = try SavedDirectories.save(allocator);
    defer saved.restore();
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    var testContext: TestTaskContext = undefined;
    testContext.init(uuidGenerator.uuidGenerator());
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "reset-app-storage-worker");
    defer temp_dirs.removeTempDir(io, tempDir);
    // The device case: getConfigDir() and getCacheDir() both answer the app's storage sandbox
    // root, so the same directory is named twice and must be emptied and counted once.
    const sandboxDir = try std.fs.path.join(allocator, &.{ tempDir, "sandbox" });
    try writeTestFile(allocator, io, sandboxDir, "databases.toml", "databases = []");
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ sandboxDir, "my-photos" }));
    try useDirectories(sandboxDir, sandboxDir);

    const result = try run(allocator, io, &testContext);

    try std.testing.expectEqual(@as(usize, 0), (try node_utils.node_fs.readdir(allocator, io, sandboxDir)).len);
    try std.testing.expectEqual(@as(u64, 2), result.entriesRemoved);
    try std.testing.expectEqual(@as(usize, 1), result.directoriesCleared.len);
    try std.testing.expectEqualStrings(sandboxDir, result.directoriesCleared[0]);
}

test "succeeds when the directories do not exist yet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    const saved = try SavedDirectories.save(allocator);
    defer saved.restore();
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    var testContext: TestTaskContext = undefined;
    testContext.init(uuidGenerator.uuidGenerator());
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "reset-app-storage-worker");
    defer temp_dirs.removeTempDir(io, tempDir);
    try useDirectories(
        try std.fs.path.join(allocator, &.{ tempDir, "never-written-config" }),
        try std.fs.path.join(allocator, &.{ tempDir, "never-written-cache" }),
    );

    const result = try run(allocator, io, &testContext);

    try std.testing.expectEqual(@as(u64, 0), result.entriesRemoved);
}

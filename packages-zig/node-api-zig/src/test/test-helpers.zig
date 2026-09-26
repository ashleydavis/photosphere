const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const FileStorage = storage_zig.file_storage.FileStorage;
const IStorage = storage_zig.storage.IStorage;
const MockWorkerPool = task_queue_zig.mock_worker_pool.MockWorkerPool;

//
// Helpers shared by the test files (imported by path, so each test binary gets its own copy).
//

//
// The directory holding the golden fixtures and the bun scripts (tests run with the package directory as cwd).
//
pub const FIXTURES_DIR = "src/test/fixtures";

//
// The directory holding the checked in test databases.
//
pub const TEST_DBS_DIR = "../../test/dbs";

//
// The directory holding the TypeScript generated encryption keys of encryption-zig.
//
pub const KEYS_DIR = "../encryption-zig/src/test/fixtures";

//
// Allocator for state that lives as long as the test process (the environment and the worker pool).
//
const process_allocator = std.heap.page_allocator;

//
// The environment installed by setupEnvironment (null until it is called).
//
var environment: ?*std.process.Environ.Map = null;

//
// The per process directory holding the config dir, the vault and TEST_TMP_DIR.
//
var process_dir: []const u8 = "";

//
// The worker pool installed as the queue backend by setupEnvironment.
//
var worker_pool: ?*MockWorkerPool = null;

//
// The uuid generator of the worker pool's task contexts.
//
var pool_uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

//
// The timestamp provider of the worker pool's task contexts.
//
var pool_timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};

//
// Receives what the code under test writes to stdout with console.log (log.info), because the test runner uses
// stdout to talk to the build runner.
//
var discarded_stdout: std.Io.Writer.Discarding = .init(&.{});

//
// Creates an empty, unique temporary directory under the package's .zig-cache and returns its absolute path.
//
pub fn makeTempDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    var randomBytes: [8]u8 = undefined;
    io.random(&randomBytes);
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    const tempDir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp-tests/{s}-{s}", .{ currentPath, name, &std.fmt.bytesToHex(randomBytes, .lower) });
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, tempDir) catch {};
    try cwd.createDirPath(io, tempDir);
    return tempDir;
}

//
// Deletes a temporary directory created by makeTempDir.
//
pub fn removeTempDir(io: std.Io, tempDir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, tempDir) catch {};
}

//
// Sets up the process environment once per test binary: the inherited environment plus an isolated config dir
// (databases.toml), a plaintext vault, TEST_TMP_DIR, and a MockWorkerPool registered as the queue backend.
// Returns the per process directory.
//
pub fn setupEnvironment(io: std.Io) ![]const u8 {
    if (environment != null) {
        return process_dir;
    }
    utils.console.setCapture(&discarded_stdout.writer, null);
    process_dir = try makeTempDir(process_allocator, io, "process");
    const map = try process_allocator.create(std.process.Environ.Map);
    map.* = try std.testing.environ.createMap(process_allocator);
    try map.put("PHOTOSPHERE_CONFIG_DIR", try std.fmt.allocPrint(process_allocator, "{s}/config", .{process_dir}));
    try map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
    try map.put("PHOTOSPHERE_VAULT_DIR", try std.fmt.allocPrint(process_allocator, "{s}/vault", .{process_dir}));
    try map.put("TEST_TMP_DIR", try std.fmt.allocPrint(process_allocator, "{s}/test-tmp", .{process_dir}));
    _ = map.orderedRemove("PSI_ENCRYPTION_KEY");
    _ = map.orderedRemove("GOOGLE_API_KEY");
    _ = map.orderedRemove("AWS_ACCESS_KEY_ID");
    _ = map.orderedRemove("AWS_SECRET_ACCESS_KEY");
    _ = map.orderedRemove("AWS_REGION");
    _ = map.orderedRemove("AWS_ENDPOINT");
    node_utils.process_env.setEnvironMap(map);
    environment = map;

    worker_pool = try MockWorkerPool.init(io, 4, .{
        .uuidGenerator = pool_uuid_generator.uuidGenerator(),
        .timestampProvider = pool_timestamp_provider.timestampProvider(),
        .sessionId = "test-session",
    });
    task_queue_zig.queue_backend.setQueueBackend(worker_pool.?.queueBackend());
    return process_dir;
}

//
// Sets or removes an environment variable of the environment installed by setupEnvironment.
//
pub fn setEnv(name: []const u8, value: ?[]const u8) !void {
    const map = environment.?;
    if (value) |text| {
        try map.put(name, text);
    }
    else {
        _ = map.orderedRemove(name);
    }
}

//
// Gets the environment installed by setupEnvironment (for child processes).
//
pub fn getEnvironment() *std.process.Environ.Map {
    return environment.?;
}

//
// Copies a directory tree.
//
pub fn copyDirectory(allocator: std.mem.Allocator, io: std.Io, sourcePath: []const u8, destPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, destPath);
    var sourceDir = try cwd.openDir(io, sourcePath, .{ .iterate = true });
    defer sourceDir.close(io);
    var walker = try sourceDir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const targetPath = try std.fs.path.join(allocator, &.{ destPath, entry.path });
        switch (entry.kind) {
            .directory => try cwd.createDirPath(io, targetPath),
            .file => {
                const sourceFile = try std.fs.path.join(allocator, &.{ sourcePath, entry.path });
                const data = try cwd.readFileAlloc(io, sourceFile, allocator, .unlimited);
                if (std.fs.path.dirname(targetPath)) |parent| {
                    try cwd.createDirPath(io, parent);
                }
                try cwd.writeFile(io, .{ .sub_path = targetPath, .data = data });
            },
            else => {},
        }
    }
}

//
// Copies one of the checked in test databases (test/dbs/<name>) to a new temporary directory.
//
pub fn copyTestDatabase(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const tempDir = try makeTempDir(allocator, io, name);
    const databaseDir = try std.fmt.allocPrint(allocator, "{s}/db", .{tempDir});
    try copyDirectory(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ TEST_DBS_DIR, name }), databaseDir);
    return databaseDir;
}

//
// Creates a FileStorage rooted at a directory (the storage `createStorage(directory)` returns for a local path).
//
pub fn directoryStorage(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !IStorage {
    const created = try storage_zig.storage_factory.createStorage(allocator, io, directory, null, null);
    return created.storage;
}

//
// Writes a file (creating its directory).
//
pub fn writeFile(io: std.Io, filePath: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(filePath)) |dirPath| {
        try cwd.createDirPath(io, dirPath);
    }
    try cwd.writeFile(io, .{ .sub_path = filePath, .data = data });
}

//
// Reads a file.
//
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
}

//
// Returns true when a file exists.
//
pub fn fileExists(io: std.Io, filePath: []const u8) bool {
    std.Io.Dir.cwd().access(io, filePath, .{}) catch {
        return false;
    };
    return true;
}

//
// The output of a bun script.
//
pub const BunResult = struct {
    // What the script wrote to stdout.
    stdout: []const u8,

    // What the script wrote to stderr.
    stderr: []const u8,
};

//
// Runs a bun script of the fixtures directory with the environment installed by setupEnvironment plus the given
// overrides, and fails the test when it does not exit with 0.
//
pub fn runBun(allocator: std.mem.Allocator, io: std.Io, script: []const u8, arguments: []const []const u8, overrides: []const [2][]const u8) !BunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "bun", "run", try std.fmt.allocPrint(allocator, "{s}/{s}", .{ FIXTURES_DIR, script }) });
    try argv.appendSlice(allocator, arguments);
    var childEnvironment = try environment.?.clone(allocator);
    for (overrides) |override| {
        try childEnvironment.put(override[0], override[1]);
    }
    const result = std.process.run(allocator, io, .{ .argv = argv.items, .environ_map = &childEnvironment }) catch |err| {

        // The TypeScript side of the interop tests needs Bun; skip them where Bun cannot be spawned.
        if (err == error.FileNotFound) {
            return error.SkipZigTest;
        }
        return err;
    };
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("bun {s} failed:\n{s}\n{s}\n", .{ script, result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

//
// Runs a bun script and parses the last line of its stdout as JSON.
//
pub fn runBunJson(allocator: std.mem.Allocator, io: std.Io, script: []const u8, arguments: []const []const u8, overrides: []const [2][]const u8) !std.json.Value {
    const result = try runBun(allocator, io, script, arguments, overrides);
    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    const lastLineStart = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |index| index + 1 else 0;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed[lastLineStart..], .{});
}

//
// A progress callback that records every message (for tests).
//
pub const ProgressRecorder = struct {
    // Allocates the copies of the messages.
    allocator: std.mem.Allocator,

    // The recorded messages.
    messages: std.ArrayList([]const u8) = .empty,

    // Guards messages (callbacks may run on other threads).
    mutex: std.Io.Mutex = .init,

    //
    // Records a message.
    //
    pub fn record(self: *ProgressRecorder, message: []const u8) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.state.store(.unlocked, .release);
        const copy = self.allocator.dupe(u8, message) catch {
            return;
        };
        self.messages.append(self.allocator, copy) catch {};
    }
};

//
// Sorts a list of strings in place (for comparing lists whose order depends on task completion order).
//
pub fn sortStrings(strings: [][]const u8) void {
    std.mem.sort([]const u8, strings, {}, struct {
        fn lessThan(context: void, left: []const u8, right: []const u8) bool {
            _ = context;
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
}

//
// Gets the strings of a JSON array.
//
pub fn jsonStrings(allocator: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| {
        try strings.append(allocator, item.string);
    }
    return strings.items;
}

//
// Gets a JSON number as an integer.
//
pub fn jsonInteger(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => -1,
    };
}

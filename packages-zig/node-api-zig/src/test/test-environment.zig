const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const MockWorkerPool = task_queue_zig.mock_worker_pool.MockWorkerPool;
const temp_dirs = @import("temp-dirs.zig");
const console_capture = @import("console-capture.zig");

//
// The process wide environment of the test program: an isolated config dir, vault and temp dir, and a MockWorkerPool
// installed as the queue backend.
//

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
// Sets up the process environment once per test binary: the inherited environment plus an isolated config dir
// (databases.toml), a plaintext vault, TEST_TMP_DIR, and a MockWorkerPool registered as the queue backend.
// Returns the per process directory.
//
pub fn setupEnvironment(io: std.Io) ![]const u8 {
    if (environment != null) {
        return process_dir;
    }
    console_capture.endConsoleCapture();
    process_dir = try temp_dirs.makeTempDir(process_allocator, io, "process");
    const map = try process_allocator.create(std.process.Environ.Map);
    map.* = try std.testing.environ.createMap(process_allocator);
    try map.put("PHOTOSPHERE_CONFIG_DIR", try std.fmt.allocPrint(process_allocator, "{s}/config", .{process_dir}));
    try map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
    try map.put("PHOTOSPHERE_VAULT_DIR", try std.fmt.allocPrint(process_allocator, "{s}/vault", .{process_dir}));
    try map.put("TEST_TMP_DIR", try std.fmt.allocPrint(process_allocator, "{s}/test-tmp", .{process_dir}));
    // The scratch space the code under test writes to (an uploaded asset's resized copies, a session's temporary files) is inside the
    // directory this process owns, so two test programs running at once cannot reach each other's files.
    try map.put("PHOTOSPHERE_TMP_DIR", process_dir);
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
// Puts back the queue backend setupEnvironment installed (or none, before it has run), for a test that installed
// a backend of its own. Every test file runs in one test program, so a test that left its own backend in place (or
// none) would break the tests after it.
//
pub fn restoreQueueBackend() void {
    if (worker_pool) |pool| {
        task_queue_zig.queue_backend.setQueueBackend(pool.queueBackend());
    }
    else {
        task_queue_zig.queue_backend.setQueueBackend(null);
    }
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

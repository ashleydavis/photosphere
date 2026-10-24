const std = @import("std");
const test_timers = @import("test-timers.zig");
const node_utils = @import("node-utils-zig");
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");
const task_queue_zig = ziggy.task_queue;
const MockWorkerPool = task_queue_zig.mock_worker_pool.MockWorkerPool;
const temp_dirs = @import("temp-dirs.zig");
const lan_share_network = @import("lan-share-network-zig");

//
// The environment of one test: an isolated config dir, vault and temp dir in a directory of its own, an environment that points at
// them, and a MockWorkerPool installed as the test thread's queue backend, whose workers run the application's task handlers. Each
// test makes its own with setupEnvironment and frees it with deinit, so no test sees another's.
//

//
// Allocator for what an environment holds. Each test thread has its own, and the environment is made and freed on the thread that set
// it up: the pool keeps what it holds with its owning thread's allocator, and each worker makes its own.
//
threadlocal var environment_allocator: ziggy.thread_allocator.ThreadAllocator = .init;

//
// The tools of the test environment's pool: none, so a task that runs ImageMagick or FFmpeg is given no runner (see
// production-queue-backend.zig for a pool whose tasks are given one).
//
pub const NoTools = struct {
    pub fn init() NoTools {
        return .{};
    }

    pub fn runner(self: *NoTools) ?node_utils.in_process_tools.InProcessRunner {
        _ = self;
        return null;
    }
};

//
// Registers the media source builders on a task's thread before the task runs.
//
pub fn registerMediaSources(context: task_queue_zig.types.ITaskContext) anyerror!void {
    _ = context;
    try node_api.task_handlers.registerMediaSourceBuilders();
}

//
// The task types of the test environment's pool: every task handler of node-api.
//
const task_entries = node_api.task_handlers.taskEntries(NoTools, registerMediaSources);

//
// The environment of the test running on this thread, which setEnv changes, or null when none is set up.
//
threadlocal var current: ?*TestEnvironment = null;

//
// The environment of one test.
//
pub const TestEnvironment = struct {
    // The test's directory, holding the config dir, the vault and TEST_TMP_DIR.
    dir: []const u8,

    // The environment, installed as the test thread's process environment.
    map: *std.process.Environ.Map,

    // The worker pool installed as the test thread's queue backend.
    pool: *MockWorkerPool,

    // How many setupEnvironment calls share the environment and have not freed it yet (a test and a fixture it uses each set one
    // up).
    uses: u32,

    //
    // Ends one use of the environment. The last waits for the pool's tasks, stops its workers and puts the test thread's environment
    // and queue backend back to none.
    //
    pub fn deinit(self: *TestEnvironment) void {
        self.deinitWith(environment_allocator.allocator());
    }

    //
    // Ends one use of an environment set up with setupEnvironmentWith, given the same allocator.
    //
    pub fn deinitWith(self: *TestEnvironment, allocator: std.mem.Allocator) void {
        self.uses -= 1;
        if (self.uses > 0) {
            return;
        }
        self.pool.deinit(std.testing.io, allocator, test_timers.timers());
        task_queue_zig.queue_backend.setQueueBackend(null);
        node_utils.process_env.setEnvironMap(null);
        self.map.deinit();
        allocator.destroy(self.map);
        allocator.free(self.dir);
        if (current == self) {
            current = null;
        }
        allocator.destroy(self);
    }
};

//
// Sets up the environment of a test: the inherited environment plus an isolated config dir (databases.toml), a plaintext vault,
// TEST_TMP_DIR, and a MockWorkerPool installed as the queue backend. The returned value must be freed with deinit when the test ends
// (`defer test_env.deinit()`), and must not move: setEnv reaches it through its address. A call while the thread already has an
// environment (from a fixture inside a test that set one up) shares that one, and each call frees it once.
//
pub fn setupEnvironment(io: std.Io) !*TestEnvironment {
    return setupEnvironmentWith(io, environment_allocator.allocator());
}

//
// Sets up the environment of a test as setupEnvironment does, with everything it holds allocated with the given allocator, which must
// be the one the test passes to the code under test: the pool keeps the tasks queued on it with the allocator each call is given, so a
// thread's calls on its queue backend all use one allocator. Free it with deinitWith given the same allocator, which must outlive it.
//
pub fn setupEnvironmentWith(io: std.Io, allocator: std.mem.Allocator) !*TestEnvironment {
    if (current) |existing| {
        existing.uses += 1;
        return existing;
    }
    const dir = try temp_dirs.makeTempDir(allocator, io, "test");
    errdefer allocator.free(dir);
    const map = try allocator.create(std.process.Environ.Map);
    errdefer allocator.destroy(map);
    map.* = try std.testing.environ.createMap(allocator);
    errdefer map.deinit();
    try putJoined(allocator, map, "PHOTOSPHERE_CONFIG_DIR", dir, "config");
    try map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
    try putJoined(allocator, map, "PHOTOSPHERE_VAULT_DIR", dir, "vault");
    try putJoined(allocator, map, "TEST_TMP_DIR", dir, "test-tmp");
    // The scratch space the code under test writes to (an uploaded asset's resized copies, a session's temporary files) is inside the
    // directory this test owns, so two test programs running at once cannot reach each other's files.
    try map.put("PHOTOSPHERE_TMP_DIR", dir);
    // Discovery broadcasts go to one port for the whole machine, so this test uses a port of its own, or its receivers and senders hear
    // the ones of every other test program running at the same time.
    const discovery_port = try lan_share_network.socket.freeUdpPort();
    var port_buffer: [8]u8 = undefined;
    try map.put("PHOTOSPHERE_LAN_SHARE_PORT", try std.fmt.bufPrint(&port_buffer, "{d}", .{discovery_port}));
    _ = map.orderedRemove("PSI_ENCRYPTION_KEY");
    _ = map.orderedRemove("GOOGLE_API_KEY");
    _ = map.orderedRemove("AWS_ACCESS_KEY_ID");
    _ = map.orderedRemove("AWS_SECRET_ACCESS_KEY");
    _ = map.orderedRemove("AWS_REGION");
    _ = map.orderedRemove("AWS_ENDPOINT");
    node_utils.process_env.setEnvironMap(map);

    // The test's thread registers the media source builders for itself, and each task on its own thread.
    try node_api.task_handlers.registerMediaSourceBuilders();
    const pool = try MockWorkerPool.init(allocator, 4, .{
        .sessionId = "test-session",
    }, &task_entries);
    task_queue_zig.queue_backend.setQueueBackend(pool.queueBackend());

    const environment = try allocator.create(TestEnvironment);
    environment.* = .{
        .dir = dir,
        .map = map,
        .pool = pool,
        .uses = 1,
    };
    current = environment;
    return environment;
}

//
// Puts into the map the path of a directory inside the test's directory (the map keeps its own copy).
//
fn putJoined(allocator: std.mem.Allocator, map: *std.process.Environ.Map, name: []const u8, dir: []const u8, child: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, child });
    defer allocator.free(path);
    try map.put(name, path);
}

//
// Sets or removes an environment variable of the environment of the test running on this thread.
//
pub fn setEnv(name: []const u8, value: ?[]const u8) !void {
    const map = current.?.map;
    if (value) |text| {
        try map.put(name, text);
    }
    else {
        _ = map.orderedRemove(name);
    }
}

//
// Puts PHOTOSPHERE_TMP_DIR back to the test's directory, for a test that pointed it elsewhere.
//
pub fn restoreTmpDir() !void {
    try setEnv("PHOTOSPHERE_TMP_DIR", current.?.dir);
}

//
// Puts the test's worker pool back as the test thread's queue backend, for a test that installed a backend of its own.
//
pub fn restoreQueueBackend() void {
    task_queue_zig.queue_backend.setQueueBackend(current.?.pool.queueBackend());
}

//
// Gets the environment of the test running on this thread (for child processes).
//
pub fn getEnvironment() *std.process.Environ.Map {
    return current.?.map;
}

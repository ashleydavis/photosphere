const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");
const media_tools = @import("media-tools-zig");
const test_environment = @import("test-environment.zig");
const test_timers = @import("test-timers.zig");

const MediaTools = media_tools.MediaTools;
const MockWorkerPool = ziggy.task_queue.mock_worker_pool.MockWorkerPool;

//
// The task types of the pool: every task handler of node-api, each task that runs the tools making them on its own thread.
//
const task_entries = node_api.task_handlers.taskEntries(media_tools.ThreadTools, test_environment.registerMediaSources);

//
// A worker pool whose tasks make the runner of the tools built into the program (ImageMagick and FFmpeg) on their threads, as the app's
// do, for the tests whose tasks run them, which the pool of test_environment gives no runner. While it is started it is the test
// thread's queue backend; stopping it puts the test environment's pool back.
//
pub const ProductionQueueBackend = struct {
    // The pool.
    pool: *MockWorkerPool,

    // The tools built into the program, started for it, which the tools each task makes on its own thread need.
    mediaTools: MediaTools,

    //
    // Starts the pool, with the allocator the test passes to the code under test (which stop must be given too), and installs it as
    // the test thread's queue backend. It must not move once started.
    //
    pub fn start(self: *ProductionQueueBackend, allocator: std.mem.Allocator) !void {
        self.mediaTools = try MediaTools.init();
        errdefer self.mediaTools.deinit();
        // Two child tasks in flight at once and four workers, as the pool the other tests run on.
        self.pool = try MockWorkerPool.init(allocator, 4, .{
            .sessionId = "test-session",
            .maxConcurrentChildTasks = 2,
        }, &task_entries);
        ziggy.task_queue.queue_backend.setQueueBackend(self.pool.queueBackend());
    }

    //
    // Puts the test environment's pool back as the test thread's queue backend, waits for the tasks, stops the workers and releases
    // everything.
    //
    pub fn stop(self: *ProductionQueueBackend, log: ILog, allocator: std.mem.Allocator) void {
        test_environment.restoreQueueBackend();
        self.pool.deinit(std.testing.io, allocator, test_timers.timers(), log);
        self.mediaTools.deinit();
    }
};

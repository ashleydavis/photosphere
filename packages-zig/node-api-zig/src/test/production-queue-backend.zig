const std = @import("std");
const ziggy = @import("ziggy-core");
const media_tools = @import("media-tools-zig");
const test_environment = @import("test-environment.zig");

const MediaTools = media_tools.MediaTools;
const TaskRunner = ziggy.task_runner.TaskRunner;
const ZiggyQueueBackend = ziggy.queue_backend.ZiggyQueueBackend;

//
// The queue backend the Photosphere App runs its tasks on (Ziggy's ZiggyQueueBackend over Ziggy's TaskRunner), set up the way
// Ziggy's core sets it up, with its tool runner set to the runner of tools built into the program, as MainState sets it. It is for
// the tests whose tasks run ImageMagick or FFmpeg, which the MockWorkerPool of test_environment cannot give a runner. While it is
// started it is the queue backend the task queue talks to; stopping it puts the MockWorkerPool back.
//
pub const ProductionQueueBackend = struct {
    // The runner that owns the worker threads. Its threads hold its address, so this must not move once started.
    runner: TaskRunner,

    // The queue backend over the runner. Owned.
    backend: *ZiggyQueueBackend,

    // The tools built into the program, whose runner the handlers are given.
    mediaTools: MediaTools,

    //
    // Starts the runner's threads and installs the backend as the task queue's backend. The task handlers must already be
    // registered with the task queue (initTaskHandlers), which is where the runner finds them.
    //
    pub fn start(self: *ProductionQueueBackend, io: std.Io) !void {
        // The backend and the runner are used from every worker thread, so their allocator must be thread safe.
        const allocator = std.heap.smp_allocator;
        self.mediaTools = try MediaTools.init(io);
        errdefer self.mediaTools.deinit();
        self.backend = try ZiggyQueueBackend.create(allocator, io, &self.runner);
        errdefer self.backend.destroy();
        self.backend.tool_runner = self.mediaTools.runner();
        // Two child tasks in flight at once and four worker threads, as the MockWorkerPool the other tests run on.
        try self.runner.start(allocator, io, .{
            .user_data = null,
            .emit = ignoreShellEvent,
        }, &.{}, .{
            .worker_threads = 4,
            .max_concurrent_child_tasks = 2,
            .describe_error = null,
            .observer = .{
                .user_data = self.backend,
                .on_task_end = observeTaskEnd,
                .on_task_message = observeTaskMessage,
            },
            .fallback_handler = ziggy.queue_backend.fallbackHandler(self.backend),
        }, .{
            .user_data = null,
            .deliver = null,
            .os_version = null,
            .quit = null,
            .pick_paths = null,
            .menu_action = null,
            .keep_alive = null,
            .worker_threads = 4,
            .max_concurrent_child_tasks = 2,
            .app_url_prefix = "",
            .data_dir = "",
            .test_mode = false,
            .test_port_file = null,
            .host_request = null,
            .screenshot = null,
        });
        ziggy.task_queue.queue_backend.setQueueBackend(self.backend.queueBackend());
    }

    //
    // Puts the MockWorkerPool back as the task queue's backend, cancels every task, waits for the worker threads and releases
    // everything, as Ziggy's core does when it is destroyed.
    //
    pub fn stop(self: *ProductionQueueBackend) void {
        test_environment.restoreQueueBackend();
        self.runner.stop();
        self.backend.destroy();
        self.mediaTools.deinit();
    }
};

//
// The runner's events for the shell (task-message and task-completed as JSON text). The test program has no shell; the backend
// learns of every task end and message through the observer, as it does in the App.
//
fn ignoreShellEvent(user_data: ?*anyopaque, message: []const u8) void {
    _ = user_data;
    _ = message;
}

//
// Tells the backend a task has ended, as Ziggy's core does.
//
fn observeTaskEnd(user_data: ?*anyopaque, end: ziggy.types.TaskEnd) void {
    const backend: *ZiggyQueueBackend = @ptrCast(@alignCast(user_data.?));
    backend.taskEnded(end);
}

//
// Tells the backend a task has sent a message, as Ziggy's core does.
//
fn observeTaskMessage(user_data: ?*anyopaque, sent: ziggy.types.TaskSentMessage) void {
    const backend: *ZiggyQueueBackend = @ptrCast(@alignCast(user_data.?));
    backend.messageSent(sent);
}

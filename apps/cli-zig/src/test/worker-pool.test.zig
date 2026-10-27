const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");
const ziggy = @import("ziggy");
const task_queue = ziggy.task_queue;
const media_tools = @import("media-tools-zig");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const types = task_queue.types;
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;

//
// The results collected by the completion callback of a test.
//
pub const Collector = struct {
    // The allocator the text of each result is copied into (the arena of the test, which outlives the
    // collector). The text is copied because it belongs to the result, which the pool frees as soon as
    // the callbacks have run, and it is not kept in a fixed buffer because its length is not known here: a
    // handler's error message can be any length, and a fixed buffer overflowed and took the whole test
    // binary down.
    allocator: std.mem.Allocator,

    // Number of completed tasks.
    completed: usize = 0,

    // Number of failed tasks.
    failed: usize = 0,

    // The error message of the last failed task.
    lastErrorMessage: []const u8 = &.{},

    // The error name of the last failed task.
    lastErrorName: []const u8 = &.{},

    // The string output of the last successful task.
    lastOutput: []const u8 = &.{},

    // Number of messages received by the typed message callback.
    typedMessages: usize = 0,

    // Number of messages received by the any-message callback.
    anyMessages: usize = 0,

    // Number of tasks added (onTaskAdded).
    added: usize = 0,

    // Number of cancellations (onTasksCancelled).
    cancellations: usize = 0,

    //
    // Creates a collector that copies the text of each result into the allocator.
    //
    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
        };
    }

    //
    // The completion callback.
    //
    pub fn onComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, _: ILog, result: types.ITaskResult) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.completed += 1;
        if (result.status == .Failed) {
            self.failed += 1;
            const message = result.errorMessage orelse "";
            self.lastErrorMessage = try self.allocator.dupe(u8, message);
            const name = result.@"error".?.name;
            self.lastErrorName = try self.allocator.dupe(u8, name);
        }
        else {
            if (result.outputs) |outputs| {
                if (outputs == .string) {
                    self.lastOutput = try self.allocator.dupe(u8, outputs.string);
                }
            }
        }
    }

    //
    // The typed message callback.
    //
    fn onTypedMessage(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, _: ILog, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.typedMessages += 1;
        _ = data;
    }

    //
    // The any-message callback.
    //
    fn onAnyMessage(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, _: ILog, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.anyMessages += 1;
        _ = data;
    }

    //
    // The onTaskAdded callback.
    //
    fn onAdded(context: ?*anyopaque, allocator: std.mem.Allocator, _: ILog, taskId: []const u8) void {
        _ = allocator;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        _ = taskId;
        self.added += 1;
    }

    //
    // The onTasksCancelled callback.
    //
    fn onCancelled(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.cancellations += 1;
    }

    //
    // Reads the pool's messages on this thread, its main thread, until the number of completed tasks reaches the count. A task that
    // never ends fails at the pool's timeout, so the wait always ends. The allocator is the one the pool was made with.
    //
    pub fn waitForCompleted(self: *Collector, log: ILog, pool: *WorkerPoolBun, allocator: std.mem.Allocator, timers: Timers, count: usize) !void {
        while (self.completed < count) {
            pool.waitForMessage(std.testing.io, allocator, timers, log);
        }
    }
};

//
// Reads the pool's messages without waiting for one, for the number of milliseconds, for a test that waits on something other than
// a task's end. The allocator is the one the pool was made with.
//
fn readMessagesFor(pool: *WorkerPoolBun, log: ILog, allocator: std.mem.Allocator, timers: Timers, milliseconds: usize) void {
    var waited: usize = 0;
    while (waited < milliseconds) {
        pool.handleQueuedMessages(std.testing.io, log, allocator, timers);
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        waited += 5;
    }
    pool.handleQueuedMessages(std.testing.io, log, allocator, timers);
}

//
// Adds a task to the pool, with the allocator the pool was made with, and frees the id the pool returns.
//
fn addTask(pool: *WorkerPoolBun, log: ILog, allocator: std.mem.Allocator, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8) !void {
    const id = try pool.addTask(allocator, std.testing.io, log, @"type", data, source, taskId, null);
    allocator.free(id);
}

//
// Returns the text of the task data.
//
fn echoHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = io;
    _ = context;
    return .{ .string = try std.fmt.allocPrint(allocator, "echo {s}", .{data.string}) };
}

//
// Always fails.
//
fn failingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return utils.errors.throwError("boom {d}", .{42});
}

//
// Sends two messages, one of type "progress".
//
fn messagingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = timers;
    _ = data;
    var progress: std.json.ObjectMap = .empty;
    try progress.put(allocator, "type", .{ .string = "progress" });
    context.sendEvent(io, allocator, log, .{ .object = progress });
    var other: std.json.ObjectMap = .empty;
    try other.put(allocator, "type", .{ .string = "other" });
    context.sendEvent(io, allocator, log, .{ .object = other });
    return .null;
}

//
// The queues the blocking tasks tell the test thread they started and ended through, and the test thread releases them through.
//
var blocking_queues: helpers.BlockingTaskQueues = .init();

//
// Blocks until released (or cancelled), telling the test thread when it starts and ends.
//
fn blockingHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = data;
    blocking_queues.runBlockingTask(io, allocator, context);
    return .null;
}

//
// Sleeps longer than the timeout of the timeout test.
//
fn slowHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = allocator;
    _ = data;
    _ = context;
    io.sleep(.fromMilliseconds(300), .awake) catch {};
    return .null;
}

//
// Runs `magick -version` through the tools built into the program, made on the task's thread, and returns what it printed.
//
fn magickVersionHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, _: types.ITaskContext) anyerror!std.json.Value {
    _ = timers;
    _ = data;
    var tools = media_tools.ThreadTools.init();
    const result = try node_utils.exec.exec(allocator, io, log, tools.runner(), "magick -version");
    return .{ .string = result.stdout };
}

//
// The task types the workers of the tests run.
//
pub const test_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "echo", .handler = ziggy.task_runner.fromQueueHandler(echoHandler) },
    .{ .name = "fail", .handler = ziggy.task_runner.fromQueueHandler(failingHandler) },
    .{ .name = "message", .handler = ziggy.task_runner.fromQueueHandler(messagingHandler) },
    .{ .name = "block", .handler = ziggy.task_runner.fromQueueHandler(blockingHandler) },
    .{ .name = "slow", .handler = ziggy.task_runner.fromQueueHandler(slowHandler) },
    .{ .name = "magick-version", .handler = ziggy.task_runner.fromQueueHandler(magickVersionHandler) },
};

test "runs a task on a worker and reports its outputs" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 2, 10000, .{ .sessionId = "session", .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    const backend = pool.queueBackend();
    var collector = Collector.init(arena.allocator());
    _ = try backend.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    const taskId = try backend.addTask(allocator, std.testing.io, log, "echo", .{ .string = "hi" }, "source", "task-1", null);
    defer allocator.free(taskId);
    try std.testing.expectEqualStrings("task-1", taskId);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 1);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
    try std.testing.expectEqualStrings("echo hi", collector.lastOutput);
}

test "a worker that fails to start is logged and replaced, and its task waits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory = try utils.memory_log.MemoryLog.init(allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();

    // The test UUID generator keeps its counter under TEST_TMP_DIR: below a file, that directory cannot be
    // created, so generating the session ID of every worker fails.
    const root = try helpers.makeTempDir(allocator, "worker-pool-start-failure");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const blockingFile = try std.fs.path.join(allocator, &.{ root, "file" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = blockingFile, .data = "x" });
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("NODE_ENV", "testing");
    try environ_map.put("TEST_TMP_DIR", try std.fs.path.join(allocator, &.{ blockingFile, "tmp" }));
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    const pool_allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(pool_allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(pool_allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, memory.log, pool_allocator, "echo", .{ .string = "x" }, "source", null);
    readMessagesFor(pool, memory.log, pool_allocator, timer_list.interface(), 100);
    pool.deinit(std.testing.io, pool_allocator);

    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Error from worker 1\n") != null);
    try std.testing.expectEqual(@as(usize, 0), collector.completed);
}

test "generates a task ID when none is given" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    const taskId = try pool.addTask(allocator, std.testing.io, log, "echo", .{ .string = "x" }, "source", null, null);
    defer allocator.free(taskId);
    try std.testing.expectEqual(@as(usize, 36), taskId.len);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 1);
}

test "reports a failed task with the error name and message" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, log, allocator, "fail", .null, "source", null);
    try addTask(pool, log, allocator, "no-such-type", .null, "source", null);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 2);
    try std.testing.expectEqual(@as(usize, 2), collector.failed);
    try std.testing.expectEqualStrings("Error", collector.lastErrorName);
    // A Ziggy worker fails a task of a type it was not given as UnknownTaskType.
    try std.testing.expectEqualStrings("UnknownTaskType", collector.lastErrorMessage);
}

test "forwards task messages to the message callbacks" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.onTaskEvent(allocator, "progress", .{ .context = &collector, .function = Collector.onTypedMessage });
    const unsubscribe = try pool.onAnyTaskEvent(allocator, .{ .context = &collector, .function = Collector.onAnyMessage });
    try addTask(pool, log, allocator, "message", .null, "source", null);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 1);
    try std.testing.expectEqual(@as(usize, 1), collector.typedMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);

    unsubscribe.call(allocator);
    try addTask(pool, log, allocator, "message", .null, "source", null);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 2);
    try std.testing.expectEqual(@as(usize, 2), collector.typedMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);
}

test "creates workers lazily up to maxWorkers" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    blocking_queues.reset();
    var blocking: helpers.BlockingTaskCount = .{};
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 2, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    var index: usize = 0;
    while (index < 4) {
        try addTask(pool, log, allocator, "block", .null, "source", null);
        index += 1;
    }
    var waited: usize = 0;
    while (blocking.running < 2 and waited < 2000) {
        pool.handleQueuedMessages(std.testing.io, log, allocator, timer_list.interface());
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        blocking.readEvents(&blocking_queues, allocator);
        waited += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), pool.workers.items.len);
    blocking_queues.release.close(std.testing.io);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 4);
    blocking.readEvents(&blocking_queues, allocator);
    try std.testing.expectEqual(@as(usize, 2), blocking.maxRunning);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
}

test "times out a task, reports it failed and replaces the worker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory = try utils.memory_log.MemoryLog.init(allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    // The pool abandons the timed out worker, whose memory is never freed and which its thread goes on using, so the pool is made
    // with an allocator that is never freed and does not count leaks.
    const pool_allocator = std.heap.smp_allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(pool_allocator, &mediaTools, 1, 50, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, pool_allocator);
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(pool_allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, memory.log, pool_allocator, "slow", .null, "source", "slow-task");
    try addTask(pool, memory.log, pool_allocator, "echo", .{ .string = "after" }, "source", "echo-task");
    try collector.waitForCompleted(memory.log, pool, pool_allocator, timer_list.interface(), 2);
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("echo after", collector.lastOutput);
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "[Task Queue] Task slow-task timed out after 50ms\n") != null);
    try std.testing.expectEqual(@as(usize, 1), pool.workers.items.len);
    try std.testing.expectEqual(@as(u32, 1), pool.workers.items[0].workerId);
}

test "a worker abandoned at its timeout can still send once the pool is gone, and what it sends is dropped" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    // The pool abandons the timed out worker, whose memory is never freed and which its thread goes on using, so the pool is made
    // with an allocator that is never freed and does not count leaks.
    const pool_allocator = std.heap.smp_allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(pool_allocator, &mediaTools, 1, 50, .{ .tasks = &test_tasks });
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(pool_allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, log, pool_allocator, "slow", .null, "source", "slow-task");
    try collector.waitForCompleted(log, pool, pool_allocator, timer_list.interface(), 1);
    try std.testing.expect(pool.abandonedWorkers);
    const queue = pool.mainQueue;
    pool.deinit(std.testing.io, pool_allocator);

    // The pool kept its queue for the abandoned worker and closed it, so the end the worker sends once its task has run its 300 ms
    // is dropped.
    try std.testing.expect(queue.isClosed(std.testing.io));
    try std.testing.io.sleep(.fromMilliseconds(600), .awake);
    try std.testing.expect(queue.tryTake(std.testing.io, allocator) == null);
}

test "the timeout message writes the timeout as a template string writes a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory = try utils.memory_log.MemoryLog.init(allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    // `--timeout 0.0000001`: the timer waits 1 ms, and the message writes the timeout as 1e-7.
    // The pool abandons the timed out worker, whose memory is never freed and which its thread goes on using, so the pool is made
    // with an allocator that is never freed and does not count leaks.
    const pool_allocator = std.heap.smp_allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(pool_allocator, &mediaTools, 1, 1e-7, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, pool_allocator);
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(pool_allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, memory.log, pool_allocator, "slow", .null, "source", "slow-task");
    try collector.waitForCompleted(memory.log, pool, pool_allocator, timer_list.interface(), 1);
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "[Task Queue] Task slow-task timed out after 1e-7ms\n") != null);
}

test "cancelTasks drops pending tasks and signals running tasks" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    blocking_queues.reset();
    var blocking: helpers.BlockingTaskCount = .{};
    const pool_allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(pool_allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, pool_allocator);
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(pool_allocator, .{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.onTaskAdded(pool_allocator, "db", .{ .context = &collector, .function = Collector.onAdded });
    _ = try pool.onTasksCancelled(pool_allocator, "db", .{ .context = &collector, .function = Collector.onCancelled });
    try addTask(pool, log, pool_allocator, "block", .null, "db", null);
    try addTask(pool, log, pool_allocator, "block", .null, "db", null);
    try addTask(pool, log, pool_allocator, "echo", .{ .string = "other" }, "other-source", null);
    try std.testing.expectEqual(@as(usize, 2), collector.added);
    var waited: usize = 0;
    while (blocking.running < 1 and waited < 2000) {
        pool.handleQueuedMessages(std.testing.io, log, pool_allocator, timer_list.interface());
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        blocking.readEvents(&blocking_queues, pool_allocator);
        waited += 1;
    }
    pool.cancelTasks(std.testing.io, pool_allocator, log, "db");
    try std.testing.expectEqual(@as(usize, 1), collector.cancellations);
    try collector.waitForCompleted(log, pool, pool_allocator, timer_list.interface(), 2);
    readMessagesFor(pool, log, pool_allocator, timer_list.interface(), 50);
    try std.testing.expectEqual(@as(usize, 2), collector.completed);
    try std.testing.expectEqualStrings("echo other", collector.lastOutput);
}

test "shutdown terminates the workers" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 2, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, log, allocator, "echo", .{ .string = "x" }, "source", null);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 1);
    pool.queueBackend().shutdown(std.testing.io, allocator);
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);
}

test "a task on a worker runs the tools built into the program, made on its own thread" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    try addTask(pool, log, allocator, "magick-version", .null, "source", null);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 1);
    try std.testing.expectEqualStrings("", collector.lastErrorMessage);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);

    // What the task printed is the version of the ImageMagick built into the program, read here from the library itself.
    const builtInVersion = (try media_tools.ImageMagick.runMagick(std.testing.io, log, arena.allocator(), &.{"-version"})).output;
    try std.testing.expect(std.mem.indexOf(u8, builtInVersion, "Version: ImageMagick ") != null);
    try std.testing.expectEqualStrings(builtInVersion, collector.lastOutput);
}

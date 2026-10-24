//
// Tests of the infrastructure ports that no other test file covers: the signal handlers, the error and shutdown paths of the
// worker pool, the parts of the argument parser the golden fixtures cannot reach, and the colour depth of a
// terminal.
//

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const ziggy = @import("ziggy");
const task_queue = ziggy.task_queue;
const MessageQueue = ziggy.message_queue.MessageQueue;
const media_tools = @import("media-tools-zig");
const helpers = @import("test-helpers.zig");

const process_signals = cli.process_signals;
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const commander = cli.commander;
const Command = commander.Command;
const picocolors = cli.picocolors;
const tty = cli.tty;
const types = task_queue.types;
const Timers = ziggy.timers.Timers;
const TimerList = ziggy.timers.TimerList;

//
// The captured console output of a test.
//
const Capture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,

    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,
};

//
// Starts capturing the console output into the given captures.
//
fn startCapture(allocator: std.mem.Allocator, capture: *Capture) void {
    capture.* = .{
        .stdout = .init(allocator),
        .stderr = .init(allocator),
    };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
}

//
// Counts the calls of a signal listener.
//
fn countSignalCalls(context: *anyopaque) void {
    const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));
    _ = calls.fetchAdd(1, .acq_rel);
}

//
// The state a listener that removes itself keeps.
//
const ISelfRemovingListener = struct {
    // The number of calls of the listener.
    calls: *std.atomic.Value(u32),

    // The signal the listener is registered for.
    signal: process_signals.Signal,
};

//
// Counts its call and then removes itself from the signal it is registered for.
//
fn selfRemovingSignalListener(context: *anyopaque) void {
    const state: *ISelfRemovingListener = @ptrCast(@alignCast(context));
    _ = state.calls.fetchAdd(1, .acq_rel);
    process_signals.removeListener(state.signal, .{
        .context = context,
        .function = selfRemovingSignalListener,
    }) catch @panic("removing a signal listener failed");
}

//
// Raises a signal and waits until the given counter has changed (fails after 10 seconds).
//
fn raiseAndWaitForCall(signal: process_signals.Signal, calls: *std.atomic.Value(u32)) !void {
    const before = calls.load(.acquire);
    switch (signal) {
        .SIGINT => try std.posix.raise(.INT),
        .SIGTERM => try std.posix.raise(.TERM),
    }
    var waited: u32 = 0;
    while (calls.load(.acquire) == before and waited < 10000) {
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        waited += 5;
    }
    try std.testing.expectEqual(true, waited < 10000);
}

test "the signal handlers hold a fixed number of listeners and call every one of them" {
    if (builtin.os.tag == .windows) {
        // On Windows SIGTERM is never received, so only SIGINT installs anything, and Ctrl+C cannot be
        // generated without stopping the process group of the build runner that started this test.
        return error.SkipZigTest;
    }

    // More listeners than the module can hold, so the limit is reached without naming it.
    var calls: [64]std.atomic.Value(u32) = undefined;
    for (&calls) |*counter| {
        counter.* = .init(0);
    }
    var registered: usize = 0;
    defer {
        for (calls[0..registered]) |*counter| {
            process_signals.removeListener(.SIGTERM, .{
                .context = counter,
                .function = countSignalCalls,
            }) catch @panic("removing a signal listener failed");
        }
    }

    var failure: ?anyerror = null;
    while (registered < calls.len) : (registered += 1) {
        process_signals.on(.SIGTERM, .{
            .context = &calls[registered],
            .function = countSignalCalls,
        }) catch |err| {
            failure = err;
            break;
        };
    }
    try std.testing.expectEqual(@as(?anyerror, error.TooManySignalListeners), failure);
    try std.testing.expectEqual(true, registered > 1);

    try raiseAndWaitForCall(.SIGTERM, &calls[registered - 1]);
    for (calls[0..registered]) |*counter| {
        try std.testing.expectEqual(@as(u32, 1), counter.load(.acquire));
    }
}

test "removing a listener that is not registered leaves the others alone" {
    if (builtin.os.tag == .windows) {
        // Ctrl+C cannot be generated without stopping the process group of the build runner that started
        // this test.
        return error.SkipZigTest;
    }

    var registered = std.atomic.Value(u32).init(0);
    var never = std.atomic.Value(u32).init(0);
    const registeredListener: process_signals.ISignalListener = .{ .context = &registered, .function = countSignalCalls };
    try process_signals.on(.SIGINT, registeredListener);
    defer process_signals.removeListener(.SIGINT, registeredListener) catch @panic("removing a signal listener failed");

    // Nothing matches this listener, so the signal's handler stays installed and the other one is called.
    try process_signals.removeListener(.SIGINT, .{ .context = &never, .function = countSignalCalls });

    try raiseAndWaitForCall(.SIGINT, &registered);
    try std.testing.expectEqual(@as(u32, 1), registered.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), never.load(.acquire));
}

test "a listener may remove itself while the signal is delivered and the others still run" {
    if (builtin.os.tag == .windows) {
        // Ctrl+C cannot be generated without stopping the process group of the build runner that started
        // this test.
        return error.SkipZigTest;
    }

    var ownCalls = std.atomic.Value(u32).init(0);
    var otherCalls = std.atomic.Value(u32).init(0);
    var state = ISelfRemovingListener{ .calls = &ownCalls, .signal = .SIGTERM };
    const self: process_signals.ISignalListener = .{ .context = &state, .function = selfRemovingSignalListener };
    const other: process_signals.ISignalListener = .{ .context = &otherCalls, .function = countSignalCalls };
    try process_signals.on(.SIGTERM, self);
    try process_signals.on(.SIGTERM, other);
    // The first listener removed itself, so this only takes the other one away.
    defer process_signals.removeListener(.SIGTERM, other) catch @panic("removing a signal listener failed");

    // Both are called, although the first one unregisters itself while the list is being delivered.
    try raiseAndWaitForCall(.SIGTERM, &ownCalls);
    try std.testing.expectEqual(@as(u32, 1), ownCalls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), otherCalls.load(.acquire));

    // The second signal only reaches the listener that is still registered.
    try raiseAndWaitForCall(.SIGTERM, &otherCalls);
    try std.testing.expectEqual(@as(u32, 1), ownCalls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), otherCalls.load(.acquire));
}

test "the console log writes no tool output for an empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: Capture = undefined;
    startCapture(arena.allocator(), &capture);
    defer utils.console.setCapture(null, null);

    var log = cli.log.Log.init(.{ .tools = true });
    log.tool("magick", .{ .stdout = "", .stderr = "" });
    log.tool("magick", .{ .stdout = null, .stderr = null });

    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

//
// The counts a test's callbacks collect.
//
const PoolCollector = struct {
    // The number of completed tasks.
    completed: usize = 0,

    // The number of failed tasks.
    failed: usize = 0,

    // The number of typed task messages.
    typedMessages: usize = 0,

    // The number of any task messages.
    anyMessages: usize = 0,

    // The labels the tasks sent, in the order they were sent (the text is copied, because the message it
    // came from belongs to a task that is freed when the task completes).
    labelText: [8][32]u8 = undefined,

    // The length of each label.
    labelLengths: [8]usize = undefined,

    // The number of labels.
    labelCount: usize = 0,

    //
    // The completion callback.
    //
    fn onComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, result: types.ITaskResult) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        const self: *PoolCollector = @ptrCast(@alignCast(context.?));
        self.completed += 1;
        if (result.status == .Failed) {
            self.failed += 1;
        }
    }

    //
    // The typed task message callback.
    //
    fn onTypedMessage(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        _ = data;
        const self: *PoolCollector = @ptrCast(@alignCast(context.?));
        self.typedMessages += 1;
    }

    //
    // The task message callback that records the label of each message.
    //
    fn onLabelMessage(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        const self: *PoolCollector = @ptrCast(@alignCast(context.?));
        self.anyMessages += 1;
        if (self.labelCount < self.labelText.len) {
            const label = data.event.object.get("label") orelse return;
            const length = @min(label.string.len, self.labelText[self.labelCount].len);
            @memcpy(self.labelText[self.labelCount][0..length], label.string[0..length]);
            self.labelLengths[self.labelCount] = label.string.len;
            self.labelCount += 1;
        }
    }

    //
    // Reads the pool's messages on this thread, its main thread, until the number of completed tasks reaches the count. A task that
    // never ends fails at the pool's timeout, so the wait always ends.
    //
    fn waitForCompleted(self: *PoolCollector, pool: *WorkerPoolBun, allocator: std.mem.Allocator, timers: Timers, count: usize) !void {
        while (self.completed < count) {
            pool.waitForMessage(std.testing.io, allocator, timers);
        }
    }
};

//
// A completion callback that always fails.
//
fn failingCompletionCallback(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, result: types.ITaskResult) anyerror!void {
    _ = io;
    _ = allocator;
    _ = timers;
    _ = context;
    _ = result;
    return error.CallbackFailed;
}

//
// A typed task message callback that always fails.
//
fn failingMessageCallback(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, data: types.ITaskEventData) anyerror!void {
    _ = io;
    _ = allocator;
    _ = timers;
    _ = context;
    _ = data;
    return error.CallbackFailed;
}

//
// The one task type the tests that use the pool register. The data of such a task says what it should do: a
// kind ("echo", "label" or "block") and the text it works with. One short name on purpose: the message of
// the no-handler case lists every registered task type, and worker-pool.test.zig copies that message into a
// fixed 256-byte buffer, so every name registered anywhere brings that buffer closer to overflowing.
//
const task_type = "ca";

//
// The queues the blocking tasks tell the test thread they started and ended through, and the test thread releases them through.
//
var blocking_queues: helpers.BlockingTaskQueues = .init();

//
// Runs the task its data asks for: "echo" returns the text, "label" sends the text as a message of the type
// the tests listen for, and "block" blocks until it is released or cancelled.
//
fn testHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = timers;
    const kind = data.object.get("kind") orelse return .null;
    const text = data.object.get("text") orelse return .null;
    if (std.mem.eql(u8, kind.string, "echo")) {
        return .{ .string = try std.fmt.allocPrint(allocator, "echo {s}", .{text.string}) };
    }
    if (std.mem.eql(u8, kind.string, "label")) {
        var message: std.json.ObjectMap = .empty;
        try message.put(allocator, "type", .{ .string = "label" });
        try message.put(allocator, "label", .{ .string = text.string });
        context.sendEvent(io, allocator, .{ .object = message });
        return .null;
    }
    if (std.mem.eql(u8, kind.string, "block")) {
        blocking_queues.runBlockingTask(io, allocator, context);
        return .null;
    }
    return .null;
}

//
// Builds the data of a test task.
//
fn taskData(allocator: std.mem.Allocator, kind: []const u8, text: []const u8) !std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(allocator, "kind", .{ .string = kind });
    try data.put(allocator, "text", .{ .string = text });
    return .{ .object = data };
}

//
// Reads the pool's messages until a blocking task is running, so the worker's "ready" is read and the task is given to it (fails
// after 10 seconds). The running task sends nothing more, so the messages are read without waiting for one.
//
fn waitForBlockingTask(pool: *WorkerPoolBun, allocator: std.mem.Allocator, timers: Timers) !void {
    var blocking: helpers.BlockingTaskCount = .{};
    var waited: u32 = 0;
    while (blocking.running == 0 and waited < 10000) {
        pool.handleQueuedMessages(std.testing.io, allocator, timers);
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        blocking.readEvents(&blocking_queues, allocator);
        waited += 5;
    }
    try std.testing.expectEqual(true, waited < 10000);
}

//
// The task types the workers of the tests that use the pool run.
//
const test_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = task_type, .handler = ziggy.task_runner.fromQueueHandler(testHandler) },
};

test "a completion callback that fails is logged and the task still finishes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var capture: Capture = undefined;
    startCapture(allocator, &capture);
    defer utils.console.setCapture(null, null);

    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var timer_list = TimerList.init();
    var collector = PoolCollector{};
    // The failing callback is registered first, so its message is logged before the collector reports the
    // task as completed and the test can read it.
    _ = try pool.onTaskComplete(allocator, .{ .context = null, .function = failingCompletionCallback });
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = PoolCollector.onComplete });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "echo", "hi"), "source", "task-1", null);
    try collector.waitForCompleted(pool, allocator, timer_list.interface(), 1);

    try std.testing.expectEqual(@as(usize, 1), collector.completed);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);

    // The callback runs on the main thread, so its failure goes to the main thread's log, with no worker prefix.
    try std.testing.expectEqualStrings(
        \\Error in task completion callback
        \\Error: CallbackFailed
        \\
    , capture.stderr.written());
}

test "a task message callback that fails is logged and the other callbacks still run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var capture: Capture = undefined;
    startCapture(allocator, &capture);
    defer utils.console.setCapture(null, null);

    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var timer_list = TimerList.init();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = PoolCollector.onComplete });
    _ = try pool.onTaskEvent(allocator, "label", .{ .context = null, .function = failingMessageCallback });
    _ = try pool.onTaskEvent(allocator, "label", .{ .context = &collector, .function = PoolCollector.onTypedMessage });
    _ = try pool.onAnyTaskEvent(allocator, .{ .context = null, .function = failingMessageCallback });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "hello"), "source", "task-2", null);
    try collector.waitForCompleted(pool, allocator, timer_list.interface(), 1);

    try std.testing.expectEqual(@as(usize, 1), collector.typedMessages);

    // The callbacks run on the main thread, so their failures go to the main thread's log, with no worker prefix.
    try std.testing.expectEqualStrings(
        \\Error in task message callback
        \\Error: CallbackFailed
        \\Error in any task message callback
        \\Error: CallbackFailed
        \\
    , capture.stderr.written());
}

//
// Counts the calls of each kind of callback, so that a test can tell which ones still fire.
//
const RemovalCounter = struct {

    // The number of calls of onTaskAdded, onTaskComplete and the message callbacks together.
    calls: usize = 0,

    // The number of onTasksCancelled calls.
    cancelled: usize = 0,

    //
    // Counts one call.
    //
    fn count(context: ?*anyopaque) void {
        const self: *RemovalCounter = @ptrCast(@alignCast(context.?));
        self.calls += 1;
    }

    //
    // The onTaskAdded callback.
    //
    fn onAdded(context: ?*anyopaque, allocator: std.mem.Allocator, taskId: []const u8) void {
        _ = allocator;
        _ = taskId;
        count(context);
    }

    //
    // The completion callback.
    //
    fn onComplete(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, result: types.ITaskResult) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        _ = result;
        count(context);
    }

    //
    // The task message callback.
    //
    fn onMessage(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, data: types.ITaskEventData) anyerror!void {
        _ = io;
        _ = allocator;
        _ = timers;
        _ = data;
        count(context);
    }

    //
    // The onTasksCancelled callback.
    //
    fn onCancelled(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        _ = allocator;
        const self: *RemovalCounter = @ptrCast(@alignCast(context.?));
        self.cancelled += 1;
    }
};

test "unsubscribing stops a callback of every kind from being called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var timer_list = TimerList.init();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = PoolCollector.onComplete });

    // One callback of each kind, and one more of each kind that is unsubscribed straight away.
    var removed = RemovalCounter{};
    var kept = RemovalCounter{};
    const addedUnsubscribe = try pool.onTaskAdded(allocator, "db", .{ .context = &removed, .function = RemovalCounter.onAdded });
    const completeUnsubscribe = try pool.onTaskComplete(allocator, .{ .context = &removed, .function = RemovalCounter.onComplete });
    const messageUnsubscribe = try pool.onTaskEvent(allocator, "label", .{ .context = &removed, .function = RemovalCounter.onMessage });
    const anyMessageUnsubscribe = try pool.onAnyTaskEvent(allocator, .{ .context = &removed, .function = RemovalCounter.onMessage });
    const cancelledUnsubscribe = try pool.onTasksCancelled(allocator, "db", .{ .context = &removed, .function = RemovalCounter.onCancelled });
    _ = try pool.onTaskAdded(allocator, "db", .{ .context = &kept, .function = RemovalCounter.onAdded });
    _ = try pool.onTaskComplete(allocator, .{ .context = &kept, .function = RemovalCounter.onComplete });
    _ = try pool.onTaskEvent(allocator, "label", .{ .context = &kept, .function = RemovalCounter.onMessage });
    _ = try pool.onAnyTaskEvent(allocator, .{ .context = &kept, .function = RemovalCounter.onMessage });
    _ = try pool.onTasksCancelled(allocator, "db", .{ .context = &kept, .function = RemovalCounter.onCancelled });

    addedUnsubscribe.call(allocator);
    completeUnsubscribe.call(allocator);
    messageUnsubscribe.call(allocator);
    anyMessageUnsubscribe.call(allocator);
    cancelledUnsubscribe.call(allocator);

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "hello"), "db", "task-3", null);
    try collector.waitForCompleted(pool, allocator, timer_list.interface(), 1);
    pool.cancelTasks(std.testing.io, allocator, "db");

    // The task was added, completed and sent one message, and the source was cancelled, so the callbacks
    // that are still registered were each called once.
    try std.testing.expectEqual(@as(usize, 4), kept.calls);
    try std.testing.expectEqual(@as(usize, 1), kept.cancelled);
    try std.testing.expectEqual(@as(usize, 0), removed.calls);
    try std.testing.expectEqual(@as(usize, 0), removed.cancelled);
}

test "a queued interactive task is dispatched before a queued background one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    blocking_queues.reset();
    // One worker, so the two tasks queued behind the running one wait for it.
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var timer_list = TimerList.init();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = PoolCollector.onComplete });
    _ = try pool.onAnyTaskEvent(allocator, .{ .context = &collector, .function = PoolCollector.onLabelMessage });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "block", ""), "source", "blocking-task", null);
    try waitForBlockingTask(pool, allocator, timer_list.interface());
    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "background"), "source", "background-task", null);
    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "interactive"), "source", "interactive-task", .Interactive);
    try std.testing.expectEqual(@as(usize, 2), pool.pendingTasks.items.len);

    blocking_queues.release.close(std.testing.io);
    try collector.waitForCompleted(pool, allocator, timer_list.interface(), 3);

    try std.testing.expectEqual(@as(usize, 0), collector.failed);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.labelCount);
    try std.testing.expectEqualStrings("interactive", collector.labelText[0][0..collector.labelLengths[0]]);
    try std.testing.expectEqualStrings("background", collector.labelText[1][0..collector.labelLengths[1]]);
}

test "a pool that can never create a worker leaves the task pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A maxWorkers that compares false against the number of workers (NaN) never allows
    // one, so the task waits for a worker that never comes.
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, std.math.nan(f64), 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var timer_list = TimerList.init();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = PoolCollector.onComplete });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "hello"), "source", "task-4", null);
    try std.testing.io.sleep(.fromMilliseconds(100), .awake);
    pool.handleQueuedMessages(std.testing.io, allocator, timer_list.interface());

    try std.testing.expectEqual(@as(usize, 0), collector.completed);
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);
}

test "shutdown discards the result of a task that is still running" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    blocking_queues.reset();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    var timer_list = TimerList.init();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = PoolCollector.onComplete });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "block", ""), "source", "blocking-task", null);
    try waitForBlockingTask(pool, allocator, timer_list.interface());
    // The running task is cancelled, so its handler returns and its worker ends, and the result it sends is thrown away.
    pool.shutdown(std.testing.io, allocator);
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);

    blocking_queues.release.close(std.testing.io);
    pool.deinit(std.testing.io, allocator);

    try std.testing.expectEqual(@as(usize, 0), collector.completed);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
}

//
// Where a test's help and errors are written.
//
const IRecorder = struct {
    // Captures stdout.
    stdout: std.Io.Writer.Allocating,

    // Captures stderr.
    stderr: std.Io.Writer.Allocating,

    //
    // The output configuration that writes to the captures.
    //
    fn output(self: *IRecorder) commander.IOutputConfiguration {
        return .{
            .writeOut = &self.stdout.writer,
            .writeErr = &self.stderr.writer,
        };
    }
};

test "the help command is added to a command with no subcommands when it is asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder = IRecorder{ .stdout = .init(allocator), .stderr = .init(allocator) };
    const program = Command.init(allocator, "tool").exitOverride().addHelpCommand(true);
    _ = program.configureOutput(recorder.output());
    _ = program.option("--flag", "A flag.", null);

    // There are no subcommands, so the help command is only there because it was asked for.
    try std.testing.expectEqual(true, program.getHelpCommand() != null);

    try std.testing.expectError(error.CommanderError, program.parse(&.{"help"}));

    const details = program.getCommanderError().?;
    try std.testing.expectEqual(@as(u8, 0), details.exitCode);
    try std.testing.expectEqualStrings("commander.help", details.code);

    // The help lists the help command under Commands, which only exists because it was asked for.
    try std.testing.expectEqualStrings(
        \\Usage: tool [options]
        \\
        \\Options:
        \\  --flag          A flag.
        \\  -h, --help      display help for command
        \\
        \\Commands:
        \\  help [command]  display help for command
        \\
    , recorder.stdout.written());
    try std.testing.expectEqualStrings("", recorder.stderr.written());
}

test "the help option can be turned off, which leaves --help an unknown option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder = IRecorder{ .stdout = .init(allocator), .stderr = .init(allocator) };
    const program = Command.init(allocator, "tool").exitOverride().helpOption(false);
    _ = program.configureOutput(recorder.output());

    try std.testing.expectEqual(true, program.getHelpOption() == null);
    try std.testing.expectError(error.CommanderError, program.parse(&.{"--help"}));

    const details = program.getCommanderError().?;
    try std.testing.expectEqual(@as(u8, 1), details.exitCode);
    try std.testing.expectEqualStrings("commander.unknownOption", details.code);
    try std.testing.expectEqualStrings("error: unknown option '--help'\n", recorder.stderr.written());
    try std.testing.expectEqualStrings("", recorder.stdout.written());

    // The usage of a command with arguments but no options and no help option is the arguments alone.
    const bare = Command.init(allocator, "bare").helpOption(false);
    _ = bare.argument("<first>", "");
    _ = bare.argument("[second]", "");
    try std.testing.expectEqualStrings("<first> [second]", try bare.usage(allocator));
}

test "boxWrap splits CRLF lines and keeps a blank line for a line of only whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var helper = commander.Help{};

    // The \r of a CRLF line ending is not part of the line.
    try std.testing.expectEqualStrings("aaa bbb\nccc", try helper.boxWrap(allocator, "aaa bbb\r\nccc", 80));

    // A line of only whitespace has no chunks at all, which is one empty line.
    try std.testing.expectEqualStrings("aaa\n\nbbb", try helper.boxWrap(allocator, "aaa\n   \nbbb", 80));

    // Whitespace at the end of a line is dropped with the chunk it follows.
    try std.testing.expectEqualStrings("aaa", try helper.boxWrap(allocator, "aaa   ", 80));

    try std.testing.expectEqualStrings("", try helper.boxWrap(allocator, "", 80));
}

test "the colours of the running process are detected from the environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("NO_COLOR", "1");
    try environ_map.put("TERM", "xterm");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    const environment = picocolors.processColorEnvironment();
    try std.testing.expectEqualStrings("1", environment.NO_COLOR orelse "");
    try std.testing.expectEqualStrings("xterm", environment.TERM orelse "");
    try std.testing.expectEqual(false, environment.FORCE_COLOR != null);
    try std.testing.expectEqual(false, environment.CI != null);

    // NO_COLOR decides it, whatever stdout is, and the answer is remembered for the rest of the process.
    try std.testing.expectEqual(false, picocolors.detectColorSupport(environment));
    try std.testing.expectEqual(false, picocolors.isColorSupported());
    try std.testing.expectEqual(false, picocolors.isColorSupported());
    try std.testing.expectEqualStrings("x", try picocolors.red(allocator, "x"));
    try std.testing.expectEqualStrings("x", try picocolors.createColors(picocolors.isColorSupported()).apply(allocator, picocolors.styles.red, "x"));
}

//
// The color depth tty.getColorDepth reports for an environment given as name/value pairs.
//
fn colorDepthFor(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !u8 {
    var environment = std.process.Environ.Map.init(allocator);
    for (pairs) |pair| {
        try environment.put(pair[0], pair[1]);
    }
    return tty.getColorDepth(&environment);
}

test "getColorDepth matches Node for the terminals the table and the patterns name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (builtin.os.tag == .windows) {
        // Node answers 24-bit color on Windows before it looks at any of these.
        return error.SkipZigTest;
    }

    // The terminals the pattern matches anywhere in the name.
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(allocator, &.{.{ "TERM", "direct" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(allocator, &.{.{ "TERM", "xterm-direct" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(allocator, &.{.{ "TERM", "vt220" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(allocator, &.{.{ "TERM", "VT100" }}));

    // The terminals the table names, which may have more than 16 colors.
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(allocator, &.{.{ "TERM", "xterm-kitty" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(allocator, &.{.{ "TERM", "XTERM-KITTY" }}));

    // The CI services, in the order Node checks them: the first one that is set decides.
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(allocator, &.{.{ "CI", "1" }, .{ "GITEA_ACTIONS", "1" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(allocator, &.{.{ "CI", "1" }, .{ "CIRCLECI", "1" }}));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(allocator, &.{.{ "CI", "1" }, .{ "APPVEYOR", "1" }, .{ "GITHUB_ACTIONS", "1" }}));

    // An empty TMUX is not set as far as the truthiness of the environment goes, so it decides nothing.
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(allocator, &.{.{ "TMUX", "" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(allocator, &.{.{ "TMUX", "" }, .{ "TERM", "xterm-truecolor" }}));
}

//
// Tests of the infrastructure ports that no other test file covers: the signal handlers, the worker thread
// log and the routing log that decides which of them a message goes to, the error and shutdown paths of the
// worker pool, the parts of the argument parser the golden fixtures cannot reach, and the colour depth of a
// terminal.
//

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue = @import("task-queue-zig");

const process_signals = cli.process_signals;
const worker_log_bun = cli.worker_log_bun;
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const commander = cli.commander;
const Command = commander.Command;
const picocolors = cli.picocolors;
const tty = cli.tty;
const types = task_queue.types;

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
// The log the routing log falls back to. The routing log keeps the log that was installed when it was first
// installed for the rest of the process, so it cannot be one this file's tests free afterwards.
//
var routing_main_log = cli.log.Log.init(.{ .verbose = false });

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

test "the worker log writes no tool output when tool logging is off or the output is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: Capture = undefined;
    startCapture(arena.allocator(), &capture);
    defer utils.console.setCapture(null, null);

    var quiet = worker_log_bun.WorkerLogBun.init(1, false, false);
    quiet.tool("ffprobe", .{ .stdout = "out", .stderr = "err" });

    // An empty output is not written, as an empty string is not truthy in TypeScript.
    var loud = worker_log_bun.WorkerLogBun.init(1, false, true);
    loud.tool("ffprobe", .{ .stdout = "", .stderr = null });
    loud.tool("ffprobe", .{ .stdout = null, .stderr = "" });
    loud.tool("ffprobe", .{ .stdout = null, .stderr = null });

    try std.testing.expectEqualStrings("", capture.stdout.written());
}

test "clearing the worker log of a thread stops the task ID being set on it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: Capture = undefined;
    startCapture(arena.allocator(), &capture);
    defer utils.console.setCapture(null, null);

    var workerLog = worker_log_bun.WorkerLogBun.init(9, false, false);
    worker_log_bun.createWorkerLog(&workerLog);
    defer worker_log_bun.clearWorkerLog();

    worker_log_bun.setWorkerTaskId("first");
    worker_log_bun.clearWorkerLog();
    worker_log_bun.setWorkerTaskId("second");
    workerLog.info("after");

    try std.testing.expectEqualStrings("[W9:first] after\n", capture.stdout.written());
}

test "the routing log sends every kind of worker message to that worker's log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: Capture = undefined;
    startCapture(arena.allocator(), &capture);
    defer utils.console.setCapture(null, null);
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    utils.log.setLog(routing_main_log.ilog());
    worker_log_bun.installWorkerLogRouting();

    const Worker = struct {
        //
        // The worker thread: every kind of message goes to the worker's own log, which is verbose and has
        // tool logging on, and none of it reaches the main log.
        //
        fn run() void {
            var workerLog = worker_log_bun.WorkerLogBun.init(4, true, true);
            worker_log_bun.createWorkerLog(&workerLog);
            defer worker_log_bun.clearWorkerLog();
            worker_log_bun.setWorkerTaskId("task-9");
            const log = utils.log.log;
            log.info("info");
            log.verbose("verbose");
            log.warn("warn");
            log.@"error"("error");
            log.debug("debug");
            log.event("event");
            log.tool("tool", .{ .stdout = "out", .stderr = "err" });
            log.exception("exception", utils.errors.throwError("Cause", .{}));
            if (log.verboseEnabled()) {
                log.info("verbose on");
            }
            const details = log.getLogDetails(std.heap.smp_allocator, std.testing.io) catch return;
            if (details.logFilePath == null) {
                log.info("no log file");
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{});
    thread.join();

    try std.testing.expectEqualStrings(
        \\[W4:task-9] info
        \\[W4:task-9] verbose
        \\[W4:task-9] [EVENT] event
        \\[W4:task-9] == tool stdout ==
        \\out
        \\[W4:task-9] == tool stderr ==
        \\err
        \\[W4:task-9] verbose on
        \\[W4:task-9] no log file
        \\
    , capture.stdout.written());
    try std.testing.expectEqualStrings(
        \\[W4:task-9] warn
        \\[W4:task-9] error
        \\[W4:task-9] exception
        \\Error: Cause
        \\
    , capture.stderr.written());
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
    // Guards the fields.
    mutex: std.Io.Mutex = .init,

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
    fn onComplete(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
        const self: *PoolCollector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.completed += 1;
        if (result.status == .Failed) {
            self.failed += 1;
        }
    }

    //
    // The typed task message callback.
    //
    fn onTypedMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        _ = data;
        const self: *PoolCollector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.typedMessages += 1;
    }

    //
    // The task message callback that records the label of each message.
    //
    fn onLabelMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *PoolCollector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.anyMessages += 1;
        if (self.labelCount < self.labelText.len) {
            const label = data.message.object.get("label") orelse return;
            const length = @min(label.string.len, self.labelText[self.labelCount].len);
            @memcpy(self.labelText[self.labelCount][0..length], label.string[0..length]);
            self.labelLengths[self.labelCount] = label.string.len;
            self.labelCount += 1;
        }
    }

    //
    // Waits until the number of completed tasks reaches the count (fails after 10 seconds).
    //
    fn waitForCompleted(self: *PoolCollector, count: usize) !void {
        var waited: usize = 0;
        while (waited < 2000) {
            self.mutex.lockUncancelable(std.testing.io);
            const completed = self.completed;
            self.mutex.unlock(std.testing.io);
            if (completed >= count) {
                return;
            }
            std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
            waited += 1;
        }
        return error.TestTimedOut;
    }
};

//
// A completion callback that always fails.
//
fn failingCompletionCallback(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
    _ = context;
    _ = result;
    return error.CallbackFailed;
}

//
// A typed task message callback that always fails.
//
fn failingMessageCallback(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
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
// How many blocking tasks are running at once.
//
var blocking_running: std.atomic.Value(usize) = .init(0);

//
// Set to release the blocking tasks.
//
var blocking_release: std.atomic.Value(bool) = .init(false);

//
// Runs the task its data asks for: "echo" returns the text, "label" sends the text as a message of the type
// the tests listen for, and "block" blocks until it is released or cancelled.
//
fn testHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    const kind = data.object.get("kind") orelse return .null;
    const text = data.object.get("text") orelse return .null;
    if (std.mem.eql(u8, kind.string, "echo")) {
        return .{ .string = try std.fmt.allocPrint(allocator, "echo {s}", .{text.string}) };
    }
    if (std.mem.eql(u8, kind.string, "label")) {
        var message: std.json.ObjectMap = .empty;
        try message.put(allocator, "type", .{ .string = "label" });
        try message.put(allocator, "label", .{ .string = text.string });
        context.sendMessage(.{ .object = message });
        return .null;
    }
    if (std.mem.eql(u8, kind.string, "block")) {
        _ = blocking_running.fetchAdd(1, .acq_rel);
        defer _ = blocking_running.fetchSub(1, .acq_rel);
        while (!blocking_release.load(.acquire) and !context.isCancelled()) {
            io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
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
// Waits until a blocking task is running (fails after 10 seconds).
//
fn waitForBlockingTask() !void {
    var waited: u32 = 0;
    while (blocking_running.load(.acquire) == 0 and waited < 10000) {
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        waited += 5;
    }
    try std.testing.expectEqual(true, waited < 10000);
}

//
// Registers the task handler of the tests that use the pool.
//
fn registerPoolHandlers() !void {
    try task_queue.worker.registerHandler(task_type, testHandler);
}

test "a completion callback that fails is logged and the task still finishes" {
    try registerPoolHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var capture: Capture = undefined;
    startCapture(allocator, &capture);
    defer utils.console.setCapture(null, null);
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = PoolCollector{};
    // The failing callback is registered first, so its message is logged before the collector reports the
    // task as completed and the test can read it.
    _ = try pool.onTaskComplete(.{ .context = null, .function = failingCompletionCallback });
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = PoolCollector.onComplete });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "echo", "hi"), "source", "task-1", null);
    try collector.waitForCompleted(1);

    try std.testing.expectEqual(@as(usize, 1), collector.completed);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);

    // The callback runs on the worker thread, after the handler has cleared the task ID from the log prefix.
    try std.testing.expectEqualStrings(
        \\[W1] Error in task completion callback
        \\Error: CallbackFailed
        \\
    , capture.stderr.written());
}

test "a task message callback that fails is logged and the other callbacks still run" {
    try registerPoolHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var capture: Capture = undefined;
    startCapture(allocator, &capture);
    defer utils.console.setCapture(null, null);
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = PoolCollector.onComplete });
    _ = try pool.onTaskMessage("label", .{ .context = null, .function = failingMessageCallback });
    _ = try pool.onTaskMessage("label", .{ .context = &collector, .function = PoolCollector.onTypedMessage });
    _ = try pool.onAnyTaskMessage(.{ .context = null, .function = failingMessageCallback });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "hello"), "source", "task-2", null);
    try collector.waitForCompleted(1);

    try std.testing.expectEqual(@as(usize, 1), collector.typedMessages);

    // The failing callbacks are logged while the task runs, so they carry the task ID.
    try std.testing.expectEqualStrings(
        \\[W1:task-2] Error in task message callback
        \\Error: CallbackFailed
        \\[W1:task-2] Error in any task message callback
        \\Error: CallbackFailed
        \\
    , capture.stderr.written());
}

//
// Counts the calls of each kind of callback, so that a test can tell which ones still fire.
//
const RemovalCounter = struct {
    // Guards the fields.
    mutex: std.Io.Mutex = .init,

    // The number of calls of onTaskAdded, onTaskComplete and the message callbacks together.
    calls: usize = 0,

    // The number of onTasksCancelled calls.
    cancelled: usize = 0,

    //
    // Counts one call.
    //
    fn count(context: ?*anyopaque) void {
        const self: *RemovalCounter = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.calls += 1;
    }

    //
    // The onTaskAdded callback.
    //
    fn onAdded(context: ?*anyopaque, taskId: []const u8) void {
        _ = taskId;
        count(context);
    }

    //
    // The completion callback.
    //
    fn onComplete(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
        _ = result;
        count(context);
    }

    //
    // The task message callback.
    //
    fn onMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        _ = data;
        count(context);
    }

    //
    // The onTasksCancelled callback.
    //
    fn onCancelled(context: ?*anyopaque) void {
        const self: *RemovalCounter = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.cancelled += 1;
    }
};

test "unsubscribing stops a callback of every kind from being called" {
    try registerPoolHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = PoolCollector.onComplete });

    // One callback of each kind, and one more of each kind that is unsubscribed straight away.
    var removed = RemovalCounter{};
    var kept = RemovalCounter{};
    const addedUnsubscribe = try pool.onTaskAdded("db", .{ .context = &removed, .function = RemovalCounter.onAdded });
    const completeUnsubscribe = try pool.onTaskComplete(.{ .context = &removed, .function = RemovalCounter.onComplete });
    const messageUnsubscribe = try pool.onTaskMessage("label", .{ .context = &removed, .function = RemovalCounter.onMessage });
    const anyMessageUnsubscribe = try pool.onAnyTaskMessage(.{ .context = &removed, .function = RemovalCounter.onMessage });
    const cancelledUnsubscribe = try pool.onTasksCancelled("db", .{ .context = &removed, .function = RemovalCounter.onCancelled });
    _ = try pool.onTaskAdded("db", .{ .context = &kept, .function = RemovalCounter.onAdded });
    _ = try pool.onTaskComplete(.{ .context = &kept, .function = RemovalCounter.onComplete });
    _ = try pool.onTaskMessage("label", .{ .context = &kept, .function = RemovalCounter.onMessage });
    _ = try pool.onAnyTaskMessage(.{ .context = &kept, .function = RemovalCounter.onMessage });
    _ = try pool.onTasksCancelled("db", .{ .context = &kept, .function = RemovalCounter.onCancelled });

    addedUnsubscribe.call();
    completeUnsubscribe.call();
    messageUnsubscribe.call();
    anyMessageUnsubscribe.call();
    cancelledUnsubscribe.call();

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "hello"), "db", "task-3", null);
    try collector.waitForCompleted(1);
    pool.cancelTasks("db");

    // The task was added, completed and sent one message, and the source was cancelled, so the callbacks
    // that are still registered were each called once.
    try std.testing.expectEqual(@as(usize, 4), kept.calls);
    try std.testing.expectEqual(@as(usize, 1), kept.cancelled);
    try std.testing.expectEqual(@as(usize, 0), removed.calls);
    try std.testing.expectEqual(@as(usize, 0), removed.cancelled);
}

test "a queued interactive task is dispatched before a queued background one" {
    try registerPoolHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    blocking_running.store(0, .release);
    blocking_release.store(false, .release);
    // One worker, so the two tasks queued behind the running one wait for it.
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = PoolCollector.onComplete });
    _ = try pool.onAnyTaskMessage(.{ .context = &collector, .function = PoolCollector.onLabelMessage });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "block", ""), "source", "blocking-task", null);
    try waitForBlockingTask();
    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "background"), "source", "background-task", null);
    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "interactive"), "source", "interactive-task", .Interactive);
    try std.testing.expectEqual(@as(usize, 2), pool.pendingTasks.items.len);

    blocking_release.store(true, .release);
    try collector.waitForCompleted(3);

    try std.testing.expectEqual(@as(usize, 0), collector.failed);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.labelCount);
    try std.testing.expectEqualStrings("interactive", collector.labelText[0][0..collector.labelLengths[0]]);
    try std.testing.expectEqualStrings("background", collector.labelText[1][0..collector.labelLengths[1]]);
}

test "a pool that can never create a worker leaves the task pending" {
    try registerPoolHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    // As in TypeScript, a maxWorkers that compares false against the number of workers (NaN) never allows
    // one, so the task waits for a worker that never comes.
    const pool = try WorkerPoolBun.init(std.testing.io, std.math.nan(f64), 10000, .{});
    defer pool.deinit();
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = PoolCollector.onComplete });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "label", "hello"), "source", "task-4", null);
    try std.testing.io.sleep(.fromMilliseconds(100), .awake);

    try std.testing.expectEqual(@as(usize, 0), collector.completed);
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);
}

test "shutdown discards the result of a task that is still running" {
    try registerPoolHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);

    blocking_running.store(0, .release);
    blocking_release.store(false, .release);
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    var collector = PoolCollector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = PoolCollector.onComplete });

    _ = try pool.addTask(allocator, std.testing.io, task_type, try taskData(allocator, "block", ""), "source", "blocking-task", null);
    try waitForBlockingTask();
    pool.shutdown();
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);

    // The worker thread only ends once its handler returns, and then throws the result away.
    blocking_release.store(true, .release);
    pool.deinit();

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

    // The \r of a CRLF line ending is not part of the line, as the split of the JavaScript is not.
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

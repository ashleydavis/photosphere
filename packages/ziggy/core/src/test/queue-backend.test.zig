//
// Tests of the queue backend: handlers registered with task-queue-zig run on Ziggy's runner, code written against IQueueBackend and
// TaskQueue works on it, and the callbacks TaskQueue is built on fire as they do on the Electron pool.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const task_queue = @import("task-queue-zig");
const helpers = @import("helpers.zig");

const types = task_queue.types;
const worker = task_queue.worker;
const getQueueBackend = task_queue.queue_backend.getQueueBackend;
const TaskQueue = task_queue.task_queue.TaskQueue;

//
// Registers a handler with task-queue-zig, once per process: the registry replaces a handler registered under the same name.
//
fn register(task_type: []const u8, handler: types.TaskHandler) !void {
    try worker.registerHandler(task_type, handler);
}

fn echoHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    var message: std.json.ObjectMap = .empty;
    try message.put(allocator, "type", .{ .string = "registered-hello" });
    context.sendMessage(.{ .object = message });
    var outputs: std.json.ObjectMap = .empty;
    try outputs.put(allocator, "taskId", .{ .string = context.taskId });
    try outputs.put(allocator, "echo", data);
    return .{ .object = outputs };
}

fn waitForCancelHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    while (!context.isCancelled()) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Cancelled;
}

fn childHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = context;
    return data;
}

//
// Adds up the outputs of the children a parent queued, as its completion callback is given them.
//
fn addUpChild(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
    const sum: *i64 = @ptrCast(@alignCast(context.?));
    sum.* += result.outputs.?.integer;
}

fn parentHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = data;
    const queue = try TaskQueue.init(allocator, io, context.uuidGenerator, "registered-parent");
    defer queue.deinit();
    var sum: i64 = 0;
    _ = try queue.onTaskComplete(.{
        .context = &sum,
        .function = addUpChild,
    });
    var index: i64 = 1;
    while (index <= 3) : (index += 1) {
        _ = try queue.addTask("registered-child", .{ .integer = index }, null, null);
    }
    try queue.awaitAllTasks();
    return .{ .integer = sum };
}

//
// A task of the runner (not registered with task-queue-zig) that queues a task through the backend, as a handler written against
// task-queue does, and says which task it queued.
//
fn queueThroughBackendTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const backend = try getQueueBackend();
    const child_id = try backend.addTask(context.arena, context.io(), "priority-report", .null, "backend-source", null, null);
    return try ziggy.json_util.stringify(context.arena, child_id);
}

//
// A task of the runner that says what priority the runner reports for the task running on its thread.
//
fn priorityReportTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const priority = context.runner.priorityOfRunningTask() orelse return error.NoRunningTask;
    return try ziggy.json_util.stringify(context.arena, @tagName(priority));
}

const backend_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "queue-through-backend", .handler = queueThroughBackendTask },
    .{ .name = "priority-report", .handler = priorityReportTask },
};

fn createCore(shell: *helpers.FakeShell, worker_threads: u32) !*ziggy.core.Core {
    var app = helpers.app;
    app.tasks = &(helpers.task_handlers ++ backend_tasks);
    return try ziggy.core.Core.create(std.testing.allocator, shell.config(worker_threads, 4), app);
}

fn addTask(core: *ziggy.core.Core, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8, priority: []const u8) !void {
    const message = try ziggy.json_util.stringify(std.testing.allocator, .{
        .channel = "add-task",
        .data = .{
            .taskId = id,
            .taskType = task_type,
            .source = source,
            .data = ziggy.json_util.Raw{ .text = data },
            .priority = priority,
        },
    });
    defer std.testing.allocator.free(message);
    core.postMessage(message);
}

test "a handler registered with task-queue-zig runs on the runner, sends messages and returns its outputs" {
    try register("registered-echo", echoHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 2);
    defer core.destroy();
    try addTask(core, "r1", "registered-echo", "s", "{\"a\":1}", "background");
    try shell.expectMessageContaining("{\"channel\":\"task-message\",\"data\":{\"taskId\":\"r1\",\"source\":\"s\",\"message\":{\"type\":\"registered-hello\"}}}");
    try shell.expectMessageContaining("\"outputs\":{\"taskId\":\"r1\",\"echo\":{\"a\":1}},\"type\":\"registered-echo\",\"inputs\":{\"a\":1}");
}

test "a registered handler sees its task cancelled when the source is cancelled" {
    try register("registered-wait", waitForCancelHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 2);
    defer core.destroy();
    try addTask(core, "w1", "registered-wait", "wait-source", "null", "background");
    shell.sleepMs(20);
    core.postMessage("{\"channel\":\"cancel-tasks\",\"data\":\"wait-source\"}");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"},\"errorMessage\":\"Cancelled\"");
}

test "a registered handler queues child tasks with TaskQueue and awaits them" {
    try register("registered-parent", parentHandler);
    try register("registered-child", childHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 4);
    defer core.destroy();
    try addTask(core, "p1", "registered-parent", "s", "null", "background");
    try shell.expectMessageContaining("{\"channel\":\"task-completed\",\"data\":{\"taskId\":\"p1\",\"result\":{\"taskId\":\"p1\",\"status\":\"succeeded\",\"outputs\":6,");
}

test "a task queued through the backend by a running task runs at that task's priority" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 2);
    defer core.destroy();
    try addTask(core, "q1", "queue-through-backend", "s", "null", "interactive");
    try shell.expectMessageContaining("\"taskId\":\"q1\",\"status\":\"succeeded\"");
    try shell.expectMessageContaining("\"status\":\"succeeded\",\"outputs\":\"interactive\",\"type\":\"priority-report\"");
    try addTask(core, "q2", "queue-through-backend", "s", "null", "background");
    try shell.expectMessageContaining("\"status\":\"succeeded\",\"outputs\":\"background\",\"type\":\"priority-report\"");
}

test "the runner reports no priority on a thread that is not running one of its tasks" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 1);
    defer core.destroy();
    try std.testing.expect(core.runner.priorityOfRunningTask() == null);
}

//
// Records what the callbacks are given, for the tests to look at.
//
const Recorder = struct {
    // Guards the lines.
    mutex: std.Io.Mutex = .init,
    // One line per call, as "kind|taskId|detail".
    lines: std.ArrayList([]u8) = .empty,

    fn record(self: *Recorder, line: []u8) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.lines.append(std.testing.allocator, line) catch @panic("out of memory");
    }

    fn deinit(self: *Recorder) void {
        for (self.lines.items) |line| {
            std.testing.allocator.free(line);
        }
        self.lines.deinit(std.testing.allocator);
    }

    fn count(self: *Recorder, prefix: []const u8) usize {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        var found: usize = 0;
        for (self.lines.items) |line| {
            if (std.mem.startsWith(u8, line, prefix)) {
                found += 1;
            }
        }
        return found;
    }

    fn waitFor(self: *Recorder, prefix: []const u8) !void {
        var waited: usize = 0;
        while (self.count(prefix) == 0) : (waited += 1) {
            if (waited > 5000) {
                return error.TimedOutWaitingForCallback;
            }
            try std.testing.io.sleep(.fromMilliseconds(2), .awake);
        }
    }

    fn onComplete(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        const outputs = if (result.outputs) |value| try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{}) else try std.testing.allocator.dupe(u8, "none");
        defer std.testing.allocator.free(outputs);
        const inputs = try std.json.Stringify.valueAlloc(std.testing.allocator, result.inputs, .{});
        defer std.testing.allocator.free(inputs);
        self.record(try std.fmt.allocPrint(std.testing.allocator, "complete|{s}|{s}|{s}|{s}|{s}|{s}", .{ result.taskId, result.type, result.status.toString(), result.errorMessage orelse "no error", outputs, inputs }));
    }

    fn onMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        const message = try std.json.Stringify.valueAlloc(std.testing.allocator, data.message, .{});
        defer std.testing.allocator.free(message);
        self.record(try std.fmt.allocPrint(std.testing.allocator, "message|{s}|{s}", .{ data.taskId, message }));
    }

    fn onTypedMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(try std.fmt.allocPrint(std.testing.allocator, "typed|{s}", .{data.taskId}));
    }

    fn onAdded(context: ?*anyopaque, task_id: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(std.fmt.allocPrint(std.testing.allocator, "added|{s}", .{task_id}) catch @panic("out of memory"));
    }

    fn onCancelled(context: ?*anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.record(std.fmt.allocPrint(std.testing.allocator, "cancelled|", .{}) catch @panic("out of memory"));
    }
};

test "the completion callback gets the task's type, input, status and outputs, and stops after it is unsubscribed" {
    try register("registered-echo", echoHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 2);
    defer core.destroy();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = try getQueueBackend();
    const unsubscribe = try backend.onTaskComplete(.{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    try addTask(core, "c1", "registered-echo", "s", "{\"a\":1}", "background");
    try recorder.waitFor("complete|c1|registered-echo|succeeded|no error|{\"taskId\":\"c1\",\"echo\":{\"a\":1}}|{\"a\":1}");
    unsubscribe.call();
    try addTask(core, "c2", "registered-echo", "s", "{\"a\":2}", "background");
    try shell.expectMessageContaining("\"taskId\":\"c2\",\"status\":\"succeeded\"");
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|c2"));
}

test "a task that fails or is cancelled while running is reported as failed, and one cancelled while queued is not reported" {
    try register("registered-wait", waitForCancelHandler);
    try register("registered-echo", echoHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 1);
    defer core.destroy();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = try getQueueBackend();
    const unsubscribe = try backend.onTaskComplete(.{
        .context = &recorder,
        .function = Recorder.onComplete,
    });
    defer unsubscribe.call();
    try addTask(core, "running", "registered-wait", "gone", "null", "background");
    shell.sleepMs(20);
    try addTask(core, "queued", "registered-echo", "gone", "null", "background");
    backend.cancelTasks("gone");
    try recorder.waitFor("complete|running|registered-wait|failed|Cancelled|none|null");
    try shell.expectMessageContaining("\"taskId\":\"queued\",\"result\":{\"taskId\":\"queued\",\"status\":\"failed\"");
    try std.testing.expectEqual(@as(usize, 0), recorder.count("complete|queued"));
}

test "message callbacks get the messages of a type, and every message" {
    try register("registered-echo", echoHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 2);
    defer core.destroy();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = try getQueueBackend();
    const any = try backend.onAnyTaskMessage(.{
        .context = &recorder,
        .function = Recorder.onMessage,
    });
    defer any.call();
    const typed = try backend.onTaskMessage("registered-hello", .{
        .context = &recorder,
        .function = Recorder.onTypedMessage,
    });
    defer typed.call();
    const other = try backend.onTaskMessage("something-else", .{
        .context = &recorder,
        .function = Recorder.onTypedMessage,
    });
    defer other.call();
    try addTask(core, "m1", "registered-echo", "s", "null", "background");
    try recorder.waitFor("message|m1|{\"type\":\"registered-hello\"}");
    try recorder.waitFor("typed|m1");
    shell.sleepMs(20);
    try std.testing.expectEqual(@as(usize, 1), recorder.count("typed|"));
}

test "callbacks for a source fire when a task is added under it and when the source is cancelled" {
    try register("registered-echo", echoHandler);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, 2);
    defer core.destroy();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const backend = try getQueueBackend();
    const added = try backend.onTaskAdded("watched", .{
        .context = &recorder,
        .function = Recorder.onAdded,
    });
    defer added.call();
    const cancelled = try backend.onTasksCancelled("watched", .{
        .context = &recorder,
        .function = Recorder.onCancelled,
    });
    defer cancelled.call();
    const unwatched_id = try backend.addTask(std.testing.allocator, std.testing.io, "registered-echo", .null, "unwatched", "u1", null);
    defer std.testing.allocator.free(unwatched_id);
    const id = try backend.addTask(std.testing.allocator, std.testing.io, "registered-echo", .null, "watched", "w1", null);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqual(@as(usize, 1), recorder.count("added|w1"));
    try std.testing.expectEqual(@as(usize, 0), recorder.count("added|u1"));
    backend.cancelTasks("unwatched");
    try std.testing.expectEqual(@as(usize, 0), recorder.count("cancelled|"));
    backend.cancelTasks("watched");
    try std.testing.expectEqual(@as(usize, 1), recorder.count("cancelled|"));
}

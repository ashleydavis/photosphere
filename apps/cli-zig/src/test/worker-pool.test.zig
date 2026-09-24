const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const task_queue = @import("task-queue-zig");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const types = task_queue.types;

//
// The results collected by the completion callback of a test.
//
const Collector = struct {
    // Guards the fields.
    mutex: std.Io.Mutex = .init,

    // Number of completed tasks.
    completed: usize = 0,

    // Number of failed tasks.
    failed: usize = 0,

    // The error message of the last failed task.
    lastErrorMessage: [256]u8 = undefined,

    // The length of lastErrorMessage.
    lastErrorMessageLength: usize = 0,

    // The error name of the last failed task.
    lastErrorName: [64]u8 = undefined,

    // The length of lastErrorName.
    lastErrorNameLength: usize = 0,

    // The string output of the last successful task.
    lastOutput: [256]u8 = undefined,

    // The length of lastOutput.
    lastOutputLength: usize = 0,

    // Number of messages received by the typed message callback.
    typedMessages: usize = 0,

    // Number of messages received by the any-message callback.
    anyMessages: usize = 0,

    // Number of tasks added (onTaskAdded).
    added: usize = 0,

    // Number of cancellations (onTasksCancelled).
    cancellations: usize = 0,

    //
    // The completion callback.
    //
    fn onComplete(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.completed += 1;
        if (result.status == .Failed) {
            self.failed += 1;
            const message = result.errorMessage orelse "";
            @memcpy(self.lastErrorMessage[0..message.len], message);
            self.lastErrorMessageLength = message.len;
            const name = result.@"error".?.name;
            @memcpy(self.lastErrorName[0..name.len], name);
            self.lastErrorNameLength = name.len;
        }
        else {
            if (result.outputs) |outputs| {
                if (outputs == .string) {
                    @memcpy(self.lastOutput[0..outputs.string.len], outputs.string);
                    self.lastOutputLength = outputs.string.len;
                }
            }
        }
    }

    //
    // The typed message callback.
    //
    fn onTypedMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.typedMessages += 1;
        _ = data;
    }

    //
    // The any-message callback.
    //
    fn onAnyMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.anyMessages += 1;
        _ = data;
    }

    //
    // The onTaskAdded callback.
    //
    fn onAdded(context: ?*anyopaque, taskId: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        _ = taskId;
        self.added += 1;
    }

    //
    // The onTasksCancelled callback.
    //
    fn onCancelled(context: ?*anyopaque) void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.cancellations += 1;
    }

    //
    // Waits until the number of completed tasks reaches the count (fails after 10 seconds).
    //
    fn waitForCompleted(self: *Collector, count: usize) !void {
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
// Returns the text of the task data.
//
fn echoHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = context;
    return .{ .string = try std.fmt.allocPrint(allocator, "echo {s}", .{data.string}) };
}

//
// Always fails.
//
fn failingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return utils.errors.throwError("boom {d}", .{42});
}

//
// Sends two messages, one of type "progress".
//
fn messagingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = data;
    var progress: std.json.ObjectMap = .empty;
    try progress.put(allocator, "type", .{ .string = "progress" });
    context.sendMessage(.{ .object = progress });
    var other: std.json.ObjectMap = .empty;
    try other.put(allocator, "type", .{ .string = "other" });
    context.sendMessage(.{ .object = other });
    return .null;
}

//
// Number of blocking tasks running at the same time, and the maximum seen.
//
var running_now: std.atomic.Value(usize) = .init(0);

//
// The maximum number of blocking tasks that ran at the same time.
//
var running_max: std.atomic.Value(usize) = .init(0);

//
// Set to release the blocking tasks.
//
var release_blocked: std.atomic.Value(bool) = .init(false);

//
// Blocks until released (or cancelled), tracking concurrency.
//
fn blockingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    const now = running_now.fetchAdd(1, .acq_rel) + 1;
    _ = running_max.fetchMax(now, .acq_rel);
    defer _ = running_now.fetchSub(1, .acq_rel);
    while (!release_blocked.load(.acquire) and !context.isCancelled()) {
        io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    return .null;
}

//
// Sleeps longer than the timeout of the timeout test.
//
fn slowHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    _ = context;
    io.sleep(.fromMilliseconds(300), .awake) catch {};
    return .null;
}

//
// Registers the handlers of the tests.
//
fn registerHandlers() !void {
    try task_queue.worker.registerHandler("echo", echoHandler);
    try task_queue.worker.registerHandler("fail", failingHandler);
    try task_queue.worker.registerHandler("message", messagingHandler);
    try task_queue.worker.registerHandler("block", blockingHandler);
    try task_queue.worker.registerHandler("slow", slowHandler);
}

test "runs a task on a worker and reports its outputs" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, 2, 10000, .{ .sessionId = "session" });
    defer pool.deinit();
    const backend = pool.queueBackend();
    var collector = Collector{};
    _ = try backend.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    const taskId = try backend.addTask(arena.allocator(), std.testing.io, "echo", .{ .string = "hi" }, "source", "task-1");
    try std.testing.expectEqualStrings("task-1", taskId);
    try collector.waitForCompleted(1);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
    try std.testing.expectEqualStrings("echo hi", collector.lastOutput[0..collector.lastOutputLength]);
}

test "generates a task ID when none is given" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    const taskId = try pool.addTask(arena.allocator(), std.testing.io, "echo", .{ .string = "x" }, "source", null);
    try std.testing.expectEqual(@as(usize, 36), taskId.len);
    try collector.waitForCompleted(1);
}

test "reports a failed task with the error name and message" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "fail", .null, "source", null);
    _ = try pool.addTask(arena.allocator(), std.testing.io, "no-such-type", .null, "source", null);
    try collector.waitForCompleted(2);
    try std.testing.expectEqual(@as(usize, 2), collector.failed);
    try std.testing.expectEqualStrings("Error", collector.lastErrorName[0..collector.lastErrorNameLength]);
    try std.testing.expect(std.mem.startsWith(u8, collector.lastErrorMessage[0..collector.lastErrorMessageLength], "No handler registered for task type: no-such-type."));
}

test "forwards task messages to the message callbacks" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.onTaskMessage("progress", .{ .context = &collector, .function = Collector.onTypedMessage });
    const unsubscribe = try pool.onAnyTaskMessage(.{ .context = &collector, .function = Collector.onAnyMessage });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "message", .null, "source", null);
    try collector.waitForCompleted(1);
    try std.testing.expectEqual(@as(usize, 1), collector.typedMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);

    unsubscribe.call();
    _ = try pool.addTask(arena.allocator(), std.testing.io, "message", .null, "source", null);
    try collector.waitForCompleted(2);
    try std.testing.expectEqual(@as(usize, 2), collector.typedMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);
}

test "creates workers lazily up to maxWorkers" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    running_now.store(0, .release);
    running_max.store(0, .release);
    release_blocked.store(false, .release);
    const pool = try WorkerPoolBun.init(std.testing.io, 2, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    var index: usize = 0;
    while (index < 4) {
        _ = try pool.addTask(arena.allocator(), std.testing.io, "block", .null, "source", null);
        index += 1;
    }
    var waited: usize = 0;
    while (running_now.load(.acquire) < 2 and waited < 2000) {
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        waited += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), pool.workers.items.len);
    release_blocked.store(true, .release);
    try collector.waitForCompleted(4);
    try std.testing.expectEqual(@as(usize, 2), running_max.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
}

test "times out a task, reports it failed and replaces the worker" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    const pool = try WorkerPoolBun.init(std.testing.io, 1, 50, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(allocator, std.testing.io, "slow", .null, "source", "slow-task");
    _ = try pool.addTask(allocator, std.testing.io, "echo", .{ .string = "after" }, "source", "echo-task");
    try collector.waitForCompleted(2);
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("echo after", collector.lastOutput[0..collector.lastOutputLength]);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "[Task Queue] Task slow-task timed out after 50ms\n") != null);
    try std.testing.expectEqual(@as(usize, 1), pool.workers.items.len);
    try std.testing.expectEqual(@as(u32, 1), pool.workers.items[0].workerId);
}

test "cancelTasks drops pending tasks and signals running tasks" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    running_now.store(0, .release);
    release_blocked.store(false, .release);
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.onTaskAdded("db", .{ .context = &collector, .function = Collector.onAdded });
    _ = try pool.onTasksCancelled("db", .{ .context = &collector, .function = Collector.onCancelled });
    _ = try pool.addTask(allocator, std.testing.io, "block", .null, "db", null);
    _ = try pool.addTask(allocator, std.testing.io, "block", .null, "db", null);
    _ = try pool.addTask(allocator, std.testing.io, "echo", .{ .string = "other" }, "other-source", null);
    try std.testing.expectEqual(@as(usize, 2), collector.added);
    var waited: usize = 0;
    while (running_now.load(.acquire) < 1 and waited < 2000) {
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        waited += 1;
    }
    pool.cancelTasks("db");
    try std.testing.expectEqual(@as(usize, 1), collector.cancellations);
    try collector.waitForCompleted(2);
    std.testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 2), collector.completed);
    try std.testing.expectEqualStrings("echo other", collector.lastOutput[0..collector.lastOutputLength]);
}

test "shutdown terminates the workers" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, 2, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "echo", .{ .string = "x" }, "source", null);
    try collector.waitForCompleted(1);
    pool.queueBackend().shutdown();
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);
}

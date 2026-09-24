const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const types = task_queue_zig.types;
const TaskStatus = types.TaskStatus;
const ITaskResult = types.ITaskResult;
const ITaskContext = types.ITaskContext;
const registerHandler = task_queue_zig.worker.registerHandler;
const setQueueBackend = task_queue_zig.queue_backend.setQueueBackend;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const MockWorkerPool = task_queue_zig.mock_worker_pool.MockWorkerPool;
const errors = utils.errors;

//
// The state shared by the tests (the variables and beforeEach/afterEach of the TypeScript describe block).
//
const Fixture = struct {
    // Allocator for the queue (task IDs and awaitTask results).
    arena: std.heap.ArenaAllocator,

    // Generates the task IDs.
    uuidGenerator: utils.random_uuid_generator.RandomUuidGenerator,

    // Provides timestamps to the tasks.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The in-process backend.
    mockBackend: *MockWorkerPool,

    // The queue under test (source "test").
    queue: *TaskQueue,

    //
    // beforeEach: creates a MockWorkerPool(maxConcurrent), registers it and creates the queue.
    //
    fn init(self: *Fixture, maxConcurrent: usize) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.uuidGenerator = .{};
        self.timestampProvider = .{};
        self.mockBackend = try MockWorkerPool.init(std.testing.io, maxConcurrent, .{
            .uuidGenerator = self.uuidGenerator.uuidGenerator(),
            .timestampProvider = self.timestampProvider.timestampProvider(),
            .sessionId = "test-session",
        });
        setQueueBackend(self.mockBackend.queueBackend());
        self.queue = try TaskQueue.init(self.arena.allocator(), std.testing.io, self.uuidGenerator.uuidGenerator(), "test");
    }

    //
    // afterEach: shuts the queue down, waits for the backend's tasks and frees everything.
    //
    fn deinit(self: *Fixture) void {
        self.queue.deinit();
        setQueueBackend(null);
        self.mockBackend.deinit();
        self.arena.deinit();
    }

    //
    // The allocator of the test.
    //
    fn allocator(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
};

//
// Parses JSON text into a task data value.
//
fn json(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Waits for a number of milliseconds.
//
fn sleepMs(milliseconds: i64) void {
    std.testing.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
}

//
// The current time in milliseconds (Date.now()).
//
fn nowMs() i64 {
    return std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
}

//
// A handler that returns "done".
//
fn doneHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return .{ .string = "done" };
}

//
// Released by the tests to let blocked handlers finish (the `taskBlocked` promise of the TypeScript tests).
//
var task_unblocked: std.Io.Event = .unset;

//
// A handler that waits until task_unblocked is set.
//
fn slowBlockedHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    _ = context;
    task_unblocked.waitUncancelable(io);
    return .{ .string = "done" };
}

//
// Number of tasks completed by the counting handlers.
//
var completed_count = std.atomic.Value(u32).init(0);

//
// A handler that counts its calls and returns "Task <id> completed".
//
fn countingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = context;
    _ = completed_count.fetchAdd(1, .acq_rel);
    return .{ .string = try std.fmt.allocPrint(allocator, "Task {d} completed", .{data.object.get("id").?.integer}) };
}

//
// A handler that sleeps 100ms, then counts its call.
//
fn slowCountingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    _ = context;
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    _ = completed_count.fetchAdd(1, .acq_rel);
    return .{ .string = "done" };
}

//
// A handler that fails.
//
fn failHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return errors.throwError("Failed", .{});
}

//
// Guards the recording globals below (handlers run on worker threads).
//
var record_mutex: std.Io.Mutex = .init;

//
// The ids passed to the recording handlers, in execution order.
//
var execution_order: [32]i64 = undefined;

//
// Number of valid entries in execution_order.
//
var execution_order_length: usize = 0;

//
// Number of recording handlers currently running.
//
var concurrent_tasks: u32 = 0;

//
// The highest value concurrent_tasks reached.
//
var max_concurrent: u32 = 0;

//
// Resets the recording globals.
//
fn resetRecording() void {
    execution_order_length = 0;
    concurrent_tasks = 0;
    max_concurrent = 0;
    completed_count.store(0, .release);
}

//
// A handler that records its id, tracks concurrency and optionally sleeps 100ms.
//
fn recordingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = context;
    const task_number = data.object.get("id").?.integer;
    const sleeps = data.object.get("sleep") != null;
    record_mutex.lockUncancelable(io);
    execution_order[execution_order_length] = task_number;
    execution_order_length += 1;
    concurrent_tasks += 1;
    max_concurrent = @max(max_concurrent, concurrent_tasks);
    record_mutex.unlock(io);

    if (sleeps) {
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }

    record_mutex.lockUncancelable(io);
    concurrent_tasks -= 1;
    record_mutex.unlock(io);
    return .{ .string = "done" };
}

//
// Allocator for the data received by the data-recording handler (it outlives the task).
//
var received_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

//
// The data received by the data-recording handler.
//
var received_data: ?std.json.Value = null;

//
// A handler that keeps a copy of its data.
//
fn dataRecordingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = context;
    record_mutex.lockUncancelable(io);
    defer record_mutex.unlock(io);
    received_data = try task_queue_zig.json_value.cloneJsonValue(received_arena.allocator(), data);
    return .{ .string = "done" };
}

//
// Serializes the received data for comparison.
//
fn receivedJson(allocator: std.mem.Allocator) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, received_data.?, .{});
}

//
// A handler that sends a "test-message" and returns "done".
//
fn messageSendingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = data;
    context.sendMessage(try json(allocator, "{\"type\":\"test-message\",\"data\":\"test\"}"));
    return .{ .string = "done" };
}

//
// Sets a boolean flag (used as a callback that must not be called).
//
fn setFlagOnComplete(context: ?*anyopaque, result: ITaskResult) anyerror!void {
    _ = result;
    const flag: *bool = @ptrCast(@alignCast(context.?));
    flag.* = true;
}

//
// Sets a boolean flag (used as a message callback that must not be called).
//
fn setFlagOnMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
    _ = data;
    const flag: *bool = @ptrCast(@alignCast(context.?));
    flag.* = true;
}

//
// Records the completion results passed to a callback (copies what it keeps).
//
const ResultsRecorder = struct {
    // Allocator for the copies.
    allocator: std.mem.Allocator,

    // The status of each result.
    statuses: std.ArrayList(TaskStatus),

    // The error message of each result ("" when none).
    errorMessages: std.ArrayList([]const u8),

    // Whether each result had an error object.
    hasError: std.ArrayList(bool),

    //
    // The completion callback.
    //
    fn record(context: ?*anyopaque, result: ITaskResult) anyerror!void {
        const self: *ResultsRecorder = @ptrCast(@alignCast(context.?));
        try self.statuses.append(self.allocator, result.status);
        try self.errorMessages.append(self.allocator, try self.allocator.dupe(u8, if (result.@"error") |task_error| task_error.message else ""));
        try self.hasError.append(self.allocator, result.@"error" != null);
    }
};

//
// Waits until the queue has the given numbers of awaitAllTasks and awaitTask callers blocked.
//
fn waitForWaiters(queue: *TaskQueue, awaitAllCount: usize, awaitTaskCount: usize) void {
    while (true) {
        queue.mutex.lockUncancelable(queue.io);
        const ready = queue.awaitAllResolvers.items.len >= awaitAllCount and queue.awaitTaskResolvers.items.len >= awaitTaskCount;
        queue.mutex.unlock(queue.io);
        if (ready) {
            return;
        }
        sleepMs(1);
    }
}

//
// Shuts the queue down once the callers are blocked, then unblocks the task (runs on a helper thread).
//
fn shutdownWhenWaiting(queue: *TaskQueue, awaitAllCount: usize, awaitTaskCount: usize) void {
    waitForWaiters(queue, awaitAllCount, awaitTaskCount);
    queue.shutdown();
    task_unblocked.set(std.testing.io);
}

//
// Cancels the backend's "test" tasks once the callers are blocked, then unblocks the task (runs on a helper thread).
//
fn cancelWhenWaiting(queue: *TaskQueue, mockBackend: *MockWorkerPool, awaitAllCount: usize, awaitTaskCount: usize) void {
    waitForWaiters(queue, awaitAllCount, awaitTaskCount);
    mockBackend.cancelTasks("test");
    task_unblocked.set(std.testing.io);
}

test "addTask: should add a task and return a UUID" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    const taskId = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{\"data\":\"test\"}"), null);
    try std.testing.expectEqual(@as(usize, 36), taskId.len);
    try fixture.queue.awaitAllTasks();
}

test "addTask: should add multiple tasks with unique IDs" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    const id1 = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{\"data\":\"test1\"}"), null);
    const id2 = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{\"data\":\"test2\"}"), null);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    try fixture.queue.awaitAllTasks();
}

test "awaitTask: awaitTask resolves when the specific task completes" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    const taskId = try fixture.queue.addTask("test-task", .null, null);
    const result = (try fixture.queue.awaitTask(taskId)).?;
    try std.testing.expectEqualStrings(taskId, result.taskId);
    try std.testing.expectEqual(TaskStatus.Succeeded, result.status);
    try std.testing.expectEqualStrings("done", result.outputs.?.string);
}

test "awaitTask: awaitTask resolves immediately when the task ID is not tracked" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    try std.testing.expect((try fixture.queue.awaitTask("unknown-task-id")) == null);
}

//
// Awaits a task on a helper thread and records that it returned.
//
fn awaitTaskOnThread(queue: *TaskQueue, taskId: []const u8, returned: *std.atomic.Value(bool)) void {
    _ = queue.awaitTask(taskId) catch {};
    returned.store(true, .release);
}

test "awaitTask: multiple awaitTask callers on the same ID all resolve when the task completes" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("slow-task", slowBlockedHandler);
    task_unblocked.reset();

    const taskId = try fixture.queue.addTask("slow-task", .null, null);
    var returned: [3]std.atomic.Value(bool) = .{ .init(false), .init(false), .init(false) };
    var threads: [3]std.Thread = undefined;
    for (&threads, &returned) |*thread, *returned_flag| {
        thread.* = try std.Thread.spawn(.{}, awaitTaskOnThread, .{ fixture.queue, taskId, returned_flag });
    }
    waitForWaiters(fixture.queue, 0, 3);
    task_unblocked.set(std.testing.io);
    for (threads) |thread| {
        thread.join();
    }

    for (returned) |returned_flag| {
        try std.testing.expect(returned_flag.load(.acquire));
    }
}

test "awaitTask: awaitTask resolves immediately when shutdown is called while waiting" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("slow-task", slowBlockedHandler);
    task_unblocked.reset();

    const taskId = try fixture.queue.addTask("slow-task", .null, null);

    // Shutdown before task completes: awaitTask should resolve immediately.
    const helper = try std.Thread.spawn(.{}, shutdownWhenWaiting, .{ fixture.queue, 0, 1 });
    const result = try fixture.queue.awaitTask(taskId);
    helper.join();

    try std.testing.expect(result == null);
}

test "awaitAllTasks: should wait for all tasks to complete" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    resetRecording();
    try registerHandler("test-task", countingHandler);

    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{\"id\":1}"), null);
    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{\"id\":2}"), null);
    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{\"id\":3}"), null);

    try fixture.queue.awaitAllTasks();

    try std.testing.expectEqual(@as(u32, 3), completed_count.load(.acquire));
}

test "awaitAllTasks: should resolve immediately if no tasks" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    try fixture.queue.awaitAllTasks();
}

test "awaitAllTasks: should handle mixed success and failure" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("success-task", doneHandler);
    try registerHandler("fail-task", failHandler);

    _ = try fixture.queue.addTask("success-task", .null, null);
    _ = try fixture.queue.addTask("fail-task", .null, null);
    _ = try fixture.queue.addTask("success-task", .null, null);

    // awaitAllTasks returns after all tasks complete, whether succeeded or failed.
    try fixture.queue.awaitAllTasks();
    try std.testing.expectEqual(@as(i64, 0), fixture.queue.numTasksInFlight);
}

test "awaitAllTasks: should handle empty queue" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    try fixture.queue.awaitAllTasks();
}

test "awaitAllTasks: awaitAllTasks resolves immediately when shutdown is called while waiting" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("slow-task", slowBlockedHandler);
    task_unblocked.reset();

    _ = try fixture.queue.addTask("slow-task", .null, null);

    // Shut down before the task completes: awaitAllTasks should return immediately.
    const helper = try std.Thread.spawn(.{}, shutdownWhenWaiting, .{ fixture.queue, 1, 0 });
    try fixture.queue.awaitAllTasks();
    helper.join();
}

test "awaitAllTasks: onTasksCancelled fires resolveAllWaiters, unblocking awaitAllTasks and awaitTask callers" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("slow-task", slowBlockedHandler);
    task_unblocked.reset();

    const taskId = try fixture.queue.addTask("slow-task", .null, null);
    var task_returned = std.atomic.Value(bool).init(false);
    const task_waiter = try std.Thread.spawn(.{}, awaitTaskOnThread, .{ fixture.queue, taskId, &task_returned });

    // cancelTasks fires onTasksCancelled which calls resolveAllWaiters.
    const helper = try std.Thread.spawn(.{}, cancelWhenWaiting, .{ fixture.queue, fixture.mockBackend, 1, 1 });
    try fixture.queue.awaitAllTasks();
    task_waiter.join();
    helper.join();

    try std.testing.expect(task_returned.load(.acquire));
}

test "awaitAllTasks: should wait for all tasks including slow ones" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    resetRecording();
    try registerHandler("slow-task", slowCountingHandler);

    _ = try fixture.queue.addTask("slow-task", .null, null);
    _ = try fixture.queue.addTask("slow-task", .null, null);
    _ = try fixture.queue.addTask("slow-task", .null, null);

    const startTime = nowMs();
    try fixture.queue.awaitAllTasks();
    const duration = nowMs() - startTime;

    try std.testing.expectEqual(@as(u32, 3), completed_count.load(.acquire));

    // Should take at least 100ms (with 2 workers, tasks run in parallel).
    try std.testing.expect(duration >= 100);
}

test "parallel execution: should execute tasks in parallel up to maxWorkers" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    resetRecording();
    try registerHandler("test-task", recordingHandler);

    // Add 5 tasks with 2 workers: should execute in batches.
    var task_number: i64 = 1;
    while (task_number <= 5) : (task_number += 1) {
        const data = try json(fixture.allocator(), try std.fmt.allocPrint(fixture.allocator(), "{{\"id\":{d},\"sleep\":true}}", .{task_number}));
        _ = try fixture.queue.addTask("test-task", data, null);
    }

    try fixture.queue.awaitAllTasks();

    // All tasks should complete.
    try std.testing.expectEqual(@as(usize, 5), execution_order_length);
}

test "parallel execution: should respect maxWorkers limit" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    resetRecording();

    const singleWorkerBackend = try MockWorkerPool.init(std.testing.io, 2, fixture.mockBackend.baseContext);
    defer singleWorkerBackend.deinit();
    setQueueBackend(singleWorkerBackend.queueBackend());
    const queueWithLimit = try TaskQueue.init(fixture.allocator(), std.testing.io, fixture.uuidGenerator.uuidGenerator(), "test-limited");
    try registerHandler("test-task", recordingHandler);

    // Add 10 tasks with maxWorkers=2.
    var task_number: i64 = 1;
    while (task_number <= 10) : (task_number += 1) {
        const data = try json(fixture.allocator(), try std.fmt.allocPrint(fixture.allocator(), "{{\"id\":{d},\"sleep\":true}}", .{task_number}));
        _ = try queueWithLimit.addTask("test-task", data, null);
    }

    try queueWithLimit.awaitAllTasks();
    queueWithLimit.deinit();

    // Should never exceed maxWorkers (2).
    try std.testing.expect(max_concurrent <= 2);
    try std.testing.expectEqual(@as(usize, 10), execution_order_length);
}

test "parallel execution: should process tasks in FIFO order" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    resetRecording();

    const singleWorkerBackend = try MockWorkerPool.init(std.testing.io, 1, fixture.mockBackend.baseContext);
    defer singleWorkerBackend.deinit();
    setQueueBackend(singleWorkerBackend.queueBackend());
    const singleQueue = try TaskQueue.init(fixture.allocator(), std.testing.io, fixture.uuidGenerator.uuidGenerator(), "test-fifo");
    try registerHandler("test-task", recordingHandler);

    // Add tasks in order.
    var task_number: i64 = 1;
    while (task_number <= 5) : (task_number += 1) {
        const data = try json(fixture.allocator(), try std.fmt.allocPrint(fixture.allocator(), "{{\"id\":{d}}}", .{task_number}));
        _ = try singleQueue.addTask("test-task", data, null);
    }

    try singleQueue.awaitAllTasks();
    singleQueue.deinit();

    // Tasks should be processed in order (FIFO).
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4, 5 }, execution_order[0..execution_order_length]);
}

test "task data handling: should pass task data to handler" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", dataRecordingHandler);

    const taskData = "{\"file\":\"test.jpg\",\"options\":{\"quality\":90},\"metadata\":{\"author\":\"test\"}}";
    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), taskData), null);
    try fixture.queue.awaitAllTasks();

    try std.testing.expectEqualStrings(taskData, try receivedJson(fixture.allocator()));
}

test "task data handling: should handle complex data structures" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", dataRecordingHandler);

    const complexData = "{\"nested\":{\"array\":[1,2,3],\"object\":{\"key\":\"value\"}},\"date\":\"2024-01-01T00:00:00.000Z\"}";
    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), complexData), null);
    try fixture.queue.awaitAllTasks();

    const nested = received_data.?.object.get("nested").?.object;
    try std.testing.expectEqual(@as(usize, 3), nested.get("array").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), nested.get("array").?.array.items[1].integer);
    try std.testing.expectEqualStrings("value", nested.get("object").?.object.get("key").?.string);
}

test "task data handling: should handle null data" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", dataRecordingHandler);

    _ = try fixture.queue.addTask("test-task", .null, null);
    try fixture.queue.awaitAllTasks();

    try std.testing.expect(received_data.? == .null);
}

// Not ported: "should handle undefined data" (std.json.Value has no undefined; JavaScript undefined data is not JSON).

test "task data handling: should handle empty object data" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", dataRecordingHandler);

    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), "{}"), null);
    try fixture.queue.awaitAllTasks();

    try std.testing.expectEqualStrings("{}", try receivedJson(fixture.allocator()));
}

test "task data handling: should handle array data" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", dataRecordingHandler);

    const arrayData = "[1,2,3,\"test\",{\"key\":\"value\"}]";
    _ = try fixture.queue.addTask("test-task", try json(fixture.allocator(), arrayData), null);
    try fixture.queue.awaitAllTasks();

    try std.testing.expectEqualStrings(arrayData, try receivedJson(fixture.allocator()));
}

test "shutdown: should terminate all workers" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    // Should not throw.
    fixture.queue.shutdown();
}

test "shutdown: should allow shutdown multiple times" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    // Should not throw.
    fixture.queue.shutdown();
    fixture.queue.shutdown();
}

test "shutdown: should prevent callbacks from being called after shutdown" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    var callbackCalled = false;
    _ = try fixture.queue.onTaskComplete(.{ .context = &callbackCalled, .function = setFlagOnComplete });

    // Shutdown the queue.
    fixture.queue.shutdown();

    _ = try fixture.queue.addTask("test-task", .null, null);

    // Wait a bit to ensure any callbacks would have fired.
    sleepMs(100);
    try fixture.queue.awaitAllTasks();

    // Callback should not be called after shutdown.
    try std.testing.expect(!callbackCalled);
}

test "shutdown: should prevent task messages from being received after shutdown" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", messageSendingHandler);

    var callbackCalled = false;
    _ = try fixture.queue.onTaskMessage("test-message", .{ .context = &callbackCalled, .function = setFlagOnMessage });

    // Shutdown the queue.
    fixture.queue.shutdown();

    _ = try fixture.queue.addTask("test-task", .null, null);

    // Wait a bit to ensure any callbacks would have fired.
    sleepMs(100);
    try fixture.queue.awaitAllTasks();

    // Callback should not be called after shutdown.
    try std.testing.expect(!callbackCalled);
}

//
// A backend that records the task IDs it is given and which of its subscriptions were removed
// (the object-literal backends of the TypeScript tests).
//
const RecordingBackend = struct {
    // The task IDs passed to addTask (static storage, no allocation needed).
    capturedIds: [4][]const u8,

    // Number of valid entries in capturedIds.
    capturedCount: usize,

    // Set when the onTaskAdded subscription is removed.
    onTaskAddedUnsubscribeCalled: bool,

    // Set when the onTaskComplete subscription is removed.
    onTaskCompleteUnsubscribeCalled: bool,

    // Set when the onAnyTaskMessage subscription is removed.
    onAnyTaskMessageUnsubscribeCalled: bool,

    //
    // Gets the IQueueBackend interface for this backend.
    //
    fn queueBackend(self: *RecordingBackend) IQueueBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IQueueBackend functions of this backend.
    //
    const vtable: IQueueBackend.VTable = .{
        .addTask = addTask,
        .onTaskAdded = onTaskAdded,
        .onTaskComplete = onTaskComplete,
        .onTaskMessage = onTaskMessage,
        .onAnyTaskMessage = onAnyTaskMessage,
        .cancelTasks = cancelTasks,
        .onTasksCancelled = onTasksCancelled,
        .shutdown = shutdown,
    };

    //
    // Records the task ID.
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8) anyerror![]const u8 {
        _ = allocator;
        _ = io;
        _ = @"type";
        _ = data;
        _ = source;
        const self: *RecordingBackend = @ptrCast(@alignCast(ptr));
        self.capturedIds[self.capturedCount] = taskId orelse "";
        self.capturedCount += 1;
        return taskId orelse "";
    }

    //
    // Records which subscription was removed (the key says which one).
    //
    fn unsubscribe(context: ?*anyopaque, key: usize) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(context.?));
        switch (key) {
            1 => self.onTaskAddedUnsubscribeCalled = true,
            2 => self.onTaskCompleteUnsubscribeCalled = true,
            3 => self.onAnyTaskMessageUnsubscribeCalled = true,
            else => {},
        }
    }

    //
    // Returns the unsubscribe function for onTaskAdded.
    //
    fn onTaskAdded(ptr: *anyopaque, source: []const u8, callback: types.TaskAddedCallback) anyerror!types.UnsubscribeFn {
        _ = source;
        _ = callback;
        return .{ .context = ptr, .key = 1, .function = unsubscribe };
    }

    //
    // Returns the unsubscribe function for onTaskComplete.
    //
    fn onTaskComplete(ptr: *anyopaque, callback: types.WorkerTaskCompletionCallback) anyerror!types.UnsubscribeFn {
        _ = callback;
        return .{ .context = ptr, .key = 2, .function = unsubscribe };
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskMessage(ptr: *anyopaque, messageType: []const u8, callback: types.TaskMessageCallback) anyerror!types.UnsubscribeFn {
        _ = messageType;
        _ = callback;
        return .{ .context = ptr, .key = 0, .function = unsubscribe };
    }

    //
    // Returns the unsubscribe function for onAnyTaskMessage.
    //
    fn onAnyTaskMessage(ptr: *anyopaque, callback: types.TaskMessageCallback) anyerror!types.UnsubscribeFn {
        _ = callback;
        return .{ .context = ptr, .key = 3, .function = unsubscribe };
    }

    //
    // Does nothing.
    //
    fn cancelTasks(ptr: *anyopaque, source: []const u8) void {
        _ = ptr;
        _ = source;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTasksCancelled(ptr: *anyopaque, source: []const u8, callback: types.TasksCancelledCallback) anyerror!types.UnsubscribeFn {
        _ = source;
        _ = callback;
        return .{ .context = ptr, .key = 0, .function = unsubscribe };
    }

    //
    // Does nothing.
    //
    fn shutdown(ptr: *anyopaque) void {
        _ = ptr;
    }
};

test "shutdown: should unsubscribe from all backend events on shutdown" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    // Create a mock backend that tracks unsubscribe calls.
    var mockTestBackend: RecordingBackend = std.mem.zeroes(RecordingBackend);
    setQueueBackend(mockTestBackend.queueBackend());
    const testQueue = try TaskQueue.init(fixture.allocator(), std.testing.io, fixture.uuidGenerator.uuidGenerator(), "test-unsub");

    // Shutdown should call all unsubscribe functions.
    testQueue.shutdown();

    try std.testing.expect(mockTestBackend.onTaskCompleteUnsubscribeCalled);
    try std.testing.expect(mockTestBackend.onAnyTaskMessageUnsubscribeCalled);
    try std.testing.expect(mockTestBackend.onTaskAddedUnsubscribeCalled);
    testQueue.deinit();
}

test "source isolation: tasks from source A do not trigger completion callbacks of source B" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    const queueB = try TaskQueue.init(fixture.allocator(), std.testing.io, fixture.uuidGenerator.uuidGenerator(), "source-b");
    var callbackBFired = false;
    _ = try queueB.onTaskComplete(.{ .context = &callbackBFired, .function = setFlagOnComplete });

    // Add a task to queue A (source "test").
    _ = try fixture.queue.addTask("test-task", .null, null);
    try fixture.queue.awaitAllTasks();

    // Nothing is queued for queue B.
    try queueB.awaitAllTasks();
    try std.testing.expect(!callbackBFired);

    queueB.deinit();
}

test "addTask with explicit taskId: addTask with an explicit taskId passes that ID through to the backend" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();

    const explicitId = "my-explicit-task-id";
    var recordingBackend: RecordingBackend = std.mem.zeroes(RecordingBackend);
    setQueueBackend(recordingBackend.queueBackend());
    const testQueue = try TaskQueue.init(fixture.allocator(), std.testing.io, fixture.uuidGenerator.uuidGenerator(), "test-explicit");

    const returnedId = try testQueue.addTask("test-task", .null, explicitId);

    try std.testing.expectEqualStrings(explicitId, returnedId);
    try std.testing.expectEqual(@as(usize, 1), recordingBackend.capturedCount);
    try std.testing.expectEqualStrings(explicitId, recordingBackend.capturedIds[0]);

    testQueue.deinit();
}

test "constructor options: should use custom UUID generator" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    // The TestUuidGenerator keeps its counter in TEST_TMP_DIR.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var environ_map = std.process.Environ.Map.init(fixture.allocator());
    try environ_map.put("TEST_TMP_DIR", try std.fmt.allocPrint(fixture.allocator(), ".zig-cache/tmp/{s}", .{tmp_dir.sub_path}));
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    var customUuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(fixture.allocator());
    const customQueue = try TaskQueue.init(fixture.allocator(), std.testing.io, customUuidGenerator.uuidGenerator(), "test-custom");

    const taskId1 = try customQueue.addTask("test-task", .null, null);
    const taskId2 = try customQueue.addTask("test-task", .null, null);

    // TestUuidGenerator creates deterministic UUIDs.
    try std.testing.expect(taskId1.len > 0);
    try std.testing.expect(taskId2.len > 0);
    try std.testing.expect(!std.mem.eql(u8, taskId1, taskId2));

    try customQueue.awaitAllTasks();
    customQueue.deinit();
}

test "constructor options: should use default UUID generator when not provided" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    var customUuidGenerator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    const defaultQueue = try TaskQueue.init(fixture.allocator(), std.testing.io, customUuidGenerator.uuidGenerator(), "test-default");

    const taskId1 = try defaultQueue.addTask("test-task", .null, null);
    const taskId2 = try defaultQueue.addTask("test-task", .null, null);

    try std.testing.expect(taskId1.len > 0);
    try std.testing.expect(taskId2.len > 0);
    try std.testing.expect(!std.mem.eql(u8, taskId1, taskId2));

    try defaultQueue.awaitAllTasks();
    defaultQueue.deinit();
}

//
// A handler that fails with a plain Zig error that has no recorded message
// (the closest Zig equivalent of throwing a value that is not an Error).
//
fn plainZigErrorHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return error.StringError;
}

//
// A handler that throws "Custom error message".
//
fn customErrorHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return errors.throwError("Custom error message", .{});
}

test "error handling: should handle handler throwing non-Error objects" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("throw-string", plainZigErrorHandler);

    var recorder: ResultsRecorder = .{ .allocator = fixture.allocator(), .statuses = .empty, .errorMessages = .empty, .hasError = .empty };
    _ = try fixture.queue.onTaskComplete(.{ .context = &recorder, .function = ResultsRecorder.record });

    _ = try fixture.queue.addTask("throw-string", .null, null);
    try fixture.queue.awaitAllTasks();

    try std.testing.expectEqual(@as(usize, 1), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Failed, recorder.statuses.items[0]);
    try std.testing.expect(recorder.hasError.items[0]);
    try std.testing.expectEqualStrings("StringError", recorder.errorMessages.items[0]);
}

// Not ported: "should handle handler throwing null" (a Zig handler can only fail with an error value).

test "error handling: should preserve error messages" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("custom-error", customErrorHandler);

    var recorder: ResultsRecorder = .{ .allocator = fixture.allocator(), .statuses = .empty, .errorMessages = .empty, .hasError = .empty };
    _ = try fixture.queue.onTaskComplete(.{ .context = &recorder, .function = ResultsRecorder.record });

    _ = try fixture.queue.addTask("custom-error", .null, null);
    try fixture.queue.awaitAllTasks();

    try std.testing.expectEqual(@as(usize, 1), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Failed, recorder.statuses.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, recorder.errorMessages.items[0], "Custom error message") != null);
}

//
// Records the progress strings of "replicate-progress" messages (like replicateDatabase's onProgress).
//
const ProgressRecorder = struct {
    // Allocator for the copies.
    allocator: std.mem.Allocator,

    // The progress strings received.
    progress: std.ArrayList([]const u8),

    //
    // The message callback.
    //
    fn record(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(context.?));
        try self.progress.append(self.allocator, try self.allocator.dupe(u8, data.message.object.get("progress").?.string));
    }
};

//
// A handler that sends two progress messages and a message of another type, then returns.
//
fn progressHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = data;
    context.sendMessage(try json(allocator, "{\"type\":\"replicate-progress\",\"databasePath\":\"/db\",\"progress\":\"one\"}"));
    context.sendMessage(try json(allocator, "{\"type\":\"other\",\"progress\":\"ignored\"}"));
    context.sendMessage(try json(allocator, "{\"type\":\"replicate-progress\",\"databasePath\":\"/db\",\"progress\":\"two\"}"));
    return json(allocator, "{\"filesCopied\":2}");
}

test "onTaskMessage delivers only messages of the registered type, in order, before awaitTask returns" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("progress-task", progressHandler);

    var recorder: ProgressRecorder = .{ .allocator = fixture.allocator(), .progress = .empty };
    const unsubscribe = try fixture.queue.onTaskMessage("replicate-progress", .{ .context = &recorder, .function = ProgressRecorder.record });

    const taskId = try fixture.queue.addTask("progress-task", .null, null);
    const result = (try fixture.queue.awaitTask(taskId)).?;

    try std.testing.expectEqual(TaskStatus.Succeeded, result.status);
    try std.testing.expectEqual(@as(i64, 2), result.outputs.?.object.get("filesCopied").?.integer);
    try std.testing.expectEqual(@as(usize, 2), recorder.progress.items.len);
    try std.testing.expectEqualStrings("one", recorder.progress.items[0]);
    try std.testing.expectEqualStrings("two", recorder.progress.items[1]);

    // After unsubscribing no more messages are delivered.
    unsubscribe.call();
    const secondTaskId = try fixture.queue.addTask("progress-task", .null, null);
    _ = try fixture.queue.awaitTask(secondTaskId);
    try std.testing.expectEqual(@as(usize, 2), recorder.progress.items.len);
}

test "onTaskComplete unsubscribe removes the callback" {
    var fixture: Fixture = undefined;
    try fixture.init(2);
    defer fixture.deinit();
    try registerHandler("test-task", doneHandler);

    var callbackCalled = false;
    const unsubscribe = try fixture.queue.onTaskComplete(.{ .context = &callbackCalled, .function = setFlagOnComplete });
    unsubscribe.call();

    _ = try fixture.queue.addTask("test-task", .null, null);
    try fixture.queue.awaitAllTasks();
    try std.testing.expect(!callbackCalled);
}

test "TaskQueue.init throws when no backend is registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    setQueueBackend(null);
    try std.testing.expectError(error.Thrown, TaskQueue.init(arena.allocator(), std.testing.io, uuid_generator.uuidGenerator(), "x"));
}

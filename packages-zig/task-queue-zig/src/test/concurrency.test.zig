//
// Tests for the parts of the queue that only show themselves when more than one thing is happening at
// once: a worker taking the next task while another is still busy, a task failing, a task being
// cancelled, and every path that shuts the queue down.
//

const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const types = task_queue_zig.types;
const ITaskResult = types.ITaskResult;
const ITaskContext = types.ITaskContext;
const ITaskMessageData = types.ITaskMessageData;
const TaskStatus = types.TaskStatus;
const registerHandler = task_queue_zig.worker.registerHandler;
const setQueueBackend = task_queue_zig.queue_backend.setQueueBackend;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const mock_worker_pool = task_queue_zig.mock_worker_pool;
const MockWorkerPool = mock_worker_pool.MockWorkerPool;
const errors = utils.errors;

//
// The parts of a queue test's world that several of the tests below share.
//
const Fixture = struct {
    // Allocator for the queues (task IDs and the results awaitTask returns).
    arena: std.heap.ArenaAllocator,

    // The allocator of the test.
    allocator: std.mem.Allocator,

    // Generates the task IDs.
    uuidGenerator: utils.random_uuid_generator.RandomUuidGenerator,

    // Provides timestamps to the tasks.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The in-process backend registered for the duration of the test.
    mockBackend: *MockWorkerPool,

    //
    // The context every task of a test runs with.
    //
    fn baseContext(self: *Fixture) mock_worker_pool.IBaseContext {
        return .{
            .uuidGenerator = self.uuidGenerator.uuidGenerator(),
            .timestampProvider = self.timestampProvider.timestampProvider(),
            .sessionId = "test-session",
        };
    }

    //
    // Creates the allocator and the generators a test needs, with no backend of its own.
    //
    fn setup(self: *Fixture) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.allocator = self.arena.allocator();
        self.uuidGenerator = .{};
        self.timestampProvider = .{};
        self.mockBackend = undefined;
    }

    //
    // Creates the allocator and the generators, registers a backend and creates a queue on it.
    //
    fn init(self: *Fixture, maxConcurrent: usize, source: []const u8) !*TaskQueue {
        self.setup();
        self.mockBackend = try MockWorkerPool.init(std.testing.io, maxConcurrent, self.baseContext());
        setQueueBackend(self.mockBackend.queueBackend());
        return try TaskQueue.init(self.allocator, std.testing.io, self.uuidGenerator.uuidGenerator(), source);
    }

    //
    // Shuts the queue down, waits for the backend's tasks and frees everything.
    //
    fn deinit(self: *Fixture, queue: *TaskQueue) void {
        queue.deinit();
        setQueueBackend(null);
        self.mockBackend.deinit();
        self.arena.deinit();
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
// Released by a test to let a blocked task finish.
//
var task_release: std.Io.Event = .unset;

//
// Waits until the release is set, giving up after a generous timeout so a broken test fails instead of
// hanging the suite.
//
fn waitForRelease(io: std.Io) void {
    task_release.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(30000), .clock = .awake } }) catch {};
}

//
// The names of the tasks that ran, in the order they started, with the buffer each name was copied
// into (the task data is freed when the task finishes).
//
var ran_names: [8][32]u8 = undefined;
var ran_count: std.atomic.Value(usize) = .init(0);

//
// Whether the cancellation-checking task reported what isCancelled said when it finished. The test
// reads it only after awaitAllTasks, which returns after the task's result has been dispatched, so
// these need no synchronisation of their own.
//
var cancellation_was_reported = false;
var cancellation_saw_true = false;

//
// The names of the tasks that sent a message.
//
var messaged_names: [8][32]u8 = undefined;
var messaged_count: std.atomic.Value(usize) = .init(0);

//
// Records a name in one of the buffers above and returns how many are recorded.
//
fn recordName(buffer: [][32]u8, counter: *std.atomic.Value(usize), name: []const u8) usize {
    const index = counter.fetchAdd(1, .acq_rel);
    @memcpy(buffer[index][0..name.len], name);
    return index;
}

//
// A handler that records the task's name, holds the slot when its data says to, and returns "done".
//
fn recordingTaskHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = context;
    const name = data.object.get("name").?.string;
    _ = recordName(&ran_names, &ran_count, name);
    if (data.object.get("hold") != null) {
        waitForRelease(io);
    }
    return .{ .string = "done" };
}

//
// A handler that records the task's name, sends a message and returns "done".
//
fn messagingTaskHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = io;
    const name = data.object.get("name").?.string;
    _ = recordName(&messaged_names, &messaged_count, name);
    context.sendMessage(try json(allocator, "{\"type\":\"note\"}"));
    return .{ .string = "done" };
}

//
// A handler that reports whether it has been cancelled and then returns "done".
//
fn cancellationCheckingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    var attempts: usize = 0;
    while (!context.isCancelled() and attempts < 3000) : (attempts += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    cancellation_saw_true = context.isCancelled();
    cancellation_was_reported = true;
    return .{ .string = "done" };
}

//
// A handler that fails.
//
fn failingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return errors.throwError("task blew up", .{});
}

//
// Records the status of every result it is given.
//
const StatusRecorder = struct {
    // The statuses, in order.
    statuses: std.ArrayList(TaskStatus),

    // The error message of each result ("" when there is none).
    errorMessages: std.ArrayList([]const u8),

    // Allocator for the copies.
    allocator: std.mem.Allocator,

    //
    // The completion callback.
    //
    fn record(context: ?*anyopaque, result: ITaskResult) anyerror!void {
        const self: *StatusRecorder = @ptrCast(@alignCast(context.?));
        try self.statuses.append(self.allocator, result.status);
        try self.errorMessages.append(self.allocator, try self.allocator.dupe(u8, if (result.@"error") |task_error| task_error.message else ""));
    }
};

//
// Records the task ID of every message it is given.
//
const MessageIdRecorder = struct {
    // The task IDs, in order.
    taskIds: std.ArrayList([]const u8),

    // Allocator for the copies.
    allocator: std.mem.Allocator,

    //
    // The message callback.
    //
    fn record(context: ?*anyopaque, data: ITaskMessageData) anyerror!void {
        const self: *MessageIdRecorder = @ptrCast(@alignCast(context.?));
        try self.taskIds.append(self.allocator, data.taskId);
    }
};

//
// Awaits a task on a helper thread and records the status it resolved with ("" when it resolved with
// no result at all).
//
const IAwaitOutcome = struct {
    // The status of the result, or null when the wait resolved with no result.
    status: ?TaskStatus,

    // The error the wait returned, if any.
    failure: ?anyerror,
};

//
fn awaitTaskOnThread(queue: *TaskQueue, taskId: []const u8, outcome: *IAwaitOutcome) void {
    const result = queue.awaitTask(taskId) catch |err| {
        outcome.status = null;
        outcome.failure = err;
        return;
    };
    outcome.failure = null;
    outcome.status = if (result) |task_result| task_result.status else null;
}

//
// Waits until the queue has the given numbers of awaitAllTasks and awaitTask callers blocked.
//
fn waitForWaiters(queue: *TaskQueue, awaitAllCount: usize, awaitTaskCount: usize) void {
    var attempts: usize = 0;
    while (attempts < 30000) : (attempts += 1) {
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
// Shuts the queue down once the callers are blocked, then releases the task.
//
fn shutdownWhenWaiting(queue: *TaskQueue, awaitAllCount: usize, awaitTaskCount: usize) void {
    waitForWaiters(queue, awaitAllCount, awaitTaskCount);
    queue.shutdown();
    task_release.set(std.testing.io);
}

//
// A backend that counts how many times each of the calls that shut a queue down is made, so that the
// tests can tell a second cancel apart from a first one.
//
const CountingBackend = struct {
    // How many times cancelTasks has been called.
    cancelTasksCalls: u32,

    // The sources cancelTasks was called with, in order (copied, because the queue frees its own
    // copy of its source when it is freed).
    cancelledSources: [4][32]u8,

    // The number of bytes of each recorded source that are valid.
    cancelledSourceLengths: [4]usize,

    // How many entries of cancelledSources are valid.
    cancelledCount: usize,

    // How many times shutdown has been called.
    shutdownCalls: u32,

    //
    // Gets the IQueueBackend interface for this backend.
    //
    fn queueBackend(self: *CountingBackend) IQueueBackend {
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
    // Returns the task ID it was given.
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?types.TaskPriority) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = @"type";
        _ = data;
        _ = source;
        _ = priority;
        return taskId orelse "task-id";
    }

    //
    // Does nothing.
    //
    fn noUnsubscribe(context: ?*anyopaque, key: usize) void {
        _ = context;
        _ = key;
    }

    //
    // An unsubscribe function that does nothing.
    //
    const no_unsubscribe: types.UnsubscribeFn = .{ .context = null, .key = 0, .function = noUnsubscribe };

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskAdded(ptr: *anyopaque, source: []const u8, callback: types.TaskAddedCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskComplete(ptr: *anyopaque, callback: types.WorkerTaskCompletionCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTaskMessage(ptr: *anyopaque, messageType: []const u8, callback: types.TaskMessageCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = messageType;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onAnyTaskMessage(ptr: *anyopaque, callback: types.TaskMessageCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Records the source.
    //
    fn cancelTasks(ptr: *anyopaque, source: []const u8) void {
        const self: *CountingBackend = @ptrCast(@alignCast(ptr));
        self.cancelTasksCalls += 1;
        if (self.cancelledCount < self.cancelledSources.len) {
            @memcpy(self.cancelledSources[self.cancelledCount][0..source.len], source);
            self.cancelledSourceLengths[self.cancelledCount] = source.len;
            self.cancelledCount += 1;
        }
    }

    //
    // Returns a no-op unsubscribe function.
    //
    fn onTasksCancelled(ptr: *anyopaque, source: []const u8, callback: types.TasksCancelledCallback) anyerror!types.UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Counts the call.
    //
    fn shutdown(ptr: *anyopaque) void {
        const self: *CountingBackend = @ptrCast(@alignCast(ptr));
        self.shutdownCalls += 1;
    }
};

//
// A pool of one worker: the task named "busy" takes the only slot and holds it, so the second task is
// left waiting until it finishes. This is the shape the tests below use to get a task that is running
// while another is queued.
//
fn withOneWorkerBusy(fixture: *Fixture) !struct { backend: *MockWorkerPool, queue: *TaskQueue } {
    // A pool of one worker is the whole point: the busy task takes the only slot, so whatever is
    // added after it is left waiting until the busy task finishes.
    const backend = try MockWorkerPool.init(std.testing.io, 1, fixture.baseContext());
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(fixture.allocator, std.testing.io, fixture.uuidGenerator.uuidGenerator(), "busy-source");
    _ = try queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"busy\",\"hold\":true}"), null, null);
    // Wait until the first task has taken the slot, so the second one is definitely still waiting.
    var attempts: usize = 0;
    while (ran_count.load(.acquire) < 1 and attempts < 3000) : (attempts += 1) {
        sleepMs(1);
    }
    return .{ .backend = backend, .queue = queue };
}

test "a worker takes the next task as soon as the one it is running finishes" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-task", recordingTaskHandler);
    ran_count.store(0, .release);
    task_release.reset();
    fixture.setup();

    const busy = try withOneWorkerBusy(&fixture);
    defer {
        task_release.set(std.testing.io);
        busy.queue.deinit();
        setQueueBackend(null);
        busy.backend.deinit();
        fixture.arena.deinit();
    }

    _ = try busy.queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"next\"}"), null, null);

    // The worker is busy, so the second task is waiting rather than running.
    try std.testing.expectEqual(@as(usize, 1), ran_count.load(.acquire));
    const pendingBefore = try busy.backend.getPendingTaskTypes(fixture.allocator);
    try std.testing.expectEqual(@as(usize, 1), pendingBefore.len);
    try std.testing.expectEqualStrings("concurrency-task", pendingBefore[0]);

    task_release.set(std.testing.io);
    try busy.queue.awaitAllTasks();

    // It ran as soon as the slot was free, which is what a worker pool is for.
    try std.testing.expectEqual(@as(usize, 2), ran_count.load(.acquire));
    try std.testing.expectEqualStrings("busy", ran_names[0][0.."busy".len]);
    try std.testing.expectEqualStrings("next", ran_names[1][0.."next".len]);
    try std.testing.expectEqual(@as(usize, 0), (try busy.backend.getPendingTaskTypes(fixture.allocator)).len);
}

test "a task that fails still hands the slot to the next task" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-task", recordingTaskHandler);
    try registerHandler("concurrency-failing-task", failingHandler);
    ran_count.store(0, .release);
    task_release.reset();
    fixture.setup();

    const busy = try withOneWorkerBusy(&fixture);
    var recorder: StatusRecorder = .{
        .statuses = .empty,
        .errorMessages = .empty,
        .allocator = fixture.allocator,
    };
    defer {
        task_release.set(std.testing.io);
        busy.queue.deinit();
        setQueueBackend(null);
        busy.backend.deinit();
        fixture.arena.deinit();
    }
    _ = try busy.queue.onTaskComplete(.{ .context = &recorder, .function = StatusRecorder.record });

    // The failing task is queued behind the busy one, so it fails only once the slot is free.
    _ = try busy.queue.addTask("concurrency-failing-task", try json(fixture.allocator, "{\"name\":\"failing\"}"), null, null);
    _ = try busy.queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"after-failure\"}"), null, null);

    task_release.set(std.testing.io);
    try busy.queue.awaitAllTasks();

    // Three results: the busy task, then the failure, then the task queued behind it.
    try std.testing.expectEqual(@as(usize, 3), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Succeeded, recorder.statuses.items[0]);
    try std.testing.expectEqual(TaskStatus.Failed, recorder.statuses.items[1]);
    try std.testing.expectEqualStrings("task blew up", recorder.errorMessages.items[1]);
    try std.testing.expectEqual(TaskStatus.Succeeded, recorder.statuses.items[2]);
    // The two recording tasks ran; the failing one has a handler of its own that records nothing.
    try std.testing.expectEqual(@as(usize, 2), ran_count.load(.acquire));
    try std.testing.expectEqualStrings("busy", ran_names[0][0.."busy".len]);
    try std.testing.expectEqualStrings("after-failure", ran_names[1][0.."after-failure".len]);
}

test "a running task sees that it has been cancelled" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-cancellation-task", cancellationCheckingHandler);
    cancellation_was_reported = false;
    cancellation_saw_true = false;

    var queue = try fixture.init(2, "cancel-source");
    defer fixture.deinit(queue);

    _ = try queue.addTask("concurrency-cancellation-task", .null, null, null);

    // The task polls isCancelled, so cancelling the source is what it is waiting for.
    fixture.mockBackend.cancelTasks("cancel-source");

    try queue.awaitAllTasks();

    // The task saw the cancellation through its own context, which is the only way a handler learns
    // it should stop.
    try std.testing.expect(cancellation_was_reported);
    try std.testing.expect(cancellation_saw_true);
}

test "cancelTasks drops the waiting tasks of the cancelled source and leaves other sources alone" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-task", recordingTaskHandler);
    ran_count.store(0, .release);
    task_release.reset();
    fixture.setup();

    const busy = try withOneWorkerBusy(&fixture);
    var other_queue = try TaskQueue.init(fixture.allocator, std.testing.io, fixture.uuidGenerator.uuidGenerator(), "other-source");
    defer {
        task_release.set(std.testing.io);
        busy.queue.deinit();
        other_queue.deinit();
        setQueueBackend(null);
        busy.backend.deinit();
        fixture.arena.deinit();
    }

    // Three waiting tasks: two of the cancelled source and one of another.
    _ = try busy.queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"cancelled-1\"}"), null, null);
    _ = try busy.queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"cancelled-2\"}"), null, null);
    _ = try other_queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"other\"}"), null, null);
    try std.testing.expectEqual(@as(usize, 3), (try busy.backend.getPendingTaskTypes(fixture.allocator)).len);

    busy.backend.cancelTasks("busy-source");

    // Only the other source's task is left waiting.
    const pendingAfter = try busy.backend.getPendingTaskTypes(fixture.allocator);
    try std.testing.expectEqual(@as(usize, 1), pendingAfter.len);

    task_release.set(std.testing.io);
    try other_queue.awaitAllTasks();

    // The cancelled source's tasks never ran; the other source's did.
    try std.testing.expectEqual(@as(usize, 2), ran_count.load(.acquire));
    try std.testing.expectEqualStrings("busy", ran_names[0][0.."busy".len]);
    try std.testing.expectEqualStrings("other", ran_names[1][0.."other".len]);
}

test "a task cancelled while it runs still reports its result, and its waiter was already given none" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-task", recordingTaskHandler);
    task_release.reset();

    var queue = try fixture.init(1, "cancel-source");
    defer fixture.deinit(queue);

    var recorder: StatusRecorder = .{
        .statuses = .empty,
        .errorMessages = .empty,
        .allocator = fixture.allocator,
    };
    _ = try queue.onTaskComplete(.{ .context = &recorder, .function = StatusRecorder.record });
    const taskId = try queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"busy\",\"hold\":true}"), null, null);

    var outcome: IAwaitOutcome = .{ .status = null, .failure = null };
    const waiter = try std.Thread.spawn(.{}, awaitTaskOnThread, .{ queue, taskId, &outcome });
    waitForWaiters(queue, 0, 1);

    // Cancelling resolves the waiter with no result, because the task could still have failed or
    // succeeded and the caller is told nothing came of it.
    fixture.mockBackend.cancelTasks("cancel-source");
    waiter.join();
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(outcome.status == null);

    // The task was already running, so cancelling does not stop it: it finishes and reports.
    task_release.set(std.testing.io);

    // Nothing is awaiting the result now (the waiter was resolved by the cancel), so the queue's
    // callbacks run on whichever thread next waits on it.
    _ = try queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"after-cancel\"}"), null, null);
    try queue.awaitAllTasks();

    try std.testing.expectEqual(@as(usize, 2), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Succeeded, recorder.statuses.items[0]);
    try std.testing.expectEqual(TaskStatus.Succeeded, recorder.statuses.items[1]);
}

test "shutdown drops the tasks still waiting for a slot" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-task", recordingTaskHandler);
    task_release.reset();
    ran_count.store(0, .release);
    fixture.setup();

    const busy = try withOneWorkerBusy(&fixture);
    defer {
        task_release.set(std.testing.io);
        busy.queue.deinit();
        setQueueBackend(null);
        busy.backend.deinit();
        fixture.arena.deinit();
    }
    _ = try busy.queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"dropped\"}"), null, null);
    try std.testing.expectEqual(@as(usize, 1), (try busy.backend.getPendingTaskTypes(fixture.allocator)).len);

    // Shutting the queue down cancels the backend's tasks of its source, which takes the waiting one
    // with it and leaves the running one to finish on its own.
    busy.queue.shutdown();
    try std.testing.expectEqual(@as(usize, 0), (try busy.backend.getPendingTaskTypes(fixture.allocator)).len);

    task_release.set(std.testing.io);
    sleepMs(100);
    try std.testing.expectEqual(@as(usize, 1), ran_count.load(.acquire));
}

test "deinit after an explicit shutdown does not cancel the source a second time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend: CountingBackend = .{
        .cancelTasksCalls = 0,
        .cancelledSources = undefined,
        .cancelledSourceLengths = undefined,
        .cancelledCount = 0,
        .shutdownCalls = 0,
    };
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(arena.allocator(), std.testing.io, uuid_generator.uuidGenerator(), "counted-source");

    queue.shutdown();
    queue.shutdown();
    queue.deinit();

    // Repeated shutdowns and the deinit that follows them are two cancels of the source, not three:
    // the deinit must not signal every running task a second time.
    try std.testing.expectEqual(@as(u32, 2), backend.cancelTasksCalls);

    // The queue never shuts the backend down itself: that is the process's call, not a queue's.
    try std.testing.expectEqual(@as(u32, 0), backend.shutdownCalls);

    setQueueBackend(null);
}

test "deinit on a queue that was never shut down cancels the source once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var backend: CountingBackend = .{
        .cancelTasksCalls = 0,
        .cancelledSources = undefined,
        .cancelledSourceLengths = undefined,
        .cancelledCount = 0,
        .shutdownCalls = 0,
    };
    setQueueBackend(backend.queueBackend());
    const queue = try TaskQueue.init(arena.allocator(), std.testing.io, uuid_generator.uuidGenerator(), "counted-source");

    queue.deinit();

    // Nothing else shut it down, so deinit is what cancels the source. Without that, freeing a queue
    // would leave its tasks running with nobody waiting for them.
    try std.testing.expectEqual(@as(u32, 1), backend.cancelTasksCalls);
    try std.testing.expectEqual(@as(usize, 1), backend.cancelledCount);
    try std.testing.expectEqualStrings("counted-source", backend.cancelledSources[0][0..backend.cancelledSourceLengths[0]]);
    try std.testing.expectEqual(@as(u32, 0), backend.shutdownCalls);

    setQueueBackend(null);
}

test "a message sent by a task of another source is not delivered" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-message-task", messagingTaskHandler);
    messaged_count.store(0, .release);

    var queue = try fixture.init(2, "message-source");
    var other_queue = try TaskQueue.init(fixture.allocator, std.testing.io, fixture.uuidGenerator.uuidGenerator(), "other-source");
    defer {
        queue.deinit();
        other_queue.deinit();
        setQueueBackend(null);
        fixture.mockBackend.deinit();
        fixture.arena.deinit();
    }

    var recorder: MessageIdRecorder = .{
        .taskIds = .empty,
        .allocator = fixture.allocator,
    };
    _ = try queue.onAnyTaskMessage(.{ .context = &recorder, .function = MessageIdRecorder.record });

    _ = try other_queue.addTask("concurrency-message-task", try json(fixture.allocator, "{\"name\":\"other\"}"), null, null);
    try other_queue.awaitAllTasks();
    try queue.awaitAllTasks();

    // The task ran, but it belongs to a queue that did not add it, so its messages are not this
    // queue's business.
    try std.testing.expectEqual(@as(usize, 1), messaged_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), recorder.taskIds.items.len);

    // The queue's own task does deliver.
    const ownTaskId = try queue.addTask("concurrency-message-task", try json(fixture.allocator, "{\"name\":\"own\"}"), null, null);
    _ = try queue.awaitTask(ownTaskId);
    try std.testing.expectEqual(@as(usize, 1), recorder.taskIds.items.len);
    try std.testing.expectEqualStrings(ownTaskId, recorder.taskIds.items[0]);
}

test "a task with no registered handler fails with the worker's message" {
    var fixture: Fixture = undefined;
    var queue = try fixture.init(2, "unhandled-source");
    defer fixture.deinit(queue);

    var recorder: StatusRecorder = .{
        .statuses = .empty,
        .errorMessages = .empty,
        .allocator = fixture.allocator,
    };
    _ = try queue.onTaskComplete(.{ .context = &recorder, .function = StatusRecorder.record });

    // No handler is registered for this type, which is what a task queued for a feature that is not
    // wired up looks like. It must be reported as a failed task, not swallowed.
    _ = try queue.addTask("concurrency-no-such-handler", .null, null, null);
    try queue.awaitAllTasks();

    try std.testing.expectEqual(@as(usize, 1), recorder.statuses.items.len);
    try std.testing.expectEqual(TaskStatus.Failed, recorder.statuses.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, recorder.errorMessages.items[0], "No handler registered for task type: concurrency-no-such-handler.") != null);
}

test "shutdown while a task is running resolves a waiter and the task still finishes" {
    var fixture: Fixture = undefined;
    try registerHandler("concurrency-task", recordingTaskHandler);
    task_release.reset();

    var queue = try fixture.init(1, "shutdown-source");
    defer fixture.deinit(queue);

    var recorder: StatusRecorder = .{
        .statuses = .empty,
        .errorMessages = .empty,
        .allocator = fixture.allocator,
    };
    _ = try queue.onTaskComplete(.{ .context = &recorder, .function = StatusRecorder.record });
    _ = try queue.addTask("concurrency-task", try json(fixture.allocator, "{\"name\":\"busy\",\"hold\":true}"), null, null);

    var await_all_returned = std.atomic.Value(bool).init(false);
    const awaiter = try std.Thread.spawn(.{}, struct {
        fn run(target: *TaskQueue, returned: *std.atomic.Value(bool)) void {
            target.awaitAllTasks() catch {};
            returned.store(true, .release);
        }
    }.run, .{ queue, &await_all_returned });

    const helper = try std.Thread.spawn(.{}, shutdownWhenWaiting, .{ queue, 1, 0 });
    var attempts: usize = 0;
    while (!await_all_returned.load(.acquire) and attempts < 3000) : (attempts += 1) {
        sleepMs(1);
    }
    try std.testing.expect(await_all_returned.load(.acquire));
    helper.join();
    awaiter.join();

    // The task kept running and finished, but its result reaches nobody: the queue unsubscribed from
    // the backend before the result arrived.
    try std.testing.expectEqual(@as(usize, 0), recorder.statuses.items.len);
}
//
// Mock queue backend for testing TaskQueue.
// Executes tasks in-process for fast, predictable tests. TypeScript runs them as promises on the
// event loop; Zig runs each task on its own thread (up to maxConcurrent at a time), so handlers may block.
// Exported from the package (task_queue_zig.mock_worker_pool) so other packages can test code that
// uses TaskQueue.
//

const std = @import("std");
const utils = @import("utils-zig");
const types = @import("../lib/types.zig");
const worker = @import("../lib/worker.zig");
const json_value = @import("../lib/json-value.zig");
const queue_backend = @import("../lib/queue-backend.zig");
const ITaskResult = types.ITaskResult;
const ITaskContext = types.ITaskContext;
const ITaskMessageData = types.ITaskMessageData;
const TaskStatus = types.TaskStatus;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskMessageCallback = types.TaskMessageCallback;
const IMessageCallbackEntry = types.IMessageCallbackEntry;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const IQueueBackend = queue_backend.IQueueBackend;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const errors = utils.errors;
const log = &utils.log.log;

//
// Thread-safe allocator for the pool's state and the tasks.
//
const pool_allocator = std.heap.smp_allocator;

//
// The parts of the task context shared by every task
// (TypeScript: Omit<ITaskContext, "sendMessage" | "isCancelled" | "taskId">).
//
pub const IBaseContext = struct {
    // Generates unique identifiers.
    uuidGenerator: IUuidGenerator,

    // Provides the current timestamp.
    timestampProvider: ITimestampProvider,

    // Unique identifier for the session the tasks belong to.
    sessionId: []const u8,
};

//
// A queued or running task (TypeScript: `{ id, type, data, source }`).
//
const IMockTask = struct {
    // Owns everything the task allocates, including the handler's allocations.
    arena: std.heap.ArenaAllocator,

    // The pool that runs the task.
    pool: *MockWorkerPool,

    // The task ID.
    id: []const u8,

    // The task type (handler name).
    type: []const u8,

    // The task data (a copy owned by the task).
    data: std.json.Value,

    // The source tag of the task.
    source: []const u8,
};

//
// A registration of a callback with the key that identifies it for unsubscribing.
//
fn Registration(comptime CallbackT: type) type {
    return struct {
        // Identifies the registration.
        key: usize,

        // The source filter (empty when the callback is not per source).
        source: []const u8,

        // The callback.
        callback: CallbackT,
    };
}

//
// Mock implementation of IQueueBackend that executes tasks in-process.
// Supports concurrency limits for testing parallel-execution scenarios.
//
pub const MockWorkerPool = struct {
    // Io for locking, waiting and running handlers.
    io: std.Io,

    // Callbacks invoked when any task completes.
    completionCallbacks: std.ArrayList(Registration(WorkerTaskCompletionCallback)),

    // Callbacks invoked for task messages of a specific type.
    messageCallbacks: std.ArrayList(Registration(IMessageCallbackEntry)),

    // Callbacks invoked for all task messages.
    anyMessageCallbacks: std.ArrayList(Registration(TaskMessageCallback)),

    // Per-source callbacks fired when a task is added.
    taskAddedCallbacks: std.ArrayList(Registration(TaskAddedCallback)),

    // Per-source callbacks fired when the tasks of a source are cancelled.
    tasksCancelledCallbacks: std.ArrayList(Registration(TasksCancelledCallback)),

    // Number of tasks currently running.
    activeTaskCount: usize,

    // Tasks waiting for a free slot, in FIFO order.
    pendingTasks: std.ArrayList(*IMockTask),

    // Maximum number of tasks that run at the same time.
    maxConcurrent: usize,

    // Sources whose tasks have been cancelled.
    cancelledSources: std.StringHashMapUnmanaged(void),

    // The context shared by every task.
    baseContext: IBaseContext,

    // Guards every field (Zig only: tasks run on threads).
    mutex: std.Io.Mutex,

    // Signalled when a task finishes (Zig only).
    condition: std.Io.Condition,

    // The threads started for tasks, joined by deinit (Zig only).
    threads: std.ArrayList(std.Thread),

    // The key of the next registration (Zig only).
    nextKey: usize,

    //
    // Creates the pool (TypeScript: constructor(maxConcurrent = 2, baseContext?); callers pass both).
    //
    pub fn init(io: std.Io, maxConcurrent: usize, baseContext: IBaseContext) !*MockWorkerPool {
        const self = try pool_allocator.create(MockWorkerPool);
        self.* = .{
            .io = io,
            .completionCallbacks = .empty,
            .messageCallbacks = .empty,
            .anyMessageCallbacks = .empty,
            .taskAddedCallbacks = .empty,
            .tasksCancelledCallbacks = .empty,
            .activeTaskCount = 0,
            .pendingTasks = .empty,
            .maxConcurrent = maxConcurrent,
            .cancelledSources = .empty,
            .baseContext = baseContext,
            .mutex = .init,
            .condition = .init,
            .threads = .empty,
            .nextKey = 0,
        };
        return self;
    }

    //
    // Waits for the queued and running tasks to finish, joins the task threads and frees the pool (Zig only).
    //
    pub fn deinit(self: *MockWorkerPool) void {
        self.lock();
        while (self.activeTaskCount > 0 or self.pendingTasks.items.len > 0) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        const threads = self.threads;
        self.threads = .empty;
        self.unlock();
        for (threads.items) |thread| {
            thread.join();
        }
        var owned_threads = threads;
        owned_threads.deinit(pool_allocator);

        self.shutdown();
        self.completionCallbacks.deinit(pool_allocator);
        self.messageCallbacks.deinit(pool_allocator);
        self.anyMessageCallbacks.deinit(pool_allocator);
        self.taskAddedCallbacks.deinit(pool_allocator);
        self.tasksCancelledCallbacks.deinit(pool_allocator);
        self.pendingTasks.deinit(pool_allocator);
        var source_iterator = self.cancelledSources.keyIterator();
        while (source_iterator.next()) |source| {
            pool_allocator.free(source.*);
        }
        self.cancelledSources.deinit(pool_allocator);
        pool_allocator.destroy(self);
    }

    //
    // Gets the IQueueBackend interface for this pool.
    //
    pub fn queueBackend(self: *MockWorkerPool) IQueueBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IQueueBackend functions of this pool.
    //
    const vtable: IQueueBackend.VTable = .{
        .addTask = addTaskErased,
        .onTaskAdded = onTaskAddedErased,
        .onTaskComplete = onTaskCompleteErased,
        .onTaskMessage = onTaskMessageErased,
        .onAnyTaskMessage = onAnyTaskMessageErased,
        .cancelTasks = cancelTasksErased,
        .onTasksCancelled = onTasksCancelledErased,
        .shutdown = shutdownErased,
    };

    //
    // Locks the pool.
    //
    fn lock(self: *MockWorkerPool) void {
        self.mutex.lockUncancelable(self.io);
    }

    //
    // Unlocks the pool.
    //
    fn unlock(self: *MockWorkerPool) void {
        self.mutex.unlock(self.io);
    }

    //
    // Queues a task. Fires the onTaskAdded callbacks of its source before the task can start.
    //
    pub fn addTask(self: *MockWorkerPool, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8) ![]const u8 {
        const id = taskId orelse try std.fmt.allocPrint(allocator, "{s}-{d}-{d}", .{ @"type", std.Io.Clock.real.now(io).toMilliseconds(), self.nextRandom(io) });

        const task = try pool_allocator.create(IMockTask);
        task.arena = std.heap.ArenaAllocator.init(pool_allocator);
        const task_allocator = task.arena.allocator();
        task.pool = self;
        task.id = try task_allocator.dupe(u8, id);
        task.type = try task_allocator.dupe(u8, @"type");
        task.data = try json_value.cloneJsonValue(task_allocator, data);
        task.source = try task_allocator.dupe(u8, source);

        self.lock();
        defer self.unlock();
        for (self.taskAddedCallbacks.items) |registration| {
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(id);
            }
        }
        try self.pendingTasks.append(pool_allocator, task);
        self.tryDispatch();
        return id;
    }

    //
    // A random number for generated task IDs (TypeScript: Math.random()).
    //
    fn nextRandom(self: *MockWorkerPool, io: std.Io) u64 {
        _ = self;
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }

    //
    // Starts pending tasks while there are free slots (the lock must be held).
    //
    fn tryDispatch(self: *MockWorkerPool) void {
        while (self.activeTaskCount < self.maxConcurrent and self.pendingTasks.items.len > 0) {
            const task = self.pendingTasks.orderedRemove(0);
            self.activeTaskCount += 1;
            const thread = std.Thread.spawn(.{}, executeTask, .{ self, task }) catch |err| {
                log.exception("Error executing task", err);
                self.activeTaskCount -= 1;
                freeTask(task);
                continue;
            };
            self.threads.append(pool_allocator, thread) catch |err| {
                log.exception("Error executing task", err);
                thread.detach();
            };
        }
    }

    //
    // Frees a task and everything it allocated.
    //
    fn freeTask(task: *IMockTask) void {
        task.arena.deinit();
        pool_allocator.destroy(task);
    }

    //
    // Runs a task on its thread and reports its completion.
    //
    fn executeTask(self: *MockWorkerPool, task: *IMockTask) void {
        const task_allocator = task.arena.allocator();
        const taskContext: ITaskContext = .{
            .uuidGenerator = self.baseContext.uuidGenerator,
            .timestampProvider = self.baseContext.timestampProvider,
            .sessionId = self.baseContext.sessionId,
            .taskId = task.id,
            .ptr = task,
            .vtable = &task_context_vtable,
        };

        var result: ITaskResult = undefined;
        if (worker.executeTaskHandler(task_allocator, self.io, task.type, task.data, taskContext)) |outputs| {
            result = .{
                .taskId = task.id,
                .type = task.type,
                .inputs = task.data,
                .status = .Succeeded,
                .outputs = outputs,
            };
        }
        else |err| {
            const is_thrown = err == error.Thrown or err == error.FatalError;
            const message = errors.errorMessage(err);
            result = .{
                .taskId = task.id,
                .type = task.type,
                .inputs = task.data,
                .status = .Failed,
                .@"error" = .{ .name = if (is_thrown) errors.lastErrorName() else "Error", .message = message },
                .errorMessage = if (message.len > 0) message else "Unknown error",
            };
        }

        self.lock();
        defer self.unlock();
        self.activeTaskCount -= 1;
        self.notifyCompletionCallbacks(result);
        freeTask(task);
        self.tryDispatch();
        self.condition.broadcast(self.io);
    }

    //
    // The ITaskContext functions of a task.
    //
    const task_context_vtable: ITaskContext.VTable = .{
        .sendMessage = taskSendMessage,
        .isCancelled = taskIsCancelled,
    };

    //
    // ITaskContext.sendMessage of a task: forwards the message to the message callbacks.
    //
    fn taskSendMessage(ptr: *anyopaque, message: std.json.Value) void {
        const task: *IMockTask = @ptrCast(@alignCast(ptr));
        const self = task.pool;
        self.lock();
        defer self.unlock();
        self.notifyMessageCallbacks(task.id, message);
    }

    //
    // ITaskContext.isCancelled of a task: true once the task's source has been cancelled.
    //
    fn taskIsCancelled(ptr: *anyopaque) bool {
        const task: *IMockTask = @ptrCast(@alignCast(ptr));
        const self = task.pool;
        self.lock();
        defer self.unlock();
        return self.cancelledSources.contains(task.source);
    }

    //
    // Registers a callback that fires when a task with the given source is added.
    //
    pub fn onTaskAdded(self: *MockWorkerPool, source: []const u8, callback: TaskAddedCallback) !UnsubscribeFn {
        return self.register(TaskAddedCallback, &self.taskAddedCallbacks, source, callback);
    }

    //
    // Registers a callback that fires when any task completes.
    //
    pub fn onTaskComplete(self: *MockWorkerPool, callback: WorkerTaskCompletionCallback) !UnsubscribeFn {
        return self.register(WorkerTaskCompletionCallback, &self.completionCallbacks, "", callback);
    }

    //
    // Registers a callback for task messages of a specific type.
    //
    pub fn onTaskMessage(self: *MockWorkerPool, messageType: []const u8, callback: TaskMessageCallback) !UnsubscribeFn {
        return self.register(IMessageCallbackEntry, &self.messageCallbacks, "", .{ .messageType = messageType, .callback = callback });
    }

    //
    // Registers a callback for all task messages.
    //
    pub fn onAnyTaskMessage(self: *MockWorkerPool, callback: TaskMessageCallback) !UnsubscribeFn {
        return self.register(TaskMessageCallback, &self.anyMessageCallbacks, "", callback);
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    pub fn onTasksCancelled(self: *MockWorkerPool, source: []const u8, callback: TasksCancelledCallback) !UnsubscribeFn {
        return self.register(TasksCancelledCallback, &self.tasksCancelledCallbacks, source, callback);
    }

    //
    // Adds a registration to a callback list and returns the function that removes it
    // (the source and the message type of an entry are expected to outlive the registration).
    //
    fn register(self: *MockWorkerPool, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), source: []const u8, callback: CallbackT) !UnsubscribeFn {
        self.lock();
        defer self.unlock();
        const key = self.nextKey;
        self.nextKey += 1;
        try list.append(pool_allocator, .{ .key = key, .source = source, .callback = callback });
        return .{ .context = self, .key = key, .function = unregister };
    }

    //
    // Removes the registration with the given key from whichever callback list holds it.
    //
    fn unregister(context: ?*anyopaque, key: usize) void {
        const self: *MockWorkerPool = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        removeKey(TaskAddedCallback, &self.taskAddedCallbacks, key);
        removeKey(WorkerTaskCompletionCallback, &self.completionCallbacks, key);
        removeKey(IMessageCallbackEntry, &self.messageCallbacks, key);
        removeKey(TaskMessageCallback, &self.anyMessageCallbacks, key);
        removeKey(TasksCancelledCallback, &self.tasksCancelledCallbacks, key);
    }

    //
    // Removes the registration with the given key from a callback list, if it is there.
    //
    fn removeKey(comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), key: usize) void {
        for (list.items, 0..) |registration, index| {
            if (registration.key == key) {
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    //
    // Marks the source as cancelled, drops its pending tasks and fires its onTasksCancelled callbacks.
    //
    pub fn cancelTasks(self: *MockWorkerPool, source: []const u8) void {
        self.lock();
        defer self.unlock();
        if (!self.cancelledSources.contains(source)) {
            const owned_source = pool_allocator.dupe(u8, source) catch |err| {
                log.exception("Failed to cancel tasks", err);
                return;
            };
            self.cancelledSources.put(pool_allocator, owned_source, {}) catch |err| {
                pool_allocator.free(owned_source);
                log.exception("Failed to cancel tasks", err);
                return;
            };
        }
        var index: usize = 0;
        while (index < self.pendingTasks.items.len) {
            const task = self.pendingTasks.items[index];
            if (std.mem.eql(u8, task.source, source)) {
                _ = self.pendingTasks.orderedRemove(index);
                freeTask(task);
                continue;
            }
            index += 1;
        }
        for (self.tasksCancelledCallbacks.items) |registration| {
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call();
            }
        }
        self.condition.broadcast(self.io);
    }

    //
    // Drops the pending tasks and every registered callback.
    //
    pub fn shutdown(self: *MockWorkerPool) void {
        self.lock();
        defer self.unlock();
        for (self.pendingTasks.items) |task| {
            freeTask(task);
        }
        self.pendingTasks.clearRetainingCapacity();
        self.completionCallbacks.clearRetainingCapacity();
        self.messageCallbacks.clearRetainingCapacity();
        self.anyMessageCallbacks.clearRetainingCapacity();
        self.taskAddedCallbacks.clearRetainingCapacity();
        self.tasksCancelledCallbacks.clearRetainingCapacity();
        self.condition.broadcast(self.io);
    }

    //
    // Invokes the completion callbacks (the lock must be held). Callback errors are logged.
    //
    fn notifyCompletionCallbacks(self: *MockWorkerPool, result: ITaskResult) void {
        for (self.completionCallbacks.items) |registration| {
            registration.callback.call(result) catch |err| {
                log.exception("Error in task completion callback", err);
            };
        }
    }

    //
    // Invokes the message callbacks that match the message type, then the callbacks for any message
    // (the lock must be held). Callback errors are logged.
    //
    fn notifyMessageCallbacks(self: *MockWorkerPool, taskId: []const u8, message: std.json.Value) void {
        const messageType = types.messageTypeOf(message);
        const data: ITaskMessageData = .{ .taskId = taskId, .message = message };

        for (self.messageCallbacks.items) |registration| {
            if (messageType == null or !std.mem.eql(u8, messageType.?, registration.callback.messageType)) {
                continue;
            }
            registration.callback.callback.call(data) catch |err| {
                log.exception("Error in task message callback", err);
            };
        }

        for (self.anyMessageCallbacks.items) |registration| {
            registration.callback.call(data) catch |err| {
                log.exception("Error in any task message callback", err);
            };
        }
    }

    //
    // IQueueBackend.addTask for this implementation.
    //
    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8) anyerror![]const u8 {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        return self.addTask(allocator, io, @"type", data, source, taskId);
    }

    //
    // IQueueBackend.onTaskAdded for this implementation.
    //
    fn onTaskAddedErased(ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        return self.onTaskAdded(source, callback);
    }

    //
    // IQueueBackend.onTaskComplete for this implementation.
    //
    fn onTaskCompleteErased(ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        return self.onTaskComplete(callback);
    }

    //
    // IQueueBackend.onTaskMessage for this implementation.
    //
    fn onTaskMessageErased(ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        return self.onTaskMessage(messageType, callback);
    }

    //
    // IQueueBackend.onAnyTaskMessage for this implementation.
    //
    fn onAnyTaskMessageErased(ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        return self.onAnyTaskMessage(callback);
    }

    //
    // IQueueBackend.cancelTasks for this implementation.
    //
    fn cancelTasksErased(ptr: *anyopaque, source: []const u8) void {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        self.cancelTasks(source);
    }

    //
    // IQueueBackend.onTasksCancelled for this implementation.
    //
    fn onTasksCancelledErased(ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        return self.onTasksCancelled(source, callback);
    }

    //
    // IQueueBackend.shutdown for this implementation.
    //
    fn shutdownErased(ptr: *anyopaque) void {
        const self: *MockWorkerPool = @ptrCast(@alignCast(ptr));
        self.shutdown();
    }
};

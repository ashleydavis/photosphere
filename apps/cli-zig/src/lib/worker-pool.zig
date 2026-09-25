//
// Port of worker-pool-bun.ts (WorkerPoolBun) and worker.ts (the worker script).
// TypeScript runs each worker as a Bun Worker and talks to it with messages. Zig runs each worker as a
// std.Thread of the CLI process: a dispatched task is handed to the worker thread, which runs the handler
// registered with task-queue-zig (worker.registerHandler) with an arena allocator owned by the task, and
// reports the completion itself (under the pool lock, where TypeScript handles the "task-completed" message).
//
// Differences that follow from threads:
// - A timed-out task's thread cannot be killed: the task is marked abandoned, the thread is detached and its
//   result discarded (it frees the task when the handler returns), and a replacement worker is created.
// - A handler error is a task failure, as in TypeScript. There is no equivalent of a worker crashing
//   (a panic ends the process); handleWorkerCrash is used when a worker thread cannot be started.
// - Workers share the main thread's queue backend (WorkerQueueBackend is not ported), so a handler that
//   queues child tasks adds them to this pool directly.
//   So the "queue-task" message (IWorkerQueueTaskMessage, with its priority) and priorityOfRunningTask,
//   which give a child task its parent's priority, are not ported.
// - Callbacks are invoked on the thread that completes the task (a worker thread or the timeout monitor)
//   while the pool lock is held (see the threading contract in task-queue-zig queue-backend.zig).
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const worker_log_bun = @import("worker-log-bun.zig");
const initTaskHandlers = node_api.task_handlers.initTaskHandlers;
const types = task_queue.types;
const json_value = task_queue.json_value;
const worker = task_queue.worker;
const ITask = types.ITask;
const ITaskResult = types.ITaskResult;
const ITaskError = types.ITaskError;
const ITaskMessageData = types.ITaskMessageData;
const TaskStatus = types.TaskStatus;
const TaskPriority = types.TaskPriority;
const insertTaskByPriority = task_queue.pending_task_queue.insertTaskByPriority;
const resolveTaskPriority = task_queue.pending_task_queue.resolveTaskPriority;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskMessageCallback = types.TaskMessageCallback;
const IMessageCallbackEntry = types.IMessageCallbackEntry;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const IQueueBackend = task_queue.queue_backend.IQueueBackend;
const TaskContext = task_queue.task_context.TaskContext;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const TimestampProvider = utils.timestamp_provider.TimestampProvider;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const errors = utils.errors;
const log = &utils.log.log;

//
// How many child tasks one task may have running at once here (worker.ts).
//
// Ten, because a desktop machine has cores and a fast disk to spare, and whatever queued the work is
// usually what the user is waiting on. It is not the size of the worker pool: it is how much of that
// pool one task may fill, so a second import, a sync, or anything the user does still gets a worker.
//
const MAX_CONCURRENT_CHILD_TASKS = 10;

//
// Thread-safe allocator for the pool's state and the tasks.
//
const pool_allocator = std.heap.smp_allocator;

//
// Options passed to workers for context initialization
//
pub const IWorkerOptions = struct {
    // Unique numeric identifier assigned to this worker.
    workerId: u32,

    // Whether verbose logging is enabled.
    verbose: ?bool = null,

    // Whether tool output logging is enabled.
    tools: ?bool = null,

    // Session identifier forwarded to task handlers.
    sessionId: ?[]const u8 = null,
};

//
// Options passed to workers for context initialization (does not include workerId, which is assigned per worker)
//
pub const IWorkerPoolOptions = struct {
    // Enable verbose logging in worker threads.
    verbose: ?bool = null,

    // Enable tool support in worker threads.
    tools: ?bool = null,

    // Session identifier forwarded to workers for context initialization.
    sessionId: ?[]const u8 = null,
};

//
// A task owned by the pool (TypeScript: ITask plus the Zig-only state of its execution).
//
const IPoolTask = struct {
    // Owns everything the task allocates, including the handler's allocations.
    arena: std.heap.ArenaAllocator,

    // The task (its strings and data are allocated in the arena).
    task: ITask,

    // When the task times out (milliseconds on the awake clock), or null while it is not running.
    deadline: ?i64,

    // Set when the task timed out or its worker was terminated: the worker thread discards the result
    // and frees the task.
    abandoned: bool,

    // The context of the running task.
    context: TaskContext,

    // The pool that runs the task.
    pool: *WorkerPoolBun,
};

//
// Worker state interface
//
const IWorkerState = struct {
    // The thread of the worker (TypeScript: the Bun Worker), null until it has been started.
    thread: ?std.Thread,

    // Unique numeric identifier assigned to this worker for logging and options.
    workerId: u32,

    // Worker has started and can process tasks (TypeScript: sent its "ready" message).
    isReady: bool,

    // Worker is ready and not currently processing a task.
    isIdle: bool,

    // ID of the task currently being processed, or null if idle.
    currentTaskId: ?[]const u8,

    // Type of the task currently being processed, or null if idle.
    currentTaskType: ?[]const u8,

    // Elapsed milliseconds for the current task, updated on status polls, or null if idle.
    currentTaskRunningTimeMs: ?i64,

    // Number of tasks this worker has completed (successful or failed).
    tasksProcessed: u64,

    // Timestamp (milliseconds) when the current task started, or null if idle.
    taskStartTime: ?i64,

    // The task handed to the worker thread and not yet picked up (TypeScript: the "execute" message).
    assignedTask: ?*IPoolTask,

    // The task the worker thread is running.
    currentTask: ?*IPoolTask,

    // Set when the worker is terminated (TypeScript: worker.terminate()); the thread exits when it sees it.
    terminated: bool,

    // The options of the worker.
    options: IWorkerOptions,
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
// Converts a JavaScript number to its string form for integral values (`${number}`).
//
fn formatNumber(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    if (value == @floor(value) and @abs(value) < 1e21) {
        return std.fmt.allocPrint(allocator, "{d}", .{@as(i128, @intFromFloat(value))});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

//
// The delay setTimeout uses for a requested delay: values that are not between 1 and 2147483647
// (including NaN) become 1.
//
fn setTimeoutDelay(delay: f64) i64 {
    if (!(delay >= 1 and delay <= 2147483647)) {
        return 1;
    }
    return @intFromFloat(@floor(delay));
}

//
// Manages workers.
//
pub const WorkerPoolBun = struct {
    // Io for locking, waiting and running handlers.
    io: std.Io,

    // All currently allocated workers.
    workers: std.ArrayList(*IWorkerState),

    // Workers that have been removed from the pool but may still have a running thread (Zig only).
    retiredWorkers: std.ArrayList(*IWorkerState),

    // Maximum number of worker threads allowed (a JavaScript number: NaN never allows a worker).
    maxWorkers: f64,

    // Options forwarded to each worker for logging and session initialization.
    workerOptions: IWorkerPoolOptions,

    // Milliseconds before a running task is considered timed out (as given; see setTimeoutDelay).
    taskTimeout: f64,

    // Callbacks notified when any task completes (success or failure).
    completionCallbacks: std.ArrayList(Registration(WorkerTaskCompletionCallback)),

    // Callbacks notified for task messages of a specific type.
    messageCallbacks: std.ArrayList(Registration(IMessageCallbackEntry)),

    // Callbacks notified for every task message regardless of type.
    anyMessageCallbacks: std.ArrayList(Registration(TaskMessageCallback)),

    // Tasks waiting to be dispatched to a worker.
    pendingTasks: std.ArrayList(*IPoolTask),

    // Callbacks registered per source via onTaskAdded.
    taskAddedCallbacks: std.ArrayList(Registration(TaskAddedCallback)),

    // Callbacks registered per source via onTasksCancelled.
    tasksCancelledCallbacks: std.ArrayList(Registration(TasksCancelledCallback)),

    // Guards every field (Zig only).
    mutex: std.Io.Mutex,

    // Signalled when a task is assigned to a worker or a worker is terminated (Zig only).
    workCondition: std.Io.Condition,

    // Signalled when a task starts running or the pool shuts down, to wake the timeout monitor (Zig only).
    monitorCondition: std.Io.Condition,

    // The thread that enforces the task timeouts (TypeScript: setTimeout), started with the first worker.
    monitorThread: ?std.Thread,

    // Set by deinit to stop the timeout monitor (Zig only).
    stopping: bool,

    // Number of worker threads that are still running (Zig only; deinit waits for them).
    runningThreads: usize,

    // The key of the next registration (Zig only).
    nextKey: usize,

    // Generates task IDs (TypeScript: randomUUID()).
    randomUuidGenerator: RandomUuidGenerator,

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate worker threads for true parallelism.
    // taskTimeout: Timeout in milliseconds for tasks.
    // workerOptions: Options to pass to workers for logging and context initialization.
    // The pool is allocated with a thread-safe allocator; deinit frees it (the CLI keeps it until exit).
    //
    pub fn init(io: std.Io, maxWorkers: f64, taskTimeout: f64, workerOptions: IWorkerPoolOptions) !*WorkerPoolBun {
        const self = try pool_allocator.create(WorkerPoolBun);
        self.* = .{
            .io = io,
            .workers = .empty,
            .retiredWorkers = .empty,
            .maxWorkers = maxWorkers,
            .workerOptions = workerOptions,
            .taskTimeout = taskTimeout,
            .completionCallbacks = .empty,
            .messageCallbacks = .empty,
            .anyMessageCallbacks = .empty,
            .pendingTasks = .empty,
            .taskAddedCallbacks = .empty,
            .tasksCancelledCallbacks = .empty,
            .mutex = .init,
            .workCondition = .init,
            .monitorCondition = .init,
            .monitorThread = null,
            .stopping = false,
            .runningThreads = 0,
            .nextKey = 0,
            .randomUuidGenerator = .{},
        };
        try initTaskHandlers();
        worker_log_bun.installWorkerLogRouting();
        return self;
    }

    //
    // Shuts the pool down, waits for every worker thread (including abandoned ones) to end and frees the
    // pool (Zig only; used by tests).
    //
    pub fn deinit(self: *WorkerPoolBun) void {
        self.shutdown();

        self.lock();
        self.stopping = true;
        self.monitorCondition.broadcast(self.io);
        self.workCondition.broadcast(self.io);
        const monitor = self.monitorThread;
        self.monitorThread = null;
        self.unlock();
        if (monitor) |thread| {
            thread.join();
        }

        self.lock();
        while (self.runningThreads > 0) {
            self.workCondition.waitUncancelable(self.io, &self.mutex);
        }
        self.unlock();

        for (self.retiredWorkers.items) |workerState| {
            pool_allocator.destroy(workerState);
        }
        self.retiredWorkers.deinit(pool_allocator);
        self.workers.deinit(pool_allocator);
        self.completionCallbacks.deinit(pool_allocator);
        self.messageCallbacks.deinit(pool_allocator);
        self.anyMessageCallbacks.deinit(pool_allocator);
        self.pendingTasks.deinit(pool_allocator);
        self.taskAddedCallbacks.deinit(pool_allocator);
        self.tasksCancelledCallbacks.deinit(pool_allocator);
        pool_allocator.destroy(self);
    }

    //
    // Gets the IQueueBackend interface for this pool.
    //
    pub fn queueBackend(self: *WorkerPoolBun) IQueueBackend {
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
    fn lock(self: *WorkerPoolBun) void {
        self.mutex.lockUncancelable(self.io);
    }

    //
    // Unlocks the pool.
    //
    fn unlock(self: *WorkerPoolBun) void {
        self.mutex.unlock(self.io);
    }

    //
    // The current time on the monotonic clock in milliseconds (Zig only: task deadlines).
    //
    fn nowMs(self: *WorkerPoolBun) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    //
    // Adds a task to the pending queue and attempts to dispatch it immediately.
    //
    // An interactive task goes in ahead of every background task already waiting, because the user
    // is sitting there looking at it.
    //
    pub fn addTask(self: *WorkerPoolBun, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) ![]const u8 {
        return self.addTaskWithParent(allocator, io, @"type", data, source, taskId, priority, null);
    }

    //
    // Adds a task that a running task asked for, so it runs at that task's priority unless it asked
    // for one of its own. This is what stops an import's hash and upload children overtaking a tap.
    // (Zig: workers share this pool as their queue backend, so a task queued from a worker thread arrives
    // through addTask, and no handler on the psi replicate or psi verify path queues child tasks.)
    //
    fn addTaskWithParent(self: *WorkerPoolBun, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority, parentPriority: ?TaskPriority) ![]const u8 {
        const id = taskId orelse try self.randomUuidGenerator.generate(allocator, io);

        const poolTask = try pool_allocator.create(IPoolTask);
        poolTask.arena = std.heap.ArenaAllocator.init(pool_allocator);
        const task_allocator = poolTask.arena.allocator();
        poolTask.task = .{
            .id = try task_allocator.dupe(u8, id),
            .type = try task_allocator.dupe(u8, @"type"),
            .status = .Pending,
            .data = try json_value.cloneJsonValue(task_allocator, data),
            .source = try task_allocator.dupe(u8, source),
            .priority = resolveTaskPriority(priority, parentPriority),
            .createdAt = std.Io.Clock.real.now(io).toMilliseconds(),
        };
        poolTask.deadline = null;
        poolTask.abandoned = false;
        poolTask.pool = self;

        self.lock();
        defer self.unlock();
        try insertTaskByPriority(pool_allocator, &self.pendingTasks, poolTask);

        for (self.taskAddedCallbacks.items) |registration| {
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(id);
            }
        }

        self.tryDispatchPending();
        return id;
    }

    //
    // Registers a callback that fires when a task with the given source is added.
    //
    pub fn onTaskAdded(self: *WorkerPoolBun, source: []const u8, callback: TaskAddedCallback) !UnsubscribeFn {
        return self.register(TaskAddedCallback, &self.taskAddedCallbacks, source, callback);
    }

    //
    // Tries to dispatch all pending tasks to available workers (the lock must be held).
    //
    fn tryDispatchPending(self: *WorkerPoolBun) void {
        while (self.pendingTasks.items.len > 0) {
            const poolTask = self.pendingTasks.items[0];
            if (!self.dispatchTask(poolTask)) {
                break;
            }
            _ = self.pendingTasks.orderedRemove(0);
        }
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    pub fn onTaskComplete(self: *WorkerPoolBun, callback: WorkerTaskCompletionCallback) !UnsubscribeFn {
        return self.register(WorkerTaskCompletionCallback, &self.completionCallbacks, "", callback);
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    pub fn onTaskMessage(self: *WorkerPoolBun, messageType: []const u8, callback: TaskMessageCallback) !UnsubscribeFn {
        return self.register(IMessageCallbackEntry, &self.messageCallbacks, "", .{ .messageType = messageType, .callback = callback });
    }

    //
    // Registers a callback that will be called for any task message, regardless of type.
    //
    pub fn onAnyTaskMessage(self: *WorkerPoolBun, callback: TaskMessageCallback) !UnsubscribeFn {
        return self.register(TaskMessageCallback, &self.anyMessageCallbacks, "", callback);
    }

    //
    // Adds a registration to a callback list and returns the function that removes it.
    //
    fn register(self: *WorkerPoolBun, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), source: []const u8, callback: CallbackT) !UnsubscribeFn {
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
        const self: *WorkerPoolBun = @ptrCast(@alignCast(context.?));
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
    // Invokes all registered completion callbacks with the task result (the lock must be held).
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyCompletionCallbacks(self: *WorkerPoolBun, result: ITaskResult) void {
        for (self.completionCallbacks.items) |registration| {
            registration.callback.call(result) catch |err| {
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", err);
            };
        }
    }

    //
    // Invokes all registered message callbacks with the task message (the lock must be held).
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyMessageCallbacks(self: *WorkerPoolBun, taskId: []const u8, message: std.json.Value) void {
        const messageType = types.messageTypeOf(message);
        const data: ITaskMessageData = .{ .taskId = taskId, .message = message };

        // Notify callbacks registered for specific message types
        for (self.messageCallbacks.items) |registration| {
            if (messageType == null or !std.mem.eql(u8, messageType.?, registration.callback.messageType)) {
                continue;
            }

            registration.callback.callback.call(data) catch |err| {
                // Don't let callback errors break the task queue
                log.exception("Error in task message callback", err);
            };
        }

        // Notify callbacks registered for any message type
        for (self.anyMessageCallbacks.items) |registration| {
            registration.callback.call(data) catch |err| {
                // Don't let callback errors break the task queue
                log.exception("Error in any task message callback", err);
            };
        }
    }

    //
    // Creates a worker state and starts its thread (the lock must be held).
    // A worker that cannot be started is handled like a crashed worker.
    //
    fn startWorker(self: *WorkerPoolBun, workerId: u32, tasksProcessed: u64) *IWorkerState {
        const workerState = pool_allocator.create(IWorkerState) catch @panic("out of memory");
        workerState.* = .{
            .thread = null,
            .workerId = workerId,
            .isReady = false, // Will be set to true when the worker thread starts
            .isIdle = false, // Will be set to true when worker is ready and idle
            .currentTaskId = null,
            .currentTaskType = null,
            .currentTaskRunningTimeMs = null,
            .tasksProcessed = tasksProcessed,
            .taskStartTime = null,
            .assignedTask = null,
            .currentTask = null,
            .terminated = false,
            .options = .{
                .workerId = workerId,
                .verbose = self.workerOptions.verbose,
                .tools = self.workerOptions.tools,
                .sessionId = self.workerOptions.sessionId,
            },
        };
        self.workers.append(pool_allocator, workerState) catch @panic("out of memory");
        self.ensureMonitor();

        const thread = std.Thread.spawn(.{}, workerMain, .{ self, workerState }) catch |err| {
            var message_buffer: [64]u8 = undefined;
            log.exception(std.fmt.bufPrint(&message_buffer, "Error from worker {d}", .{workerId}) catch "Error from worker", err);
            workerState.terminated = true;
            return workerState;
        };
        workerState.thread = thread;
        self.runningThreads += 1;
        return workerState;
    }

    //
    // Creates a single worker and adds it to the pool (the lock must be held).
    // Returns the worker state.
    //
    fn createWorker(self: *WorkerPoolBun) *IWorkerState {
        const workerId: u32 = @intCast(self.workers.items.len + 1);
        return self.startWorker(workerId, 0);
    }

    //
    // Replaces a worker with a new one (the lock must be held).
    //
    fn replaceWorker(self: *WorkerPoolBun, oldWorkerState: *IWorkerState) void {
        // Remove from workers array
        for (self.workers.items, 0..) |workerState, index| {
            if (workerState == oldWorkerState) {
                _ = self.workers.orderedRemove(index);
                break;
            }
        }
        self.retireWorker(oldWorkerState);

        // Preserve task count when replacing worker
        _ = self.startWorker(oldWorkerState.workerId, oldWorkerState.tasksProcessed);
    }

    //
    // Terminates a worker: its thread exits when idle, or discards its running task's result (Zig only).
    // The state is kept until deinit because the thread may still use it.
    //
    fn retireWorker(self: *WorkerPoolBun, workerState: *IWorkerState) void {
        workerState.terminated = true;
        if (workerState.thread) |thread| {
            thread.detach();
            workerState.thread = null;
        }
        self.retiredWorkers.append(pool_allocator, workerState) catch {};
        self.workCondition.broadcast(self.io);
    }

    //
    // Starts the timeout monitor thread if it is not running (the lock must be held).
    //
    fn ensureMonitor(self: *WorkerPoolBun) void {
        if (self.monitorThread != null) {
            return;
        }
        self.monitorThread = std.Thread.spawn(.{}, monitorMain, .{self}) catch |err| {
            log.exception("Error starting the task timeout monitor", err);
            return;
        };
    }

    //
    // The body of a worker thread (TypeScript: worker.ts).
    //
    fn workerMain(self: *WorkerPoolBun, workerState: *IWorkerState) void {
        var workerLog = worker_log_bun.WorkerLogBun.init(workerState.workerId, workerState.options.verbose orelse false, workerState.options.tools orelse false);
        worker_log_bun.createWorkerLog(&workerLog);
        defer worker_log_bun.clearWorkerLog();

        var context_arena = std.heap.ArenaAllocator.init(pool_allocator);
        defer context_arena.deinit();
        const context_allocator = context_arena.allocator();

        // Test providers are automatically configured when NODE_ENV === "testing"
        const isTesting = std.mem.eql(u8, node_utils.process_env.getEnv("NODE_ENV") orelse "", "testing");
        var testUuidGenerator: ?TestUuidGenerator = if (isTesting) TestUuidGenerator.init(context_allocator) catch null else null;
        var randomUuidGenerator = RandomUuidGenerator{};
        var testTimestampProvider = TestTimestampProvider{};
        var timestampProviderImpl = TimestampProvider{};
        const uuidGenerator: IUuidGenerator = if (testUuidGenerator) |*generator| generator.uuidGenerator() else randomUuidGenerator.uuidGenerator();
        const timestampProvider: ITimestampProvider = if (isTesting) testTimestampProvider.timestampProvider() else timestampProviderImpl.timestampProvider();
        const sessionId = workerState.options.sessionId orelse (uuidGenerator.generate(context_allocator, self.io) catch "");

        self.lock();
        defer {
            self.runningThreads -= 1;
            self.workCondition.broadcast(self.io);
            self.unlock();
        }

        // The worker is ready (TypeScript: the "worker-ready" message).
        if (workerState.terminated) {
            return;
        }
        workerState.isReady = true;
        workerState.isIdle = true;
        self.tryDispatchPending();

        while (true) {
            while (workerState.assignedTask == null and !workerState.terminated) {
                self.workCondition.waitUncancelable(self.io, &self.mutex);
            }
            const poolTask = workerState.assignedTask orelse return;
            workerState.assignedTask = null;
            workerState.currentTask = poolTask;
            poolTask.context = TaskContext.init(uuidGenerator, timestampProvider, sessionId, poolTask.task.id, .{ .context = poolTask, .function = sendMessageFn }, MAX_CONCURRENT_CHILD_TASKS);
            self.unlock();

            const outputs = self.executeTask(poolTask);

            self.lock();
            workerState.currentTask = null;
            if (poolTask.abandoned or workerState.terminated) {
                // The task timed out or the worker was terminated: the result is discarded.
                freeTask(poolTask);
                return;
            }
            self.handleTaskCompleted(workerState, poolTask, outputs);
        }
    }

    //
    // Executes a task handler on the worker thread (TypeScript: executeTask in worker.ts).
    // Returns the handler outputs, or the failure.
    //
    fn executeTask(self: *WorkerPoolBun, poolTask: *IPoolTask) TaskOutcome {
        const task = poolTask.task;

        // Set task ID for logging prefix and progress messages
        worker_log_bun.setWorkerTaskId(task.id);
        defer worker_log_bun.setWorkerTaskId(null);

        // Execute the handler with task-specific context
        if (worker.executeTaskHandler(poolTask.arena.allocator(), self.io, task.type, task.data, poolTask.context.taskContext())) |outputs| {
            return .{ .succeeded = outputs };
        }
        else |err| {
            const is_thrown = err == error.Thrown or err == error.FatalError;
            const message = poolTask.arena.allocator().dupe(u8, errors.errorMessage(err)) catch "";
            const name = poolTask.arena.allocator().dupe(u8, if (is_thrown) errors.lastErrorName() else "Error") catch "Error";
            if (log.verboseEnabled()) {
                const detail = std.fmt.allocPrint(poolTask.arena.allocator(), "Task {s} failed with error {{\n  \"name\": \"{s}\",\n  \"message\": \"{s}\"\n}}", .{ task.id, name, message }) catch "";
                log.verbose(detail);
            }
            return .{ .failed = .{ .name = name, .message = message } };
        }
    }

    //
    // The outcome of running a task handler (Zig only).
    //
    const TaskOutcome = union(enum) {
        // The handler returned these outputs.
        succeeded: std.json.Value,

        // The handler failed with this error.
        failed: ITaskError,
    };

    //
    // Handles the completion of a task (TypeScript: the "task-completed" message; the lock must be held).
    //
    fn handleTaskCompleted(self: *WorkerPoolBun, workerState: *IWorkerState, poolTask: *IPoolTask, outcome: TaskOutcome) void {
        // Clear timeout since task completed
        poolTask.deadline = null;

        const task = poolTask.task;

        // Build result object
        const fullResult: ITaskResult = switch (outcome) {
            .succeeded => |outputs| .{
                .taskId = task.id,
                .status = .Succeeded,
                .@"error" = null,
                .errorMessage = "Unknown error",
                .outputs = outputs,
                .type = task.type,
                .inputs = task.data,
            },
            .failed => |failure| .{
                .taskId = task.id,
                .status = .Failed,
                .@"error" = failure,
                .errorMessage = if (failure.message.len > 0) failure.message else "Unknown error",
                .outputs = null,
                .type = task.type,
                .inputs = task.data,
            },
        };

        // Update worker state
        workerState.isIdle = true;
        workerState.currentTaskId = null;
        workerState.currentTaskType = null;
        workerState.currentTaskRunningTimeMs = null;
        workerState.taskStartTime = null;
        workerState.tasksProcessed += 1;

        self.notifyCompletionCallbacks(fullResult);
        freeTask(poolTask);

        // Not ported: broadcasting the completion to the workers (for WorkerQueueBackend, not ported).

        self.tryDispatchPending();
    }

    //
    // Sends a message from the current task back to the caller (TypeScript: sendMessageFn in worker.ts
    // and the "task-message" handling in the pool).
    //
    fn sendMessageFn(context: ?*anyopaque, message: std.json.Value) void {
        const poolTask: *IPoolTask = @ptrCast(@alignCast(context.?));
        const self = poolTask.pool;
        self.lock();
        defer self.unlock();
        if (poolTask.abandoned) {
            return;
        }
        self.notifyMessageCallbacks(poolTask.task.id, message);
    }

    //
    // The body of the timeout monitor thread (TypeScript: the setTimeout callbacks).
    //
    fn monitorMain(self: *WorkerPoolBun) void {
        self.lock();
        defer self.unlock();
        while (!self.stopping) {
            var earliest: ?i64 = null;
            for (self.workers.items) |workerState| {
                const poolTask = workerState.currentTask orelse workerState.assignedTask orelse continue;
                const deadline = poolTask.deadline orelse continue;
                if (earliest == null or deadline < earliest.?) {
                    earliest = deadline;
                }
            }
            if (earliest == null) {
                self.monitorCondition.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            const now = self.nowMs();
            if (earliest.? > now) {
                const wait_ms = @min(earliest.? - now, 50);
                self.unlock();
                self.io.sleep(.fromMilliseconds(wait_ms), .awake) catch {};
                self.lock();
                continue;
            }

            // Find a timed out task and handle it.
            for (self.workers.items) |workerState| {
                const poolTask = workerState.currentTask orelse workerState.assignedTask orelse continue;
                const deadline = poolTask.deadline orelse continue;
                if (deadline <= now) {
                    self.handleTaskTimeout(poolTask, workerState);
                    break;
                }
            }
        }
    }

    //
    // Handles task timeout by terminating the worker and marking the task as failed (the lock must be held).
    //
    fn handleTaskTimeout(self: *WorkerPoolBun, poolTask: *IPoolTask, workerState: *IWorkerState) void {
        // Clear the timeout (should already be cleared, but be safe)
        poolTask.deadline = null;

        var buffer: [256]u8 = undefined;
        var fixed_allocator = std.heap.FixedBufferAllocator.init(&buffer);
        const timeoutText = formatNumber(fixed_allocator.allocator(), self.taskTimeout) catch "";
        var message_buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "[Task Queue] Task {s} timed out after {s}ms", .{ poolTask.task.id, timeoutText }) catch "[Task Queue] Task timed out";
        log.@"error"(message);

        // Terminate the worker: the thread cannot be killed, so its task is abandoned and the thread detached.
        poolTask.abandoned = true;
        if (workerState.currentTask == poolTask) {
            poolTask.context.cancel();
        }
        if (workerState.assignedTask == poolTask) {
            // The thread has not picked the task up yet: it is freed here.
            workerState.assignedTask = null;
        }

        const task = poolTask.task;
        const result: ITaskResult = .{
            .taskId = task.id,
            .status = .Failed,
            .@"error" = .{ .name = "Error", .message = "Task timeout" },
            .errorMessage = "Task timeout",
            .outputs = null,
            .type = task.type,
            .inputs = task.data,
        };

        workerState.isIdle = true;
        workerState.currentTaskId = null;
        workerState.currentTaskType = null;
        workerState.currentTaskRunningTimeMs = null;
        workerState.taskStartTime = null;

        self.notifyCompletionCallbacks(result);
        if (workerState.currentTask != poolTask) {
            freeTask(poolTask);
        }

        // Replace the worker
        self.replaceWorker(workerState);
        self.tryDispatchPending();
    }

    //
    // Handles worker crashes by terminating the worker and creating a replacement (the lock must be held).
    // If the worker had a task, it is reported as failed.
    //
    fn handleWorkerCrash(self: *WorkerPoolBun, workerState: *IWorkerState) void {
        const crashedTask = workerState.currentTask orelse workerState.assignedTask;

        // If worker had a task, clear its timeout and mark as failed
        if (crashedTask) |poolTask| {
            poolTask.deadline = null;
            poolTask.abandoned = true;
            const task = poolTask.task;
            const result: ITaskResult = .{
                .taskId = task.id,
                .status = .Failed,
                .@"error" = .{ .name = "Error", .message = "Worker crashed" },
                .errorMessage = "Worker crashed",
                .outputs = null,
                .type = task.type,
                .inputs = task.data,
            };

            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            self.notifyCompletionCallbacks(result);
            if (workerState.assignedTask == poolTask) {
                workerState.assignedTask = null;
                freeTask(poolTask);
            }
        }

        // Replace the worker
        self.replaceWorker(workerState);
    }

    //
    // Dispatches a single task to an available worker (the lock must be held).
    // Returns true if the task was dispatched, false if no worker was available.
    //
    fn dispatchTask(self: *WorkerPoolBun, poolTask: *IPoolTask) bool {

        //
        // Find an available idle worker that has processed the least tasks
        //
        var availableWorker: ?*IWorkerState = null;
        for (self.workers.items) |workerState| {
            if (!workerState.isIdle) {
                continue;
            }
            if (availableWorker == null or workerState.tasksProcessed < availableWorker.?.tasksProcessed) {
                availableWorker = workerState;
            }
        }

        //
        // If no idle worker available and we haven't reached maxWorkers, create workers for pending tasks
        //
        if (availableWorker == null and @as(f64, @floatFromInt(self.workers.items.len)) < self.maxWorkers) {
            // Create one worker (TypeScript: workersNeeded = 1, up to the maxWorkers limit)
            const workerState = self.createWorker();
            if (workerState.terminated) {
                self.handleWorkerCrash(workerState);
            }

            // Workers won't be idle until their threads start, so return for now
            return false;
        }

        const selectedWorker = availableWorker orelse return false; // All workers busy or not ready yet

        selectedWorker.isIdle = false;
        selectedWorker.currentTaskId = poolTask.task.id;
        selectedWorker.currentTaskType = poolTask.task.type;
        selectedWorker.taskStartTime = std.Io.Clock.real.now(self.io).toMilliseconds();

        // Set up timeout for this task
        poolTask.deadline = self.nowMs() + setTimeoutDelay(self.taskTimeout);
        self.monitorCondition.broadcast(self.io);

        // Send task to worker
        selectedWorker.assignedTask = poolTask;
        self.workCondition.broadcast(self.io);

        return true;
    }

    //
    // Frees a task and everything it allocated.
    //
    fn freeTask(poolTask: *IPoolTask) void {
        poolTask.arena.deinit();
        pool_allocator.destroy(poolTask);
    }

    //
    // Drops pending tasks with the given source and signals running tasks to cancel.
    //
    pub fn cancelTasks(self: *WorkerPoolBun, source: []const u8) void {
        self.lock();
        defer self.unlock();
        var index: usize = 0;
        while (index < self.pendingTasks.items.len) {
            const poolTask = self.pendingTasks.items[index];
            if (std.mem.eql(u8, poolTask.task.source, source)) {
                _ = self.pendingTasks.orderedRemove(index);
                freeTask(poolTask);
                continue;
            }
            index += 1;
        }

        // Signal running tasks with the source to cancel (TypeScript: the "cancel-tasks" message).
        for (self.workers.items) |workerState| {
            if (workerState.currentTask) |poolTask| {
                if (std.mem.eql(u8, poolTask.task.source, source)) {
                    poolTask.context.cancel();
                }
            }
        }

        for (self.tasksCancelledCallbacks.items) |registration| {
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call();
            }
        }
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    pub fn onTasksCancelled(self: *WorkerPoolBun, source: []const u8, callback: TasksCancelledCallback) !UnsubscribeFn {
        return self.register(TasksCancelledCallback, &self.tasksCancelledCallbacks, source, callback);
    }

    //
    // Shuts down all the workers.
    //
    pub fn shutdown(self: *WorkerPoolBun) void {
        self.lock();
        defer self.unlock();

        // Clear all timeouts first to prevent any timeout callbacks from running
        for (self.workers.items) |workerState| {
            if (workerState.currentTask) |poolTask| {
                poolTask.deadline = null;
            }
            if (workerState.assignedTask) |poolTask| {
                workerState.assignedTask = null;
                freeTask(poolTask);
            }
        }

        for (self.workers.items) |workerState| {
            self.retireWorker(workerState);
        }
        self.workers.clearRetainingCapacity();
    }

    //
    // IQueueBackend.addTask for this implementation.
    //
    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.addTask(allocator, io, @"type", data, source, taskId, priority);
    }

    //
    // IQueueBackend.onTaskAdded for this implementation.
    //
    fn onTaskAddedErased(ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTaskAdded(source, callback);
    }

    //
    // IQueueBackend.onTaskComplete for this implementation.
    //
    fn onTaskCompleteErased(ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTaskComplete(callback);
    }

    //
    // IQueueBackend.onTaskMessage for this implementation.
    //
    fn onTaskMessageErased(ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTaskMessage(messageType, callback);
    }

    //
    // IQueueBackend.onAnyTaskMessage for this implementation.
    //
    fn onAnyTaskMessageErased(ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onAnyTaskMessage(callback);
    }

    //
    // IQueueBackend.cancelTasks for this implementation.
    //
    fn cancelTasksErased(ptr: *anyopaque, source: []const u8) void {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        self.cancelTasks(source);
    }

    //
    // IQueueBackend.onTasksCancelled for this implementation.
    //
    fn onTasksCancelledErased(ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTasksCancelled(source, callback);
    }

    //
    // IQueueBackend.shutdown for this implementation.
    //
    fn shutdownErased(ptr: *anyopaque) void {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        self.shutdown();
    }
};

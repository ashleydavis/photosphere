//
// The worker pool of the CLI, a port of the TypeScript CLI's WorkerPoolBun. The CLI's main thread owns the pool and
// everything in it. Each worker is one of Ziggy's workers: a thread that runs one task at a time and talks to the main thread only by
// message, as a Bun worker does. The main thread reads the workers' messages while its own code waits for a task (the IQueueBackend's
// waitForMessage), and fails the tasks that have run past their timeout while it waits, so the pool needs no lock.
//
// The pool keeps no Io, allocator or timers: each function is given the main thread's, and the allocator must be the same one on every
// call, because what the pool keeps is allocated with it. A task's timeout is the time it started plus the pool's timeout, which each
// wait looks at, rather than a timer of the pool's own.
//
// What a thread cannot do that a Bun worker can:
// - A thread cannot be stopped from outside it. A task that times out is failed and its worker is abandoned (left running, with what
//   it still sends ignored) and replaced, where TypeScript terminates the worker and replaces it.
// - A worker that cannot be started is a crashed worker: its task fails and it is replaced, as TypeScript does for a worker's "error"
//   event.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const media_tools = @import("media-tools-zig");
const console_output = @import("console-output.zig");
const task_queue = ziggy.task_queue;
const types = task_queue.types;
const json = ziggy.json;
const worker_messages = ziggy.worker_messages;
const MessageQueue = ziggy.message_queue.MessageQueue;
const Message = ziggy.message_queue.Message;
const Worker = ziggy.worker.Worker;
const Timers = ziggy.timers.Timers;
const ITaskResult = types.ITaskResult;
const TaskStatus = types.TaskStatus;
const TaskPriority = types.TaskPriority;
const insertTaskByPriority = task_queue.pending_task_queue.insertTaskByPriority;
const resolveTaskPriority = task_queue.pending_task_queue.resolveTaskPriority;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskEventCallback = types.TaskEventCallback;
const IEventCallbackEntry = types.IEventCallbackEntry;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const IQueueBackend = task_queue.queue_backend.IQueueBackend;
const writeOutputLine = console_output.writeOutputLine;
const writeErrorLine = console_output.writeErrorLine;

//
// How many child tasks one task may have running at once.
//
// Ten, because a desktop machine has cores and a fast disk to spare, and whatever queued the work is
// usually what the user is waiting on. It is not the size of the worker pool: it is how much of that
// pool one task may fill, so a second import, a sync, or anything the user does still gets a worker.
//
const MAX_CONCURRENT_CHILD_TASKS = 10;

//
// The task types the workers run: every task handler of the application. Each task that runs ImageMagick or FFmpeg makes the tools
// built into the program on its own thread.
//
const task_types = node_api.task_handlers.taskEntries(media_tools.ThreadTools, registerMediaSources);

//
// Registers, on a task's thread before the task runs, the builders of the media sources an import reads (initTaskHandlers in
// TypeScript).
//
fn registerMediaSources(context: task_queue.types.ITaskContext) anyerror!void {
    _ = context;
    try node_api.task_handlers.registerMediaSourceBuilders();
}

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

    // The task types the workers run, or null for every task handler of the application. It stands for the worker script TypeScript
    // starts each worker from, and must outlive the pool.
    tasks: ?[]const ziggy.task_runner.TaskHandlerEntry = null,
};

//
// A task the pool knows of, from when it is added until it ends. Its strings are allocated with the pool's allocator.
//
const IPoolTask = struct {
    // The task's id.
    id: []const u8,

    // The task's type.
    taskType: []const u8,

    // The source the task is cancelled by.
    source: []const u8,

    // The task's data as JSON text, as it is sent to a worker.
    dataJson: []const u8,

    // The task's priority.
    priority: TaskPriority,
};

//
// Worker state interface
//
const IWorkerState = struct {
    // The underlying worker thread.
    worker: *Worker,

    // The number the worker's messages reach the main thread's queue under. A replacement gets a new one, so what an abandoned worker
    // still sends is never taken for its replacement's.
    senderId: u32,

    // Unique numeric identifier assigned to this worker for logging and options.
    workerId: u32,

    // Worker has sent "ready" message and can process tasks.
    isReady: bool,

    // Worker is ready and not currently processing a task.
    isIdle: bool,

    // ID of the task currently being processed, or null if idle. Owned by the task.
    currentTaskId: ?[]const u8,

    // Type of the task currently being processed, or null if idle. Owned by the task.
    currentTaskType: ?[]const u8,

    // Elapsed milliseconds for the current task, updated on status polls, or null if idle.
    currentTaskRunningTimeMs: ?i64,

    // Number of tasks this worker has completed (successful or failed).
    tasksProcessed: u64,

    // Timestamp (milliseconds on the awake clock) when the current task started, or null if idle. The task times out the pool's
    // timeout after it.
    taskStartTime: ?i64,
};

//
// A registration of a callback with the key that identifies it for unsubscribing.
//
fn Registration(comptime CallbackT: type) type {
    return struct {
        // Identifies the registration.
        key: usize,

        // The source filter (empty when the callback is not per source). Owned.
        source: []u8,

        // The callback.
        callback: CallbackT,
    };
}

//
// The keys of the registrations of a list, copied with the allocator, which the caller frees them with. A callback may register or
// unregister callbacks while the callbacks of a list are called, so they are called by these keys rather than by their places in the
// list.
//
fn callbackKeys(allocator: std.mem.Allocator, list: anytype) []usize {
    const keys = allocator.alloc(usize, list.items.len) catch @panic("out of memory calling callbacks");
    for (list.items, keys) |registration, *key| {
        key.* = registration.key;
    }
    return keys;
}

//
// The registration of a list with the key, or null when it has been unregistered.
//
fn registered(list: anytype, key: usize) ?@TypeOf(list.items[0]) {
    for (list.items) |registration| {
        if (registration.key == key) {
            return registration;
        }
    }
    return null;
}

//
// Converts a number to its string form.
//
fn formatNumber(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try utils.js_number.writeNumber(&output.writer, value);
    return output.written();
}

//
// The delay used for a requested timer delay (utils-zig's sleep.zig).
//
const setTimeoutDelay = utils.sleep.setTimeoutDelay;

//
// Manages workers.
//
pub const WorkerPoolBun = struct {
    // The tools built into the program, which every worker's tasks run.
    mediaTools: *media_tools.MediaTools,

    // The pool's queue, which the workers send their messages to and the main thread reads. When the pool has abandoned a worker,
    // freeing the pool closes the queue and keeps it, so a late message from that worker is dropped.
    mainQueue: *MessageQueue,

    // Whether a worker has been abandoned (left running, see handleTaskTimeout).
    abandonedWorkers: bool,

    // The number the next worker's messages reach mainQueue under. A late message from a worker an earlier pool abandoned goes to
    // that pool's queue, so the numbers need only differ within this pool.
    nextSenderId: u32,

    // All currently allocated worker threads.
    workers: std.ArrayList(*IWorkerState),

    // Maximum number of worker threads allowed.
    maxWorkers: f64,

    // Options forwarded to each worker thread for logging and session initialization.
    workerOptions: IWorkerPoolOptions,

    // Milliseconds before a running task is considered timed out.
    taskTimeout: f64,

    // Callbacks notified when any task completes (success or failure).
    completionCallbacks: std.ArrayList(Registration(WorkerTaskCompletionCallback)),

    // Callbacks notified for task messages of a specific type.
    messageCallbacks: std.ArrayList(Registration(IEventCallbackEntry)),

    // Callbacks notified for every task message regardless of type.
    anyMessageCallbacks: std.ArrayList(Registration(TaskEventCallback)),

    // Tasks waiting to be dispatched to a worker.
    pendingTasks: std.ArrayList(*IPoolTask),

    // Maps task ID to task for result construction.
    taskMap: std.StringHashMapUnmanaged(*IPoolTask),

    // Callbacks registered per source via onTaskAdded.
    taskAddedCallbacks: std.ArrayList(Registration(TaskAddedCallback)),

    // Callbacks registered per source via onTasksCancelled.
    tasksCancelledCallbacks: std.ArrayList(Registration(TasksCancelledCallback)),

    // The key of the next registration.
    nextKey: usize,

    // Makes the ids of tasks added without one.
    randomUuidGenerator: utils.random_uuid_generator.RandomUuidGenerator,

    // Set once shutdown has begun.
    isShuttingDown: bool,

    // The results of the tasks whose worker could not be given them, as the JSON text of each ITaskResult, owned: the callbacks are
    // called with them at the next wait, which has the main thread's timers they are given (see handleWorkerCrash).
    crashedResults: std.ArrayList([]u8),

    //
    // Creates a new task queue with the specified number of workers, allocated with the main thread's allocator.
    // Tasks will execute in separate worker threads for true parallelism.
    // taskTimeout: Timeout in milliseconds for tasks.
    // workerOptions: Options to pass to workers for logging and context initialization.
    // mediaTools: The ImageMagick and FFmpeg built into the program, which must outlive the pool.
    // The thread that calls it is the pool's main thread, which alone uses the pool.
    //
    pub fn init(allocator: std.mem.Allocator, mediaTools: *media_tools.MediaTools, maxWorkers: f64, taskTimeout: f64, workerOptions: IWorkerPoolOptions) !*WorkerPoolBun {
        const self = try allocator.create(WorkerPoolBun);
        errdefer allocator.destroy(self);
        const queue = try allocator.create(MessageQueue);
        queue.* = MessageQueue.init();
        self.* = .{
            .mediaTools = mediaTools,
            .mainQueue = queue,
            .abandonedWorkers = false,
            .nextSenderId = 1,
            .workers = .empty,
            .maxWorkers = maxWorkers,
            .workerOptions = workerOptions,
            .taskTimeout = taskTimeout,
            .completionCallbacks = .empty,
            .messageCallbacks = .empty,
            .anyMessageCallbacks = .empty,
            .pendingTasks = .empty,
            .taskMap = .empty,
            .taskAddedCallbacks = .empty,
            .tasksCancelledCallbacks = .empty,
            .nextKey = 0,
            .randomUuidGenerator = .{},
            .isShuttingDown = false,
            .crashedResults = .empty,
        };
        return self;
    }

    //
    // Shuts the pool down and frees it, with the main thread's Io and allocator.
    //
    pub fn deinit(self: *WorkerPoolBun, io: std.Io, allocator: std.mem.Allocator) void {
        self.shutdown(io, allocator);
        if (self.abandonedWorkers) {
            self.mainQueue.close(io);
        }
        else {
            self.mainQueue.deinit();
            allocator.destroy(self.mainQueue);
        }
        var tasks = self.taskMap.valueIterator();
        while (tasks.next()) |poolTask| {
            freeTask(allocator, poolTask.*);
        }
        self.taskMap.deinit(allocator);
        freeList(allocator, &self.completionCallbacks);
        freeList(allocator, &self.messageCallbacks);
        freeList(allocator, &self.anyMessageCallbacks);
        freeList(allocator, &self.taskAddedCallbacks);
        freeList(allocator, &self.tasksCancelledCallbacks);
        self.pendingTasks.deinit(allocator);
        self.workers.deinit(allocator);
        for (self.crashedResults.items) |text| {
            allocator.free(text);
        }
        self.crashedResults.deinit(allocator);
        allocator.destroy(self);
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
        .onTaskEvent = onTaskEventErased,
        .onAnyTaskEvent = onAnyTaskEventErased,
        .cancelTasks = cancelTasksErased,
        .onTasksCancelled = onTasksCancelledErased,
        .shutdown = shutdownErased,
        .waitForMessage = waitForMessageErased,
    };

    //
    // The current time on the monotonic clock in milliseconds.
    //
    fn nowMs(io: std.Io) i64 {
        return std.Io.Clock.awake.now(io).toMilliseconds();
    }

    //
    // Adds a task to the pending queue and attempts to dispatch it immediately. Returns the task's id, allocated with the allocator.
    //
    // An interactive task goes in ahead of every background task already waiting, because the user
    // is sitting there looking at it.
    //
    pub fn addTask(self: *WorkerPoolBun, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) ![]const u8 {
        const id = if (taskId) |given| try allocator.dupe(u8, given) else try self.randomUuidGenerator.uuidGenerator().generate(allocator, io);
        errdefer allocator.free(id);
        const dataJson = try json.stringify(allocator, data);
        defer allocator.free(dataJson);
        try self.addTaskWithParent(io, log, allocator, @"type", dataJson, source, id, priority, null);
        return id;
    }

    //
    // Adds a task that a running task asked for, so it runs at that task's priority unless it asked
    // for one of its own. This is what stops an import's hash and upload children overtaking a tap.
    //
    fn addTaskWithParent(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, @"type": []const u8, dataJson: []const u8, source: []const u8, taskId: []const u8, priority: ?TaskPriority, parentPriority: ?TaskPriority) !void {
        const poolTask = try allocator.create(IPoolTask);
        errdefer allocator.destroy(poolTask);
        poolTask.* = .{
            .id = try allocator.dupe(u8, taskId),
            .taskType = try allocator.dupe(u8, @"type"),
            .source = try allocator.dupe(u8, source),
            .dataJson = try allocator.dupe(u8, dataJson),
            .priority = resolveTaskPriority(priority, parentPriority),
        };
        try insertTaskByPriority(allocator, &self.pendingTasks, poolTask);
        try self.taskMap.put(allocator, poolTask.id, poolTask);

        const keys = callbackKeys(allocator, &self.taskAddedCallbacks);
        defer allocator.free(keys);
        for (keys) |key| {
            const registration = registered(&self.taskAddedCallbacks, key) orelse {
                continue;
            };
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(allocator, log, poolTask.id);
            }
        }

        self.tryDispatchPending(io, log, allocator);
    }

    //
    // Registers a callback that fires when a task with the given source is added.
    //
    pub fn onTaskAdded(self: *WorkerPoolBun, allocator: std.mem.Allocator, source: []const u8, callback: TaskAddedCallback) !UnsubscribeFn {
        return self.register(allocator, TaskAddedCallback, &self.taskAddedCallbacks, source, callback);
    }

    //
    // The priority of the task the given worker is running, so a child it queues inherits it.
    // Null when the worker is between tasks, which a child task cannot be spawned from.
    //
    fn priorityOfRunningTask(self: *WorkerPoolBun, workerState: *IWorkerState) ?TaskPriority {
        const taskId = workerState.currentTaskId orelse {
            return null;
        };
        const poolTask = self.taskMap.get(taskId) orelse {
            return null;
        };
        return poolTask.priority;
    }

    //
    // Tries to dispatch all pending tasks to available workers.
    //
    fn tryDispatchPending(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator) void {
        while (self.pendingTasks.items.len > 0) {
            const poolTask = self.pendingTasks.items[0];
            if (!self.dispatchTask(io, log, allocator, poolTask)) {
                break;
            }
            _ = self.pendingTasks.orderedRemove(0);
        }
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    pub fn onTaskComplete(self: *WorkerPoolBun, allocator: std.mem.Allocator, callback: WorkerTaskCompletionCallback) !UnsubscribeFn {
        return self.register(allocator, WorkerTaskCompletionCallback, &self.completionCallbacks, "", callback);
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // Only messages with the given type are passed to the callback.
    //
    pub fn onTaskEvent(self: *WorkerPoolBun, allocator: std.mem.Allocator, messageType: []const u8, callback: TaskEventCallback) !UnsubscribeFn {
        return self.register(allocator, IEventCallbackEntry, &self.messageCallbacks, "", .{
            .eventType = try allocator.dupe(u8, messageType),
            .callback = callback,
        });
    }

    //
    // Registers a callback that will be called for any task message, regardless of type.
    //
    pub fn onAnyTaskEvent(self: *WorkerPoolBun, allocator: std.mem.Allocator, callback: TaskEventCallback) !UnsubscribeFn {
        return self.register(allocator, TaskEventCallback, &self.anyMessageCallbacks, "", callback);
    }

    //
    // Invokes all registered completion callbacks with the task result, with the main thread's Io, allocator and timers.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyCompletionCallbacks(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers, result: ITaskResult) void {
        const keys = callbackKeys(allocator, &self.completionCallbacks);
        defer allocator.free(keys);
        for (keys) |key| {
            const registration = registered(&self.completionCallbacks, key) orelse {
                continue;
            };
            registration.callback.call(io, allocator, timers, log, result) catch |err| {
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", err);
            };
        }
    }

    //
    // Invokes all registered message callbacks with the task message, with the main thread's Io, allocator and timers.
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyMessageCallbacks(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers, taskId: []const u8, message: std.json.Value) void {
        const messageType = types.eventTypeOf(message);
        const data: types.ITaskEventData = .{
            .taskId = taskId,
            .event = message,
        };

        // Notify callbacks registered for specific message types
        const typed_keys = callbackKeys(allocator, &self.messageCallbacks);
        defer allocator.free(typed_keys);
        for (typed_keys) |key| {
            const registration = registered(&self.messageCallbacks, key) orelse {
                continue;
            };
            const wanted = messageType orelse {
                continue;
            };
            if (!std.mem.eql(u8, wanted, registration.callback.eventType)) {
                continue;
            }
            registration.callback.callback.call(io, allocator, timers, log, data) catch |err| {
                // Don't let callback errors break the task queue
                log.exception("Error in task message callback", err);
            };
        }

        // Notify callbacks registered for any message type
        const any_keys = callbackKeys(allocator, &self.anyMessageCallbacks);
        defer allocator.free(any_keys);
        for (any_keys) |key| {
            const registration = registered(&self.anyMessageCallbacks, key) orelse {
                continue;
            };
            registration.callback.call(io, allocator, timers, log, data) catch |err| {
                // Don't let callback errors break the task queue
                log.exception("Error in any task message callback", err);
            };
        }
    }

    //
    // Starts a worker thread whose messages reach the main thread's queue under a number of its own.
    //
    fn startWorker(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, workerId: u32) !*IWorkerState {
        const senderId = self.nextSenderId;
        self.nextSenderId += 1;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The worker gets a copy of this thread's environment as its own, as a Bun worker is given process.env.
        const environment: ?std.json.Value = if (ziggy.utils.process_env.getEnvironMap()) |map| try ziggy.worker.environmentJson(arena, map) else null;
        // A log with a file writes every line, whatever its console shows, so when the log given has one the worker sends its verbose and tool
        // lines too, and the log's console options decide what the console shows.
        const writesFile = log.logFilePath() != null;
        const options: ziggy.worker.IWorkerOptions = .{
            .workerId = workerId,
            .verbose = writesFile or (self.workerOptions.verbose orelse false),
            .tools = writesFile or (self.workerOptions.tools orelse false),
            .sessionId = self.workerOptions.sessionId orelse "",
            .maxConcurrentChildTasks = MAX_CONCURRENT_CHILD_TASKS,
            .environment = environment,
        };
        const worker = try Worker.start(allocator, io, senderId, self.mainQueue, .{
            .options_json = try json.stringify(arena, options),
            .tasks = self.workerOptions.tasks orelse &task_types,
            .describe_error = describeError,
        });
        const workerState = try allocator.create(IWorkerState);
        workerState.* = .{
            .worker = worker,
            .senderId = senderId,
            .workerId = workerId,
            .isReady = false, // Will be set to true when worker sends "ready" message
            .isIdle = false, // Will be set to true when worker is ready and idle
            .currentTaskId = null,
            .currentTaskType = null,
            .currentTaskRunningTimeMs = null,
            .tasksProcessed = 0,
            .taskStartTime = null,
        };
        return workerState;
    }

    //
    // Creates a single worker and adds it to the pool.
    // A worker that cannot be started is handled as a crashed one.
    //
    fn createWorker(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator) void {
        const workerId: u32 = @intCast(self.workers.items.len + 1);
        const workerState = self.startWorker(io, log, allocator, workerId) catch |err| {
            var message_buffer: [64]u8 = undefined;
            log.exception(std.fmt.bufPrint(&message_buffer, "Error from worker {d}", .{workerId}) catch "Error from worker", err);
            return;
        };
        self.workers.append(allocator, workerState) catch @panic("out of memory adding a worker");
    }

    //
    // Replaces a worker with a new one.
    //
    fn replaceWorker(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, oldWorkerState: *IWorkerState) void {
        // Remove from workers array
        for (self.workers.items, 0..) |workerState, index| {
            if (workerState == oldWorkerState) {
                _ = self.workers.orderedRemove(index);
                break;
            }
        }

        const workerId = oldWorkerState.workerId;
        const tasksProcessed = oldWorkerState.tasksProcessed; // Preserve task count when replacing worker
        allocator.destroy(oldWorkerState);
        const newWorkerState = self.startWorker(io, log, allocator, workerId) catch |err| {
            var message_buffer: [64]u8 = undefined;
            log.exception(std.fmt.bufPrint(&message_buffer, "Error from worker {d}", .{workerId}) catch "Error from worker", err);
            return;
        };
        newWorkerState.tasksProcessed = tasksProcessed;
        self.workers.append(allocator, newWorkerState) catch @panic("out of memory replacing a worker");
    }

    //
    // Handles every message waiting in the main thread's queue without waiting, then fails the tasks that have timed out and runs the
    // main thread's timers that are due.
    //
    pub fn handleQueuedMessages(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers) void {
        _ = self.reportCrashedTasks(io, log, allocator, timers);
        while (self.mainQueue.tryTake(io, allocator)) |message| {
            defer allocator.free(message.text);
            self.receive(io, log, allocator, timers, message);
        }
        self.failTimedOutTasks(io, log, allocator, timers);
        timers.runDue(io, allocator, null);
    }

    //
    // Reads the main thread's next message, waiting no longer than until the next task timeout or the next of the main thread's timers
    // is due, handles it, then fails the tasks that have timed out and runs the timers that are due. The main thread's own code waits
    // for its tasks with it, through the IQueueBackend.
    //
    pub fn waitForMessage(self: *WorkerPoolBun, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        // A task whose worker could not be given it has ended, which a wait reports as it would a message.
        if (self.reportCrashedTasks(io, log, allocator, timers)) {
            return;
        }
        if (self.mainQueue.take(io, allocator, earlierTimeout(timers.nextTimeout(), self.nextTaskTimeout()))) |message| {
            defer allocator.free(message.text);
            self.receive(io, log, allocator, timers, message);
        }
        self.failTimedOutTasks(io, log, allocator, timers);
        timers.runDue(io, allocator, null);
    }

    //
    // Calls the completion callbacks with the results of the tasks whose worker could not be given them, and says whether there were
    // any.
    //
    fn reportCrashedTasks(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers) bool {
        if (self.crashedResults.items.len == 0) {
            return false;
        }
        const results = self.crashedResults.toOwnedSlice(allocator) catch @panic("out of memory reporting a crashed task");
        defer allocator.free(results);
        for (results) |text| {
            defer allocator.free(text);
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const result = std.json.parseFromSliceLeaky(ITaskResult, arena_state.allocator(), text, .{}) catch @panic("out of memory reporting a crashed task");
            self.notifyCompletionCallbacks(io, log, allocator, timers, result);
        }
        return true;
    }

    //
    // When the first running task times out, or none when no task is running.
    //
    fn nextTaskTimeout(self: *WorkerPoolBun) std.Io.Timeout {
        var earliest: ?i64 = null;
        for (self.workers.items) |workerState| {
            const deadline = self.taskDeadline(workerState) orelse {
                continue;
            };
            if (earliest == null or deadline < earliest.?) {
                earliest = deadline;
            }
        }
        const deadline = earliest orelse {
            return .none;
        };
        return .{
            .deadline = .{
                .raw = .fromNanoseconds(@as(i96, deadline) * std.time.ns_per_ms),
                .clock = .awake,
            },
        };
    }

    //
    // When the task the worker is running times out, in milliseconds on the awake clock, or null when it runs none.
    //
    fn taskDeadline(self: *WorkerPoolBun, workerState: *const IWorkerState) ?i64 {
        if (workerState.currentTaskId == null) {
            return null;
        }
        const started = workerState.taskStartTime orelse {
            return null;
        };
        return started + @as(i64, @intCast(setTimeoutDelay(self.taskTimeout)));
    }

    //
    // Fails every task that has run past its timeout (see handleTaskTimeout).
    //
    fn failTimedOutTasks(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers) void {
        var index: usize = 0;
        while (index < self.workers.items.len) {
            const workerState = self.workers.items[index];
            const deadline = self.taskDeadline(workerState) orelse {
                index += 1;
                continue;
            };
            if (nowMs(io) < deadline) {
                index += 1;
                continue;
            }
            // The worker is replaced, so the same place is looked at again.
            self.handleTaskTimeout(io, log, allocator, timers, workerState) catch |err| {
                log.exception("Error handling task timeout", err);
                index += 1;
            };
        }
    }

    //
    // Hands a message from the main thread's queue to the worker state of the worker that sent it. A message from a worker the pool
    // no longer has (an abandoned one) is ignored.
    //
    fn receive(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers, message: Message) void {
        for (self.workers.items) |workerState| {
            if (workerState.senderId == message.from) {
                self.handleWorkerMessage(io, log, allocator, timers, workerState, message.text);
                return;
            }
        }
    }

    //
    // Handles messages from worker threads.
    // Processes task results and errors.
    //
    fn handleWorkerMessage(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers, workerState: *IWorkerState, text: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
            std.debug.panic("a worker sent a message that is not JSON: {s}", .{text});
        };
        const messageType = worker_messages.typeOf(parsed) orelse {
            std.debug.panic("a worker sent a message with no type: {s}", .{text});
        };

        // A worker that could not start (TypeScript: the worker's "error" event). Its thread has ended, so it is released, and it had
        // no task yet, so replacing it is all that handleWorkerCrash has left to do.
        if (std.mem.eql(u8, messageType, "worker-error")) {
            const failure = worker_messages.decodeValue(worker_messages.IWorkerErrorMessage, arena, parsed) catch |err| {
                std.debug.panic("could not read a worker's worker-error message ({s}): {s}", .{ @errorName(err), text });
            };
            var message_buffer: [64]u8 = undefined;
            log.exception(std.fmt.bufPrint(&message_buffer, "Error from worker {d}", .{workerState.workerId}) catch "Error from worker", utils.errors.throwError("{s}", .{failure.message}));
            workerState.worker.destroy(allocator);
            self.replaceWorker(io, log, allocator, workerState);
            return;
        }

        // Handle worker ready message
        if (std.mem.eql(u8, messageType, "worker-ready")) {
            workerState.isReady = true;
            workerState.isIdle = true;
            self.tryDispatchPending(io, log, allocator);
            return;
        }

        // Handle task result (both success and failure)
        if (std.mem.eql(u8, messageType, "task-completed")) {
            const data = worker_messages.decodeValue(worker_messages.IWorkerTaskCompletedMessage, arena, parsed) catch |err| {
                std.debug.panic("could not read a worker's task-completed message ({s}): {s}", .{ @errorName(err), text });
            };
            const taskId = data.taskId;
            const result = data.result;

            const poolTask = self.taskMap.get(taskId);
            _ = self.taskMap.remove(taskId);
            defer if (poolTask) |task| freeTask(allocator, task);

            if (result.status == .Failed and log.verboseEnabled()) {
                const detail = std.fmt.allocPrint(arena, "Task {s} failed with error {{\n  \"name\": \"{s}\",\n  \"message\": \"{s}\"\n}}", .{ taskId, if (result.@"error") |failure| failure.name else "Error", result.errorMessage orelse "" }) catch @panic("out of memory logging a failed task");
                writeOutputLine(prefixMessage(arena, workerState.workerId, workerState.currentTaskId, detail));
            }

            // Build result object
            const fullResult: ITaskResult = .{
                .taskId = taskId,
                .status = result.status,
                .@"error" = result.@"error",
                .errorMessage = if (result.@"error") |failure| failure.message else "Unknown error",
                .outputs = result.outputs,
                .type = if (poolTask) |task| task.taskType else "",
                .inputs = inputsOf(arena, poolTask),
            };

            // Update worker state
            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            workerState.tasksProcessed += 1;

            self.notifyCompletionCallbacks(io, log, allocator, timers, fullResult);

            // Broadcast completion to all workers so worker-side TaskQueue instances
            // (e.g. in orchestrator tasks) can react to child task completions.
            const completed = json.stringify(arena, .{
                .type = "task-completed",
                .taskId = taskId,
                .result = fullResult,
            }) catch @panic("out of memory telling the workers a task ended");
            for (self.workers.items) |each| {
                each.worker.postMessage(io, completed) catch @panic("out of memory telling the workers a task ended");
            }

            self.tryDispatchPending(io, log, allocator);
            return;
        }

        // Handle task message
        if (std.mem.eql(u8, messageType, "task-message")) {
            const taskId = json.getString(parsed, "taskId") orelse {
                std.debug.panic("a worker sent a task-message with no task id: {s}", .{text});
            };
            self.notifyMessageCallbacks(io, log, allocator, timers, taskId, parsed.object.get("message") orelse .null);
            return;
        }

        // Handle queue-task request from worker
        if (std.mem.eql(u8, messageType, "queue-task")) {
            const msg = worker_messages.decodeValue(worker_messages.IWorkerQueueTaskMessage, arena, parsed) catch |err| {
                std.debug.panic("could not read a worker's queue-task message ({s}): {s}", .{ @errorName(err), text });
            };
            const requested: ?TaskPriority = if (msg.priority) |given| switch (given) {
                .Interactive => .Interactive,
                .Background => .Background,
            } else null;
            const dataJson = json.stringify(arena, msg.data) catch @panic("out of memory queueing a child task");
            self.addTaskWithParent(io, log, allocator, msg.taskType, dataJson, msg.source, msg.taskId, requested, self.priorityOfRunningTask(workerState)) catch @panic("out of memory queueing a child task");
            return;
        }

        // A worker's log line: only the main thread writes the output, prefixed with the worker and its task as WorkerLogBun does.
        if (std.mem.eql(u8, messageType, "log")) {
            writeWorkerLog(arena, log, self.workerOptions.tools orelse false, workerState.workerId, workerState.currentTaskId, text);
            return;
        }

        // A line a worker wrote to its console, which reaches the output as it is.
        if (std.mem.eql(u8, messageType, "console")) {
            const line = worker_messages.decode(worker_messages.IWorkerConsoleMessage, arena, text) catch |err| {
                std.debug.panic("could not read a worker's console message ({s}): {s}", .{ @errorName(err), text });
            };
            if (std.mem.eql(u8, line.stream, "stderr")) {
                writeErrorLine(line.line);
            }
            else {
                writeOutputLine(line.line);
            }
            return;
        }

        // The CLI has no native app: a task's request to one fails.
        if (std.mem.eql(u8, messageType, "native-app-request")) {
            const reply = json.stringify(arena, .{
                .type = "native-app-response",
                .requestId = json.getInteger(parsed, "requestId") orelse 0,
                .@"error" = "NativeCallMissing",
            }) catch @panic("out of memory answering a native app request");
            workerState.worker.postMessage(io, reply) catch @panic("out of memory answering a native app request");
            return;
        }
    }

    //
    // Writes a worker's log line to the log given (the main thread's) as WorkerLogBun writes it: the line as the worker's console would
    // show it, prefixed with the worker and the task it is running (`[W<id>:<task id>]`, or `[W<id>]` between tasks). With a log
    // file, workers send every verbose and tool line: the main thread's log leaves verbose lines off its console as its options say, and
    // a tool line is shown only when the command was given --tools (`toolsShown`), otherwise it goes to the log as a tool line, which
    // only a log file keeps. WorkerLogBun writes no debug lines. The text is the worker's log message (IWorkerLogMessage).
    //
    pub fn writeWorkerLog(arena: std.mem.Allocator, log: ILog, toolsShown: bool, workerId: u32, taskId: ?[]const u8, text: []const u8) void {
        const message = worker_messages.decode(worker_messages.IWorkerLogMessage, arena, text) catch |err| {
            std.debug.panic("could not read a worker's log message ({s}): {s}", .{ @errorName(err), text });
        };
        switch (message.level) {
            .info => log.info(prefixMessage(arena, workerId, taskId, message.message)),
            .verbose => log.verbose(prefixMessage(arena, workerId, taskId, message.message)),
            .@"error" => log.@"error"(prefixMessage(arena, workerId, taskId, message.message)),
            .warn => log.warn(prefixMessage(arena, workerId, taskId, message.message)),
            .exception => {
                log.@"error"(prefixMessage(arena, workerId, taskId, message.message));
                if (message.@"error") |errorText| {
                    log.@"error"(errorText);
                }
            },
            .debug => {},
            .tool => if (!toolsShown) {
                log.tool(prefixMessage(arena, workerId, taskId, message.message), .{
                    .stdout = if (message.toolData) |data| data.stdout else null,
                    .stderr = if (message.toolData) |data| data.stderr else null,
                });
            }
            else if (message.toolData) |data| {
                writeToolStream(arena, log, workerId, taskId, message.message, "stdout", data.stdout);
                writeToolStream(arena, log, workerId, taskId, message.message, "stderr", data.stderr);
            },
            .event => log.info(prefixMessage(arena, workerId, taskId, std.fmt.allocPrint(arena, "[EVENT] {s}", .{message.message}) catch @panic("out of memory writing a log line"))),
        }
    }

    //
    // Writes `== <tool> <stream> ==` and what a worker's tool wrote to it, prefixed as the worker's other lines are, when the tool
    // wrote anything.
    //
    fn writeToolStream(arena: std.mem.Allocator, log: ILog, workerId: u32, taskId: ?[]const u8, toolName: []const u8, stream: []const u8, text: ?[]const u8) void {
        const written = text orelse return;
        if (written.len == 0) {
            return;
        }
        log.info(prefixMessage(arena, workerId, taskId, std.fmt.allocPrint(arena, "== {s} {s} ==\n{s}", .{ toolName, stream, written }) catch @panic("out of memory writing a log line")));
    }

    //
    // Handles task timeout by abandoning the worker and marking the task as failed.
    //
    fn handleTaskTimeout(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, timers: Timers, workerState: *IWorkerState) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const taskId = try arena.dupe(u8, workerState.currentTaskId.?);

        const timeoutText = try formatNumber(arena, self.taskTimeout);
        log.@"error"(try std.fmt.allocPrint(arena, "[Task Queue] Task {s} timed out after {s}ms", .{ taskId, timeoutText }));

        // Abandon the worker: a thread cannot be stopped, so it is left to finish on its own.
        workerState.worker.abandon();
        self.abandonedWorkers = true;

        const poolTask = self.taskMap.get(taskId);
        _ = self.taskMap.remove(taskId);
        defer if (poolTask) |task| freeTask(allocator, task);
        const result: ITaskResult = .{
            .taskId = taskId,
            .status = .Failed,
            .@"error" = .{ .name = "Error", .message = "Task timeout" },
            .errorMessage = "Task timeout",
            .type = if (poolTask) |task| task.taskType else "",
            .inputs = inputsOf(arena, poolTask),
        };

        workerState.isIdle = true;
        workerState.currentTaskId = null;
        workerState.currentTaskType = null;
        workerState.currentTaskRunningTimeMs = null;
        workerState.taskStartTime = null;

        self.notifyCompletionCallbacks(io, log, allocator, timers, result);

        // Replace the worker
        self.replaceWorker(io, log, allocator, workerState);
        self.tryDispatchPending(io, log, allocator);
    }

    //
    // Handles a worker that could not be given its task: fails the task and replaces the worker. The completion callbacks are called
    // with the task's result at the next wait (see reportCrashedTasks), because a task can be dispatched where the pool is given no
    // timers (addTask).
    //
    fn handleWorkerCrash(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, workerState: *IWorkerState) void {
        // If worker had a task, mark it as failed
        if (workerState.currentTaskId) |crashedTaskId| {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const poolTask = self.taskMap.get(crashedTaskId);
            const taskId = if (poolTask) |task| task.id else crashedTaskId;
            const result: ITaskResult = .{
                .taskId = taskId,
                .status = .Failed,
                .@"error" = .{ .name = "Error", .message = "Worker crashed" },
                .errorMessage = "Worker crashed",
                .type = if (poolTask) |task| task.taskType else "",
                .inputs = inputsOf(arena, poolTask),
            };
            const text = json.stringify(allocator, result) catch @panic("out of memory failing a crashed task");
            self.crashedResults.append(allocator, text) catch @panic("out of memory failing a crashed task");
            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            if (poolTask) |task| {
                _ = self.taskMap.remove(task.id);
                freeTask(allocator, task);
            }
        }

        // Abandon the worker and replace it
        workerState.worker.abandon();
        self.abandonedWorkers = true;
        self.replaceWorker(io, log, allocator, workerState);
    }

    //
    // Dispatches a single task to an available worker.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    fn dispatchTask(self: *WorkerPoolBun, io: std.Io, log: ILog, allocator: std.mem.Allocator, poolTask: *IPoolTask) bool {
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
        // If no idle worker available and we haven't reached maxWorkers, create a worker. It is not idle until it sends its "ready"
        // message, so return for now.
        //
        const workerState = availableWorker orelse {
            if (@as(f64, @floatFromInt(self.workers.items.len)) < self.maxWorkers) {
                self.createWorker(io, log, allocator);
            }
            return false; // All workers busy or not ready yet
        };

        workerState.isIdle = false;
        workerState.currentTaskId = poolTask.id;
        workerState.currentTaskType = poolTask.taskType;
        // The task times out the pool's timeout after this, which the waits look at (see nextTaskTimeout).
        workerState.taskStartTime = nowMs(io);

        // Send task to worker
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const executeMsg = json.stringify(arena_state.allocator(), .{
            .type = "execute",
            .taskId = poolTask.id,
            .taskType = poolTask.taskType,
            .data = json.Raw{
                .text = poolTask.dataJson,
            },
            .source = poolTask.source,
        }) catch |err| {
            var message_buffer: [64]u8 = undefined;
            log.exception(std.fmt.bufPrint(&message_buffer, "Error sending task to worker {d}", .{workerState.workerId}) catch "Error sending task to worker", err);
            self.handleWorkerCrash(io, log, allocator, workerState);
            return true;
        };
        workerState.worker.postMessage(io, executeMsg) catch |err| {
            var message_buffer: [64]u8 = undefined;
            log.exception(std.fmt.bufPrint(&message_buffer, "Error sending task to worker {d}", .{workerState.workerId}) catch "Error sending task to worker", err);
            self.handleWorkerCrash(io, log, allocator, workerState);
        };

        return true;
    }

    //
    // Drops pending tasks with the given source and signals running tasks to cancel.
    //
    pub fn cancelTasks(self: *WorkerPoolBun, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        _ = log;
        var index: usize = 0;
        while (index < self.pendingTasks.items.len) {
            const poolTask = self.pendingTasks.items[index];
            if (!std.mem.eql(u8, poolTask.source, source)) {
                index += 1;
                continue;
            }
            _ = self.pendingTasks.orderedRemove(index);
            _ = self.taskMap.remove(poolTask.id);
            freeTask(allocator, poolTask);
        }

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const cancelMsg = json.stringify(arena_state.allocator(), .{
            .type = "cancel-tasks",
            .source = source,
        }) catch @panic("out of memory cancelling tasks");
        for (self.workers.items) |workerState| {
            workerState.worker.postMessage(io, cancelMsg) catch @panic("out of memory cancelling tasks");
        }

        const keys = callbackKeys(allocator, &self.tasksCancelledCallbacks);
        defer allocator.free(keys);
        for (keys) |key| {
            const registration = registered(&self.tasksCancelledCallbacks, key) orelse {
                continue;
            };
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(io, allocator);
            }
        }
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    pub fn onTasksCancelled(self: *WorkerPoolBun, allocator: std.mem.Allocator, source: []const u8, callback: TasksCancelledCallback) !UnsubscribeFn {
        return self.register(allocator, TasksCancelledCallback, &self.tasksCancelledCallbacks, source, callback);
    }

    //
    // Shuts down all the workers and returns once every worker thread this pool started, apart from the abandoned ones, has ended.
    //
    // TypeScript terminates the workers, which ends the tasks they are running. A thread cannot be stopped from outside it, so the
    // task each worker is running is cancelled instead, and each worker is asked to end its own thread once that task returns. What
    // the tasks report is not read: a message from a worker that has started is dropped, so no callback is called and no timer is
    // needed.
    //
    pub fn shutdown(self: *WorkerPoolBun, io: std.Io, allocator: std.mem.Allocator) void {
        self.isShuttingDown = true;

        // A worker that has not sent "worker-ready" has not read anything yet, so it is waited for before it is told to end.
        while (self.anyStarting()) {
            const message = self.mainQueue.take(io, allocator, .none) orelse {
                break;
            };
            defer allocator.free(message.text);
            self.receiveWhileStopping(allocator, message);
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        for (self.workers.items) |workerState| {
            const taskId = workerState.currentTaskId orelse continue;
            const poolTask = self.taskMap.get(taskId) orelse continue;
            const cancelMsg = json.stringify(arena_state.allocator(), .{
                .type = "cancel-tasks",
                .source = poolTask.source,
            }) catch @panic("out of memory cancelling tasks");
            workerState.worker.postMessage(io, cancelMsg) catch @panic("out of memory cancelling tasks");
        }
        for (self.workers.items) |workerState| {
            workerState.worker.postMessage(io, "{\"type\":\"shutdown\"}") catch @panic("out of memory stopping a worker");
        }
        for (self.workers.items) |workerState| {
            workerState.worker.destroy(allocator);
            allocator.destroy(workerState);
        }
        self.workers.clearRetainingCapacity();
    }

    //
    // Stops the workers as the process ends, and returns once every worker thread this pool started, apart from the abandoned ones,
    // has ended: the task each worker is running is cancelled, so it can clean up after itself, and each worker is asked to end its
    // own thread once that task returns. Nothing is freed, because the process ends next, so no allocator is needed.
    //
    pub fn stopWorkers(self: *WorkerPoolBun, io: std.Io) void {
        self.isShuttingDown = true;
        var buffer: [4096]u8 = undefined;
        for (self.workers.items) |workerState| {
            const taskId = workerState.currentTaskId orelse continue;
            const poolTask = self.taskMap.get(taskId) orelse continue;
            var fixed = std.heap.FixedBufferAllocator.init(&buffer);
            const cancelMsg = json.stringify(fixed.allocator(), .{
                .type = "cancel-tasks",
                .source = poolTask.source,
            }) catch @panic("a task's source is too long to cancel it");
            workerState.worker.postMessage(io, cancelMsg) catch @panic("out of memory cancelling tasks");
        }
        for (self.workers.items) |workerState| {
            workerState.worker.postMessage(io, "{\"type\":\"shutdown\"}") catch @panic("out of memory stopping a worker");
        }
        for (self.workers.items) |workerState| {
            workerState.worker.thread.join();
        }
        self.workers.clearRetainingCapacity();
    }

    //
    // Reads a message while the pool shuts down: a worker that is starting reports that it is ready, or that it could not start, and
    // anything else is dropped.
    //
    fn receiveWhileStopping(self: *WorkerPoolBun, allocator: std.mem.Allocator, message: Message) void {
        for (self.workers.items, 0..) |workerState, index| {
            if (workerState.senderId != message.from) {
                continue;
            }
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), message.text, .{}) catch {
                std.debug.panic("a worker sent a message that is not JSON: {s}", .{message.text});
            };
            const messageType = worker_messages.typeOf(parsed) orelse {
                return;
            };
            if (std.mem.eql(u8, messageType, "worker-ready")) {
                workerState.isReady = true;
                workerState.isIdle = true;
            }
            else if (std.mem.eql(u8, messageType, "worker-error")) {
                // The worker's thread has ended, so it is released, and a worker is not started in its place.
                workerState.worker.destroy(allocator);
                _ = self.workers.orderedRemove(index);
                allocator.destroy(workerState);
            }
            return;
        }
    }

    //
    // Whether a worker has been started and has not sent "worker-ready" yet.
    //
    fn anyStarting(self: *WorkerPoolBun) bool {
        for (self.workers.items) |workerState| {
            if (!workerState.isReady) {
                return true;
            }
        }
        return false;
    }

    //
    // Adds a registration to a callback list and returns the function that removes it.
    //
    fn register(self: *WorkerPoolBun, allocator: std.mem.Allocator, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), source: []const u8, callback: CallbackT) !UnsubscribeFn {
        const sourceCopy = try allocator.dupe(u8, source);
        errdefer allocator.free(sourceCopy);
        const key = self.nextKey;
        self.nextKey += 1;
        try list.append(allocator, .{
            .key = key,
            .source = sourceCopy,
            .callback = callback,
        });
        return .{
            .context = self,
            .key = key,
            .function = unregister,
        };
    }

    //
    // Removes the registration with the given key from whichever list holds it, with the allocator it was made with.
    //
    fn unregister(context: ?*anyopaque, allocator: std.mem.Allocator, key: usize) void {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(context.?));
        removeKey(allocator, TaskAddedCallback, &self.taskAddedCallbacks, key);
        removeKey(allocator, WorkerTaskCompletionCallback, &self.completionCallbacks, key);
        removeKey(allocator, IEventCallbackEntry, &self.messageCallbacks, key);
        removeKey(allocator, TaskEventCallback, &self.anyMessageCallbacks, key);
        removeKey(allocator, TasksCancelledCallback, &self.tasksCancelledCallbacks, key);
    }

    //
    // The IQueueBackend addTask of this pool.
    //
    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, log: ILog, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.addTask(allocator, io, log, @"type", data, source, taskId, priority);
    }

    //
    // The IQueueBackend onTaskAdded of this pool.
    //
    fn onTaskAddedErased(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTaskAdded(allocator, source, callback);
    }

    //
    // The IQueueBackend onTaskComplete of this pool.
    //
    fn onTaskCompleteErased(ptr: *anyopaque, allocator: std.mem.Allocator, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTaskComplete(allocator, callback);
    }

    //
    // The IQueueBackend onTaskEvent of this pool.
    //
    fn onTaskEventErased(ptr: *anyopaque, allocator: std.mem.Allocator, eventType: []const u8, callback: TaskEventCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTaskEvent(allocator, eventType, callback);
    }

    //
    // The IQueueBackend onAnyTaskEvent of this pool.
    //
    fn onAnyTaskEventErased(ptr: *anyopaque, allocator: std.mem.Allocator, callback: TaskEventCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onAnyTaskEvent(allocator, callback);
    }

    //
    // The IQueueBackend cancelTasks of this pool.
    //
    fn cancelTasksErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: ILog, source: []const u8) void {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        self.cancelTasks(io, allocator, log, source);
    }

    //
    // The IQueueBackend onTasksCancelled of this pool.
    //
    fn onTasksCancelledErased(ptr: *anyopaque, allocator: std.mem.Allocator, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        return self.onTasksCancelled(allocator, source, callback);
    }

    //
    // The IQueueBackend shutdown of this pool.
    //
    fn shutdownErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        self.shutdown(io, allocator);
    }

    //
    // The IQueueBackend waitForMessage of this pool.
    //
    fn waitForMessageErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, log: ILog) void {
        const self: *WorkerPoolBun = @ptrCast(@alignCast(ptr));
        self.waitForMessage(io, allocator, timers, log);
    }
};

//
// The earlier of two timeouts, where none is later than any deadline. Both deadlines are on the awake clock.
//
fn earlierTimeout(first: std.Io.Timeout, second: std.Io.Timeout) std.Io.Timeout {
    const first_deadline = switch (first) {
        .deadline => |deadline| deadline,
        else => return second,
    };
    const second_deadline = switch (second) {
        .deadline => |deadline| deadline,
        else => return first,
    };
    return if (first_deadline.compare(.lte, second_deadline)) first else second;
}

//
// The input of a task, read back from its JSON text into the arena, or null when the pool no longer knows the task.
//
fn inputsOf(arena: std.mem.Allocator, poolTask: ?*IPoolTask) std.json.Value {
    const task = poolTask orelse {
        return .null;
    };
    return std.json.parseFromSliceLeaky(std.json.Value, arena, task.dataJson, .{}) catch @panic("out of memory reading a task's input");
}

//
// Prefixes a worker's log line with the worker and the task it is running, as WorkerLogBun's prefixMessage does.
//
fn prefixMessage(arena: std.mem.Allocator, workerId: u32, taskId: ?[]const u8, message: []const u8) []const u8 {
    if (taskId) |id| {
        return std.fmt.allocPrint(arena, "[W{d}:{s}] {s}", .{ workerId, id, message }) catch @panic("out of memory writing a log line");
    }
    return std.fmt.allocPrint(arena, "[W{d}] {s}", .{ workerId, message }) catch @panic("out of memory writing a log line");
}

//
// Gives the text of a failed task's error: the message the handler recorded (the task queue's throwError), or the error's name.
//
fn describeError(err: anyerror) ?[]const u8 {
    return utils.errors.errorMessage(err);
}

//
// Frees a task, with the allocator it was made with.
//
fn freeTask(allocator: std.mem.Allocator, poolTask: *IPoolTask) void {
    allocator.free(poolTask.id);
    allocator.free(poolTask.taskType);
    allocator.free(poolTask.source);
    allocator.free(poolTask.dataJson);
    allocator.destroy(poolTask);
}

//
// Frees the sources a list of registrations owns, and the list.
//
fn freeList(allocator: std.mem.Allocator, list: anytype) void {
    for (list.items) |registration| {
        freeRegistration(allocator, registration);
    }
    list.deinit(allocator);
}

//
// Frees what a registration owns: its source, and the event type of a typed event registration.
//
fn freeRegistration(allocator: std.mem.Allocator, registration: anytype) void {
    allocator.free(registration.source);
    if (@TypeOf(registration.callback) == IEventCallbackEntry) {
        allocator.free(registration.callback.eventType);
    }
}

//
// Removes the registration with the given key from a list, if it is there.
//
fn removeKey(allocator: std.mem.Allocator, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), key: usize) void {
    for (list.items, 0..) |registration, index| {
        if (registration.key == key) {
            freeRegistration(allocator, registration);
            _ = list.orderedRemove(index);
            return;
        }
    }
}

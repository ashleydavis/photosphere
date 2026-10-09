//
// The queue backend of Ziggy: the IQueueBackend that code written against task-queue-zig (the port of the task-queue package) talks to,
// backed by Ziggy's task runner. It is what WorkerPoolElectronMain is to the Electron app. The runner owns the threads, the one queue (an interactive
// task at the head, a background task at the end), cancellation by source and the pool and child task limits the platform layer
// sets. This file owns what the TypeScript pool owns besides those: the callbacks (onTaskAdded, onTaskComplete, onTaskMessage,
// onAnyTaskMessage, onTasksCancelled) that TaskQueue is built on, and the context a handler runs with.
//
// A handler an app registers with task-queue-zig's registry (`worker.registerHandler`, as the TypeScript workers register theirs) runs on the
// runner through `fallbackHandler`, for a task type the app has no entry of its own for. It gets the ITaskContext of task-queue-zig.
// Ziggy depends on task-queue-zig and utils-zig, which are shared packages, and on nothing of any app.
//
// (Zig: a task a handler queues through TaskQueue reaches `addTask` here on the handler's thread, and the runner tells which task is
// running on that thread, which is how the child takes its parent's priority where the Electron pool asks the worker. The callbacks are
// invoked on the thread that ended the task or sent the message, with the backend's lock held, as the contract in task-queue-zig's
// queue-backend.zig says.)
//

const std = @import("std");
const utils = @import("utils-zig");
const task_queue = @import("task-queue-zig");

const types = task_queue.types;
const queue_backend = task_queue.queue_backend;
const worker = task_queue.worker;
const IQueueBackend = queue_backend.IQueueBackend;
const ITaskContext = types.ITaskContext;
const ITaskResult = types.ITaskResult;
const ITaskMessageData = types.ITaskMessageData;
const TaskPriority = types.TaskPriority;
const UnsubscribeFn = types.UnsubscribeFn;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskMessageCallback = types.TaskMessageCallback;
const IMessageCallbackEntry = types.IMessageCallbackEntry;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const task_runner = @import("task-runner.zig");
const ziggy_types = @import("types.zig");

const TaskContext = task_runner.TaskContext;
const TaskRunner = task_runner.TaskRunner;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const TimestampProvider = utils.timestamp_provider.TimestampProvider;
const log = &utils.log.log;

//
// A callback and the key that identifies it for unsubscribing, with the source it was registered for ("" for a callback that is not
// for one source).
//
fn Registration(comptime CallbackT: type) type {
    return struct {
        // Identifies the registration.
        key: usize,

        // The source the callback is for, owned by the backend.
        source: []u8,

        // The callback.
        callback: CallbackT,
    };
}

//
// The backend: Ziggy's runner seen as the IQueueBackend that task-queue code is written against.
//
pub const ZiggyQueueBackend = struct {
    // Allocates the backend's state. It is used from many threads, so it must be thread safe.
    allocator: std.mem.Allocator,

    // For the lock, for the ids of tasks and for the tasks' sleeping and file access.
    io: std.Io,

    // The runner that runs the tasks.
    runner: *TaskRunner,

    // Guards every list below.
    mutex: std.Io.Mutex,

    // The key of the next registration.
    next_key: usize,

    // Callbacks for a task added under a source.
    task_added_callbacks: std.ArrayList(Registration(TaskAddedCallback)),

    // Callbacks for every task that ends.
    completion_callbacks: std.ArrayList(Registration(WorkerTaskCompletionCallback)),

    // Callbacks for the messages of one type.
    message_callbacks: std.ArrayList(Registration(IMessageCallbackEntry)),

    // Callbacks for every message.
    any_message_callbacks: std.ArrayList(Registration(TaskMessageCallback)),

    // Callbacks for the cancelling of a source.
    tasks_cancelled_callbacks: std.ArrayList(Registration(TasksCancelledCallback)),

    // Makes the ids of tasks and the session id.
    uuid_generator: RandomUuidGenerator,

    // Makes the time stamps of task contexts.
    timestamp_provider: TimestampProvider,

    // Identifies this run of the app to the handlers, as `sessionId` of the worker pool options does.
    session_id: []const u8,

    //
    // Makes the backend for a runner. The runner need not be running yet, it is only used once tasks are queued.
    //
    pub fn create(allocator: std.mem.Allocator, io: std.Io, runner: *TaskRunner) !*ZiggyQueueBackend {
        const self = try allocator.create(ZiggyQueueBackend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .runner = runner,
            .mutex = .init,
            .next_key = 0,
            .task_added_callbacks = .empty,
            .completion_callbacks = .empty,
            .message_callbacks = .empty,
            .any_message_callbacks = .empty,
            .tasks_cancelled_callbacks = .empty,
            .uuid_generator = .{},
            .timestamp_provider = .{},
            .session_id = &.{},
        };
        self.session_id = try self.uuid_generator.generate(allocator, io);
        return self;
    }

    //
    // Releases the backend. A registration that was not removed is dropped.
    //
    pub fn destroy(self: *ZiggyQueueBackend) void {
        self.freeList(&self.task_added_callbacks);
        self.freeList(&self.completion_callbacks);
        self.freeList(&self.message_callbacks);
        self.freeList(&self.any_message_callbacks);
        self.freeList(&self.tasks_cancelled_callbacks);
        self.allocator.free(self.session_id);
        self.allocator.destroy(self);
    }

    //
    // Frees the sources a list of registrations owns and the list.
    //
    fn freeList(self: *ZiggyQueueBackend, list: anytype) void {
        for (list.items) |registration| {
            self.allocator.free(registration.source);
        }
        list.deinit(self.allocator);
    }

    //
    // Gets the IQueueBackend interface for this backend.
    //
    pub fn queueBackend(self: *ZiggyQueueBackend) IQueueBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IQueueBackend functions of this backend.
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

    fn lock(self: *ZiggyQueueBackend) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *ZiggyQueueBackend) void {
        self.mutex.unlock(self.io);
    }

    //
    // Adds a task to the runner and returns its id (allocated with the allocator). The callbacks registered for the source are told
    // before the task can start. A task a running task queues runs at the priority it asked for, or at the priority of the task that
    // queued it, or at the default (background) when nothing queued it: the Electron pool's addTaskWithParent.
    //
    pub fn addTask(self: *ZiggyQueueBackend, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) ![]const u8 {
        const id = if (taskId) |given| try allocator.dupe(u8, given) else try self.uuid_generator.generate(allocator, io);
        errdefer allocator.free(id);
        const data_json = try std.json.Stringify.valueAlloc(allocator, data, .{});
        defer allocator.free(data_json);
        const requested: ?task_runner.TaskPriority = if (priority) |given| switch (given) {
            .Interactive => task_runner.TaskPriority.interactive,
            .Background => task_runner.TaskPriority.background,
        } else null;
        const runner_priority = task_runner.resolveTaskPriority(requested, self.runner.priorityOfRunningTask() orelse .background);
        self.lock();
        for (self.task_added_callbacks.items) |registration| {
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call(id);
            }
        }
        self.unlock();
        try self.runner.addTask(id, @"type", source, data_json, runner_priority, null);
        return id;
    }

    //
    // Registers a callback that fires whenever a task with the given source is added.
    //
    pub fn onTaskAdded(self: *ZiggyQueueBackend, source: []const u8, callback: TaskAddedCallback) !UnsubscribeFn {
        return self.register(TaskAddedCallback, &self.task_added_callbacks, source, callback);
    }

    //
    // Registers a callback that fires whenever a task that ran ends.
    //
    pub fn onTaskComplete(self: *ZiggyQueueBackend, callback: WorkerTaskCompletionCallback) !UnsubscribeFn {
        return self.register(WorkerTaskCompletionCallback, &self.completion_callbacks, "", callback);
    }

    //
    // Registers a callback for the messages of one type.
    //
    pub fn onTaskMessage(self: *ZiggyQueueBackend, messageType: []const u8, callback: TaskMessageCallback) !UnsubscribeFn {
        return self.register(IMessageCallbackEntry, &self.message_callbacks, "", .{
            .messageType = messageType,
            .callback = callback,
        });
    }

    //
    // Registers a callback for every message.
    //
    pub fn onAnyTaskMessage(self: *ZiggyQueueBackend, callback: TaskMessageCallback) !UnsubscribeFn {
        return self.register(TaskMessageCallback, &self.any_message_callbacks, "", callback);
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    pub fn onTasksCancelled(self: *ZiggyQueueBackend, source: []const u8, callback: TasksCancelledCallback) !UnsubscribeFn {
        return self.register(TasksCancelledCallback, &self.tasks_cancelled_callbacks, source, callback);
    }

    //
    // Adds a registration to a callback list and returns the function that removes it.
    //
    fn register(self: *ZiggyQueueBackend, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), source: []const u8, callback: CallbackT) !UnsubscribeFn {
        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);
        self.lock();
        defer self.unlock();
        const key = self.next_key;
        self.next_key += 1;
        try list.append(self.allocator, .{
            .key = key,
            .source = source_copy,
            .callback = callback,
        });
        return .{
            .context = self,
            .key = key,
            .function = unregister,
        };
    }

    //
    // Removes the registration with the given key from whichever list holds it. When it returns the callback is not running, because
    // the callbacks are invoked with the lock held.
    //
    fn unregister(context: ?*anyopaque, key: usize) void {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        self.removeKey(TaskAddedCallback, &self.task_added_callbacks, key);
        self.removeKey(WorkerTaskCompletionCallback, &self.completion_callbacks, key);
        self.removeKey(IMessageCallbackEntry, &self.message_callbacks, key);
        self.removeKey(TaskMessageCallback, &self.any_message_callbacks, key);
        self.removeKey(TasksCancelledCallback, &self.tasks_cancelled_callbacks, key);
    }

    //
    // Removes the registration with the given key from a list, if it is there.
    //
    fn removeKey(self: *ZiggyQueueBackend, comptime CallbackT: type, list: *std.ArrayList(Registration(CallbackT)), key: usize) void {
        for (list.items, 0..) |registration, index| {
            if (registration.key == key) {
                self.allocator.free(registration.source);
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    //
    // Drops the queued tasks with the given source, tells the running ones to stop, and fires the callbacks registered for the source.
    // (The page is told of each queued task that was dropped, as a cancelled completion, which the Electron pool did not do.)
    //
    pub fn cancelTasks(self: *ZiggyQueueBackend, source: []const u8) void {
        self.runner.cancelSource(source);
        self.lock();
        defer self.unlock();
        for (self.tasks_cancelled_callbacks.items) |registration| {
            if (std.mem.eql(u8, registration.source, source)) {
                registration.callback.call();
            }
        }
    }

    //
    // Does nothing: the core stops the runner when it is destroyed.
    //
    pub fn shutdown(self: *ZiggyQueueBackend) void {
        _ = self;
    }

    //
    // A task ended: tells the completion callbacks, as the Electron pool does when a worker reports a task completed. A task that was
    // cancelled while it waited never reached a worker, and the Electron pool dropped it without a word, so it is not reported.
    //
    pub fn taskEnded(self: *ZiggyQueueBackend, end: ziggy_types.TaskEnd) void {
        if (!end.started) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const inputs = std.json.parseFromSliceLeaky(std.json.Value, arena, end.input_json, .{}) catch |err| {
            log.exception("Error reading the input of a task that ended", err);
            return;
        };
        var result: ITaskResult = .{
            .taskId = end.task_id,
            .status = .Succeeded,
            .type = end.task_type,
            .inputs = inputs,
        };
        switch (end.status) {
            .succeeded => {
                if (end.result_json) |text| {
                    result.outputs = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| {
                        log.exception("Error reading the result of a task that ended", err);
                        return;
                    };
                }
            },
            .failed, .cancelled => {
                const message = if (end.status == .cancelled) "Cancelled" else end.error_message orelse "Unknown error";
                result.status = .Failed;
                result.errorMessage = message;
                result.@"error" = .{
                    .name = "Error",
                    .message = message,
                };
            },
        }
        self.lock();
        defer self.unlock();
        for (self.completion_callbacks.items) |registration| {
            registration.callback.call(result) catch |err| {
                // Don't let callback errors break the task queue.
                log.exception("Error in task completion callback", err);
            };
        }
    }

    //
    // A task sent a message: tells the callbacks for its type and the callbacks for every message.
    //
    pub fn messageSent(self: *ZiggyQueueBackend, sent: ziggy_types.TaskSentMessage) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const message = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), sent.message_json, .{}) catch |err| {
            log.exception("Error reading a message a task sent", err);
            return;
        };
        const message_type = types.messageTypeOf(message);
        const data: ITaskMessageData = .{
            .taskId = sent.task_id,
            .message = message,
        };
        self.lock();
        defer self.unlock();
        for (self.message_callbacks.items) |registration| {
            const wanted = message_type orelse {
                continue;
            };
            if (!std.mem.eql(u8, wanted, registration.callback.messageType)) {
                continue;
            }
            registration.callback.callback.call(data) catch |err| {
                log.exception("Error in task message callback", err);
            };
        }
        for (self.any_message_callbacks.items) |registration| {
            registration.callback.call(data) catch |err| {
                log.exception("Error in any task message callback", err);
            };
        }
    }

    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        return self.addTask(allocator, io, @"type", data, source, taskId, priority);
    }

    fn onTaskAddedErased(ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTaskAdded(source, callback);
    }

    fn onTaskCompleteErased(ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTaskComplete(callback);
    }

    fn onTaskMessageErased(ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTaskMessage(messageType, callback);
    }

    fn onAnyTaskMessageErased(ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onAnyTaskMessage(callback);
    }

    fn cancelTasksErased(ptr: *anyopaque, source: []const u8) void {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        self.cancelTasks(source);
    }

    fn onTasksCancelledErased(ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        return self.onTasksCancelled(source, callback);
    }

    fn shutdownErased(ptr: *anyopaque) void {
        const self: *ZiggyQueueBackend = @ptrCast(@alignCast(ptr));
        self.shutdown();
    }
};

//
// What a handler's ITaskContext reaches: the Ziggy context of the task it runs in.
//
const ContextBridge = struct {
    // The task's context in Ziggy's runner.
    context: *TaskContext,

    const vtable: ITaskContext.VTable = .{
        .sendMessage = sendMessageErased,
        .isCancelled = isCancelledErased,
    };

    //
    // Sends a message to the page and to the observers of the backend.
    //
    fn sendMessageErased(ptr: *anyopaque, message: std.json.Value) void {
        const self: *ContextBridge = @ptrCast(@alignCast(ptr));
        self.context.sendMessage(message) catch |err| {
            log.exception("Error sending a task message", err);
        };
    }

    //
    // Whether the task's source has been cancelled.
    //
    fn isCancelledErased(ptr: *anyopaque) bool {
        const self: *ContextBridge = @ptrCast(@alignCast(ptr));
        return self.context.isCancelled();
    }
};

//
// The runner's way to a handler registered with task-queue-zig: it asks whether one is registered for a task type, and runs it.
//
pub fn fallbackHandler(self: *ZiggyQueueBackend) task_runner.FallbackHandler {
    return .{
        .user_data = self,
        .handles = handlesTaskType,
        .run = runRegisteredHandler,
    };
}

//
// Whether a handler is registered with task-queue-zig for the task type.
//
fn handlesTaskType(user_data: ?*anyopaque, task_type: []const u8) bool {
    _ = user_data;
    return worker.getHandler(task_type) != null;
}

//
// Runs the handler registered for the task's type, with the context those handlers expect, and returns its outputs as JSON text.
// A handler that fails gives the error it returned, with the message it recorded (task-queue-zig's throwError), which the app's
// describe_error gives to the page.
//
fn runRegisteredHandler(user_data: ?*anyopaque, context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const backend: *ZiggyQueueBackend = @ptrCast(@alignCast(user_data.?));
    var bridge: ContextBridge = .{
        .context = context,
    };
    const task_context: ITaskContext = .{
        .uuidGenerator = backend.uuid_generator.uuidGenerator(),
        .timestampProvider = backend.timestamp_provider.timestampProvider(),
        .sessionId = backend.session_id,
        .taskId = context.taskId(),
        .maxConcurrentChildTasks = context.maxConcurrentChildTasks(),
        .ptr = &bridge,
        .vtable = &ContextBridge.vtable,
    };
    const outputs = try worker.executeTaskHandler(context.arena, context.io(), context.taskType(), data, task_context);
    return try std.json.Stringify.valueAlloc(context.arena, outputs, .{});
}

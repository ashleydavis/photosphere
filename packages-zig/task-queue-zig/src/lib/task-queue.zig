const std = @import("std");
const utils = @import("utils-zig");
const types = @import("types.zig");
const queue_backend = @import("queue-backend.zig");
const ITaskResult = types.ITaskResult;
const ITaskMessageData = types.ITaskMessageData;
const TaskMessageCallback = types.TaskMessageCallback;
const TaskCompletionCallback = types.TaskCompletionCallback;
const IMessageCallbackEntry = types.IMessageCallbackEntry;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskPriority = types.TaskPriority;
const IQueueBackend = queue_backend.IQueueBackend;
const getQueueBackend = queue_backend.getQueueBackend;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const log = &utils.log.log;

// Not ported: ITaskQueue (TaskQueue is its only implementation; Zig callers use TaskQueue directly).

//
// Thread-safe allocator for the queue's internal state, which backend callbacks update from worker
// threads (the queue's own allocator may be an arena that is not thread-safe).
//
const transit_allocator = std.heap.smp_allocator;

//
// The kind of an event delivered by the backend.
//
const QueueEventKind = enum {
    // A tracked task completed (the event holds an ITaskResult).
    completed,

    // A tracked task sent a message (the event holds an ITaskMessageData).
    message,
};

//
// An event delivered by the backend (on any thread) and waiting to be dispatched to the queue's
// callbacks by a thread blocked in awaitAllTasks or awaitTask. This stands in for the JavaScript event
// loop: like in TypeScript, callbacks run one at a time while the owner of the queue awaits.
//
const IQueueEvent = struct {
    // Whether the event is a completion or a message.
    kind: QueueEventKind,

    // The ITaskResult or ITaskMessageData serialized to JSON (allocated with transit_allocator), so
    // that the event does not depend on memory owned by the backend.
    json: []u8,
};

//
// A caller blocked in awaitAllTasks (TypeScript: the resolve function of the returned promise).
//
const IAwaitAllResolver = struct {
    // Set when the caller can return.
    resolved: bool,
};

//
// A caller blocked in awaitTask (TypeScript: the resolve function of the returned promise).
//
const IAwaitTaskResolver = struct {
    // The task the caller waits for.
    taskId: []const u8,

    // Allocator for the copy of the result handed to the caller.
    allocator: std.mem.Allocator,

    // The result of the task, or null when the queue was shut down or its tasks were cancelled.
    result: ?ITaskResult,

    // The error that prevented copying the result, if any.
    copyError: ?anyerror,

    // Set when the caller can return.
    resolved: bool,
};

//
// A completion callback with the key that identifies it for unsubscribing.
//
const ICompletionCallbackRegistration = struct {
    // Identifies the registration.
    key: usize,

    // The callback.
    callback: TaskCompletionCallback,
};

//
// A message callback entry with the key that identifies it for unsubscribing.
//
const IMessageCallbackRegistration = struct {
    // Identifies the registration.
    key: usize,

    // The message type filter (owned by the queue) and the callback.
    entry: IMessageCallbackEntry,
};

//
// Generic task queue implementation with an abstraction for workers.
//
// Zig threading model: the backend reports completions and messages from any thread. They are queued
// and the registered callbacks run on the thread that is blocked in awaitAllTasks or awaitTask (one
// callback at a time), like the JavaScript event loop running callbacks while the caller awaits.
// Values passed to callbacks are only valid during the call.
//
pub const TaskQueue = struct {
    //
    // Allocator for the queue itself, generated task IDs and the results returned by awaitTask
    // (used on the threads that call addTask and awaitTask).
    //
    allocator: std.mem.Allocator,

    //
    // Io for locking and waiting.
    //
    io: std.Io,

    //
    // Generates unique IDs for tasks added via addTask.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Source tag used to identify all tasks owned by this queue instance.
    // Used for filtering completions and for cancellation via shutdown().
    //
    source: []const u8,

    //
    // The underlying backend that executes tasks (worker pool or IPC proxy).
    //
    backend: IQueueBackend,

    //
    // Callbacks invoked whenever a tracked task completes (success or failure).
    //
    completionCallbacks: std.ArrayList(ICompletionCallbackRegistration),

    //
    // Callbacks invoked when a tracked task emits a message of a specific type.
    //
    messageCallbacks: std.ArrayList(IMessageCallbackRegistration),

    // Not ported: anyMessageCallbacks (TaskQueue.onAnyTaskMessage is not used by psi replicate or psi verify).

    //
    // Count of tasks that have been added but not yet completed.
    //
    numTasksInFlight: i64,

    //
    // Set of task IDs owned by this queue, used to filter backend callbacks.
    //
    trackedTaskIds: std.StringHashMapUnmanaged(void),

    //
    // Callers blocked in awaitAllTasks(), resolved when numTasksInFlight reaches zero.
    //
    awaitAllResolvers: std.ArrayList(*IAwaitAllResolver),

    //
    // Callers blocked in awaitTask(taskId). A resolver receives the task's ITaskResult on normal
    // completion, or null when the queue is shut down before the task completes.
    // (TypeScript keys them by task ID in a Map; the list is searched by task ID.)
    //
    awaitTaskResolvers: std.ArrayList(*IAwaitTaskResolver),

    //
    // Unsubscribe functions returned by backend subscriptions, called on shutdown.
    //
    unsubscribeFunctions: std.ArrayList(UnsubscribeFn),

    //
    // Guards every field that backend callbacks or other threads can reach.
    //
    mutex: std.Io.Mutex,

    //
    // Signalled when an event arrives or a waiter is resolved.
    //
    condition: std.Io.Condition,

    //
    // Events delivered by the backend that have not been dispatched yet (a FIFO: the first
    // pendingEventsHead items have been taken already).
    //
    pendingEvents: std.ArrayList(IQueueEvent),

    //
    // Index of the next event of pendingEvents to dispatch.
    //
    pendingEventsHead: usize,

    //
    // True while a thread is dispatching an event (callbacks never run concurrently).
    //
    isDispatching: bool,

    //
    // The key of the next callback registration.
    //
    nextCallbackKey: usize,

    //
    // Whether shutdown has run, so that deinit does not cancel the tasks of the source a second time.
    // (No TypeScript counterpart: deinit has none.)
    //
    isShutDown: bool,

    //
    // Creates a queue for the tasks of `source` on the backend registered with setQueueBackend
    // (TypeScript: constructor(uuidGenerator, source)). Free it with deinit.
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, uuidGenerator: IUuidGenerator, source: []const u8) !*TaskQueue {
        const backend = try getQueueBackend();
        const self = try allocator.create(TaskQueue);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .uuidGenerator = uuidGenerator,
            .source = try transit_allocator.dupe(u8, source),
            .backend = backend,
            .completionCallbacks = .empty,
            .messageCallbacks = .empty,
            .numTasksInFlight = 0,
            .trackedTaskIds = .empty,
            .awaitAllResolvers = .empty,
            .awaitTaskResolvers = .empty,
            .unsubscribeFunctions = .empty,
            .mutex = .init,
            .condition = .init,
            .pendingEvents = .empty,
            .pendingEventsHead = 0,
            .isDispatching = false,
            .nextCallbackKey = 0,
            .isShutDown = false,
        };
        errdefer self.deinit();
        try self.unsubscribeFunctions.append(transit_allocator, try self.backend.onTaskAdded(self.source, .{
            .context = self,
            .function = onBackendTaskAdded,
        }));
        try self.unsubscribeFunctions.append(transit_allocator, try self.backend.onTaskComplete(.{
            .context = self,
            .function = onBackendTaskComplete,
        }));
        try self.unsubscribeFunctions.append(transit_allocator, try self.backend.onAnyTaskMessage(.{
            .context = self,
            .function = onBackendAnyTaskMessage,
        }));
        try self.unsubscribeFunctions.append(transit_allocator, try self.backend.onTasksCancelled(self.source, .{
            .context = self,
            .function = onBackendTasksCancelled,
        }));
        return self;
    }

    //
    // Shuts the queue down (if it is not already) and frees it. This has no TypeScript counterpart
    // (garbage collection frees the TypeScript object).
    //
    pub fn deinit(self: *TaskQueue) void {
        if (!self.isShutDown) {
            self.shutdown();
        }
        self.completionCallbacks.deinit(transit_allocator);
        self.messageCallbacks.deinit(transit_allocator);
        self.trackedTaskIds.deinit(transit_allocator);
        self.awaitAllResolvers.deinit(transit_allocator);
        self.awaitTaskResolvers.deinit(transit_allocator);
        self.unsubscribeFunctions.deinit(transit_allocator);
        self.pendingEvents.deinit(transit_allocator);
        transit_allocator.free(self.source);
        self.allocator.destroy(self);
    }

    //
    // Locks the queue's state.
    //
    fn lock(self: *TaskQueue) void {
        self.mutex.lockUncancelable(self.io);
    }

    //
    // Unlocks the queue's state.
    //
    fn unlock(self: *TaskQueue) void {
        self.mutex.unlock(self.io);
    }

    //
    // Backend callback: a task with this queue's source was added (TypeScript: the onTaskAdded arrow function).
    //
    fn onBackendTaskAdded(context: ?*anyopaque, taskId: []const u8) void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        const entry = self.trackedTaskIds.getOrPut(transit_allocator, taskId) catch |err| {
            log.exception("Failed to track task", err);
            return;
        };
        if (!entry.found_existing) {
            entry.key_ptr.* = transit_allocator.dupe(u8, taskId) catch |err| {
                _ = self.trackedTaskIds.remove(taskId);
                log.exception("Failed to track task", err);
                return;
            };
        }
        self.numTasksInFlight += 1;
    }

    //
    // Backend callback: a task completed (TypeScript: the onTaskComplete arrow function).
    // Results of tracked tasks are queued for dispatch.
    //
    fn onBackendTaskComplete(context: ?*anyopaque, result: ITaskResult) anyerror!void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        if (!self.trackedTaskIds.contains(result.taskId)) {
            return;
        }
        try self.queueEvent(.completed, result);
    }

    //
    // Backend callback: a task sent a message (TypeScript: the onAnyTaskMessage arrow function).
    // Messages of tracked tasks are queued for dispatch.
    //
    fn onBackendAnyTaskMessage(context: ?*anyopaque, message: ITaskMessageData) anyerror!void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        if (!self.trackedTaskIds.contains(message.taskId)) {
            return;
        }
        try self.queueEvent(.message, message);
    }

    //
    // Backend callback: the tasks of this queue's source were cancelled (TypeScript: the onTasksCancelled arrow function).
    //
    fn onBackendTasksCancelled(context: ?*anyopaque) void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        self.resolveAllWaiters();
    }

    //
    // Serializes a backend event and queues it for dispatch (the lock must be held).
    //
    fn queueEvent(self: *TaskQueue, kind: QueueEventKind, payload: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(transit_allocator, payload, .{});
        errdefer transit_allocator.free(json);
        try self.pendingEvents.append(transit_allocator, .{ .kind = kind, .json = json });
        self.condition.broadcast(self.io);
    }

    //
    // Resolves all pending awaitAllTasks() and awaitTask() callers immediately (the lock must be held).
    //
    fn resolveAllWaiters(self: *TaskQueue) void {
        for (self.awaitAllResolvers.items) |resolver| {
            resolver.resolved = true;
        }
        self.awaitAllResolvers.clearRetainingCapacity();

        for (self.awaitTaskResolvers.items) |resolver| {
            resolver.result = null;
            resolver.resolved = true;
        }
        self.awaitTaskResolvers.clearRetainingCapacity();
        self.condition.broadcast(self.io);
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID).
    // If taskId is provided (and not empty), it will be used instead of generating a new one.
    //
    pub fn addTask(self: *TaskQueue, @"type": []const u8, data: std.json.Value, taskId: ?[]const u8, priority: ?TaskPriority) ![]const u8 {
        const id = if (taskId != null and taskId.?.len > 0) taskId.? else try self.uuidGenerator.generate(self.allocator, self.io);
        _ = try self.backend.addTask(self.allocator, self.io, @"type", data, self.source, id, priority);
        return id;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    // Returns an unsubscribe function to remove the callback.
    //
    pub fn onTaskComplete(self: *TaskQueue, callback: TaskCompletionCallback) !UnsubscribeFn {
        self.lock();
        defer self.unlock();
        const key = self.nextCallbackKey;
        self.nextCallbackKey += 1;
        try self.completionCallbacks.append(transit_allocator, .{ .key = key, .callback = callback });
        return .{ .context = self, .key = key, .function = unsubscribeCompletionCallback };
    }

    //
    // Removes a completion callback (the function returned by onTaskComplete).
    //
    fn unsubscribeCompletionCallback(context: ?*anyopaque, key: usize) void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        for (self.completionCallbacks.items, 0..) |registration, index| {
            if (registration.key == key) {
                _ = self.completionCallbacks.orderedRemove(index);
                return;
            }
        }
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // Only messages with the specified messageType will be passed to the callback.
    // Returns an unsubscribe function to remove the callback.
    //
    pub fn onTaskMessage(self: *TaskQueue, messageType: []const u8, callback: TaskMessageCallback) !UnsubscribeFn {
        const owned_message_type = try transit_allocator.dupe(u8, messageType);
        errdefer transit_allocator.free(owned_message_type);
        self.lock();
        defer self.unlock();
        const key = self.nextCallbackKey;
        self.nextCallbackKey += 1;
        try self.messageCallbacks.append(transit_allocator, .{
            .key = key,
            .entry = .{ .messageType = owned_message_type, .callback = callback },
        });
        return .{ .context = self, .key = key, .function = unsubscribeMessageCallback };
    }

    //
    // Removes a message callback (the function returned by onTaskMessage).
    //
    fn unsubscribeMessageCallback(context: ?*anyopaque, key: usize) void {
        const self: *TaskQueue = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        for (self.messageCallbacks.items, 0..) |registration, index| {
            if (registration.key == key) {
                transit_allocator.free(registration.entry.messageType);
                _ = self.messageCallbacks.orderedRemove(index);
                return;
            }
        }
    }

    // Not ported: onAnyTaskMessage (not used by psi replicate or psi verify).

    //
    // Returns when all currently in-flight tasks have completed, running the queue's callbacks
    // for the completions and messages that arrive meanwhile.
    // Returns immediately if no tasks are in flight.
    //
    pub fn awaitAllTasks(self: *TaskQueue) !void {
        self.lock();
        defer self.unlock();
        if (self.numTasksInFlight <= 0) {
            return;
        }
        var resolver: IAwaitAllResolver = .{ .resolved = false };
        try self.awaitAllResolvers.append(transit_allocator, &resolver);
        self.waitUntilResolved(&resolver.resolved);
    }

    //
    // Returns the task's result when the task with the given ID completes (allocated with the
    // queue's allocator), running the queue's callbacks meanwhile.
    // Returns null when the task ID is not tracked by this queue,
    // or when the queue is shut down / its tasks are cancelled before completion.
    //
    pub fn awaitTask(self: *TaskQueue, taskId: []const u8) !?ITaskResult {
        self.lock();
        defer self.unlock();
        if (!self.trackedTaskIds.contains(taskId)) {
            return null;
        }
        var resolver: IAwaitTaskResolver = .{
            .taskId = taskId,
            .allocator = self.allocator,
            .result = null,
            .copyError = null,
            .resolved = false,
        };
        try self.awaitTaskResolvers.append(transit_allocator, &resolver);
        self.waitUntilResolved(&resolver.resolved);
        if (resolver.copyError) |err| {
            return err;
        }
        return resolver.result;
    }

    //
    // Dispatches queued events until `resolved` is set, waiting for events when there are none
    // (the lock must be held; it is released while callbacks run and while waiting).
    //
    fn waitUntilResolved(self: *TaskQueue, resolved: *bool) void {
        while (!resolved.*) {
            if (!self.isDispatching and self.pendingEventsHead < self.pendingEvents.items.len) {
                const event = self.pendingEvents.items[self.pendingEventsHead];
                self.pendingEventsHead += 1;
                if (self.pendingEventsHead == self.pendingEvents.items.len) {
                    self.pendingEvents.clearRetainingCapacity();
                    self.pendingEventsHead = 0;
                }
                self.isDispatching = true;
                self.unlock();
                self.dispatchEvent(event);
                transit_allocator.free(event.json);
                self.lock();
                self.isDispatching = false;
                self.condition.broadcast(self.io);
                continue;
            }
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    //
    // Runs the callbacks for one queued event (the lock must not be held).
    //
    fn dispatchEvent(self: *TaskQueue, event: IQueueEvent) void {
        var scratch = std.heap.ArenaAllocator.init(transit_allocator);
        defer scratch.deinit();
        const scratch_allocator = scratch.allocator();
        switch (event.kind) {
            .completed => {
                const result = std.json.parseFromSliceLeaky(ITaskResult, scratch_allocator, event.json, .{ .allocate = .alloc_always }) catch |err| {
                    log.exception("Failed to read task result", err);
                    return;
                };
                self.notifyCompletionCallbacks(scratch_allocator, result, event.json);
            },
            .message => {
                const message = std.json.parseFromSliceLeaky(ITaskMessageData, scratch_allocator, event.json, .{ .allocate = .alloc_always }) catch |err| {
                    log.exception("Failed to read task message", err);
                    return;
                };
                self.notifyMessageCallbacks(scratch_allocator, message.taskId, message.message);
            },
        }
    }

    //
    // Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // `scratchAllocator` holds the result for the duration of the callbacks; `resultJson` is the
    // serialized result, parsed again for each awaitTask caller into that caller's allocator.
    //
    fn notifyCompletionCallbacks(self: *TaskQueue, scratchAllocator: std.mem.Allocator, result: ITaskResult, resultJson: []const u8) void {
        self.lock();
        if (self.trackedTaskIds.fetchRemove(result.taskId)) |removed| {
            transit_allocator.free(removed.key);
        }
        self.numTasksInFlight -= 1;
        const callbacks = scratchAllocator.dupe(ICompletionCallbackRegistration, self.completionCallbacks.items) catch &.{};
        self.unlock();

        for (callbacks) |registration| {
            registration.callback.call(result) catch |err| {
                log.exception("Error in task completion callback", err);
            };
        }

        self.lock();
        defer self.unlock();

        // Resolve awaitTask waiters for this task ID.
        var index: usize = 0;
        while (index < self.awaitTaskResolvers.items.len) {
            const resolver = self.awaitTaskResolvers.items[index];
            if (!std.mem.eql(u8, resolver.taskId, result.taskId)) {
                index += 1;
                continue;
            }
            if (std.json.parseFromSliceLeaky(ITaskResult, resolver.allocator, resultJson, .{ .allocate = .alloc_always })) |copied_result| {
                resolver.result = copied_result;
            }
            else |err| {
                resolver.copyError = err;
            }
            resolver.resolved = true;
            _ = self.awaitTaskResolvers.orderedRemove(index);
        }

        // Resolve awaitAll waiters if all tasks are done.
        if (self.numTasksInFlight <= 0) {
            for (self.awaitAllResolvers.items) |resolver| {
                resolver.resolved = true;
            }
            self.awaitAllResolvers.clearRetainingCapacity();
        }
        self.condition.broadcast(self.io);
    }

    //
    // Invokes all registered message callbacks with the task message.
    // Only callbacks that match the message type will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    fn notifyMessageCallbacks(self: *TaskQueue, scratchAllocator: std.mem.Allocator, taskId: []const u8, message: std.json.Value) void {
        const messageType = types.messageTypeOf(message);

        self.lock();
        var callbacks: std.ArrayList(TaskMessageCallback) = .empty;
        for (self.messageCallbacks.items) |registration| {
            if (messageType == null or !std.mem.eql(u8, messageType.?, registration.entry.messageType)) {
                continue;
            }
            callbacks.append(scratchAllocator, registration.entry.callback) catch {};
        }
        self.unlock();

        for (callbacks.items) |callback| {
            callback.call(.{ .taskId = taskId, .message = message }) catch |err| {
                log.exception("Error in task message callback", err);
            };
        }

        // Not ported: anyMessageCallbacks (TaskQueue.onAnyTaskMessage is not used by psi replicate or psi verify).
    }

    //
    // Cancels all in-flight tasks belonging to this queue and cleans up subscriptions.
    // Any callers blocked in awaitAllTasks() or awaitTask() are resolved immediately.
    // (Zig also drops the events that were delivered but not dispatched yet.)
    //
    pub fn shutdown(self: *TaskQueue) void {
        self.isShutDown = true;
        self.backend.cancelTasks(self.source);

        self.lock();
        const unsubscribeFunctions = self.unsubscribeFunctions;
        self.unsubscribeFunctions = .empty;
        self.unlock();
        for (unsubscribeFunctions.items) |unsubscribe| {
            unsubscribe.call();
        }
        var owned_unsubscribe_functions = unsubscribeFunctions;
        owned_unsubscribe_functions.deinit(transit_allocator);

        self.lock();
        defer self.unlock();

        var tracked_iterator = self.trackedTaskIds.keyIterator();
        while (tracked_iterator.next()) |key| {
            transit_allocator.free(key.*);
        }
        self.trackedTaskIds.clearRetainingCapacity();
        self.resolveAllWaiters();
        for (self.messageCallbacks.items) |registration| {
            transit_allocator.free(registration.entry.messageType);
        }
        self.messageCallbacks.clearRetainingCapacity();
        self.completionCallbacks.clearRetainingCapacity();

        for (self.pendingEvents.items[self.pendingEventsHead..]) |event| {
            transit_allocator.free(event.json);
        }
        self.pendingEvents.clearRetainingCapacity();
        self.pendingEventsHead = 0;
    }
};

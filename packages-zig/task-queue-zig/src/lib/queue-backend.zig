//
// IQueueBackend: the interface that all task scheduling backends implement.
// Real worker pools (WorkerPoolBun, WorkerPoolElectronMain, WorkerPoolInline) and
// IPC/WebSocket proxies (ElectronQueueBackend, WebSocketQueueBackend) implement this.
// TaskQueue depends only on IQueueBackend; concrete backend classes are registered once
// at process startup via setQueueBackend().
//
// Threading contract of the Zig port (TypeScript backends run on one event loop):
// - Every method may be called from any thread.
// - Callbacks may be invoked from any thread (e.g. a worker thread when a task completes), but the
//   callbacks registered for a task added with addTask must fire before that task can start running
//   (TaskQueue relies on onTaskAdded being called synchronously from addTask, as in TypeScript).
// - After an UnsubscribeFn returns, the backend must not invoke that callback again, and no invocation of
//   it may still be running (TaskQueue frees its state after unsubscribing). A backend may hold its own
//   lock while invoking callbacks: the callbacks registered by TaskQueue never call back into the backend.
// - Values passed to callbacks only have to stay valid during the call.
//

const std = @import("std");
const utils = @import("utils-zig");
const types = @import("types.zig");
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;
const TaskMessageCallback = types.TaskMessageCallback;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskAddedCallback = types.TaskAddedCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const TaskPriority = types.TaskPriority;
const errors = utils.errors;

//
// The interface implemented by all queue backends.
// Worker pools implement this plus IWorkerPool. IPC/WebSocket proxies implement only this.
//
pub const IQueueBackend = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IQueueBackend provides (same names as the TypeScript interface).
    //
    pub const VTable = struct {
        // Adds a task to the backend. Returns the task ID (allocated with allocator).
        addTask: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8,

        // Registers a callback that fires whenever a task with the given source is added.
        onTaskAdded: *const fn (ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn,

        // Registers a callback that fires when any task completes (success or failure).
        onTaskComplete: *const fn (ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn,

        // Registers a callback for task messages of a specific type.
        onTaskMessage: *const fn (ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn,

        // Registers a callback for every task message regardless of type.
        onAnyTaskMessage: *const fn (ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn,

        // Signals running tasks with the given source to cancel and drops pending tasks with that source.
        cancelTasks: *const fn (ptr: *anyopaque, source: []const u8) void,

        // Registers a callback that fires when cancelTasks is called for the given source.
        onTasksCancelled: *const fn (ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn,

        // Shuts down the backend, releasing all resources.
        shutdown: *const fn (ptr: *anyopaque) void,
    };

    //
    // Adds a task to the backend. Returns the task ID.
    // If taskId is provided it is used instead of generating a new one.
    //
    // The priority decides which pending task is dispatched next. Leaving it out means "whatever is
    // right for this task": a task queued from inside a running task runs at its parent's priority,
    // so an import's children can never overtake something the user is waiting on, and anything else
    // runs at DEFAULT_TASK_PRIORITY. Pass it explicitly to say the user is waiting (Interactive), or
    // to opt a child back down to Background when it is long-running work its parent only kicked off.
    //
    // The backend copies `data` (it only has to be valid during the call).
    //
    pub fn addTask(self: IQueueBackend, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        return self.vtable.addTask(self.ptr, allocator, io, @"type", data, source, taskId, priority);
    }

    //
    // Registers a callback that fires whenever a task with the given source is added.
    // Returns an unsubscribe function.
    //
    pub fn onTaskAdded(self: IQueueBackend, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTaskAdded(self.ptr, source, callback);
    }

    //
    // Registers a callback that fires when any task completes (success or failure).
    // Returns an unsubscribe function.
    //
    pub fn onTaskComplete(self: IQueueBackend, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTaskComplete(self.ptr, callback);
    }

    //
    // Registers a callback for task messages of a specific type.
    // Returns an unsubscribe function.
    //
    pub fn onTaskMessage(self: IQueueBackend, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTaskMessage(self.ptr, messageType, callback);
    }

    //
    // Registers a callback for every task message regardless of type.
    // Returns an unsubscribe function.
    //
    pub fn onAnyTaskMessage(self: IQueueBackend, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        return self.vtable.onAnyTaskMessage(self.ptr, callback);
    }

    //
    // Signals running tasks with the given source to cancel and drops any pending
    // tasks with that source from the queue.
    //
    pub fn cancelTasks(self: IQueueBackend, source: []const u8) void {
        self.vtable.cancelTasks(self.ptr, source);
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    // Returns an unsubscribe function.
    //
    pub fn onTasksCancelled(self: IQueueBackend, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        return self.vtable.onTasksCancelled(self.ptr, source, callback);
    }

    //
    // Shuts down the backend, releasing all resources.
    //
    pub fn shutdown(self: IQueueBackend) void {
        self.vtable.shutdown(self.ptr);
    }
};

//
// The process-level singleton backend. Set once at startup via setQueueBackend().
//
var _backend: ?IQueueBackend = null;

//
// Registers the process-level singleton queue backend.
// Must be called once at process startup before any TaskQueue is created.
// (Zig takes an optional so that tests can clear it; TypeScript tests pass `undefined as any`.)
//
pub fn setQueueBackend(backend: ?IQueueBackend) void {
    _backend = backend;
}

//
// Returns the process-level singleton queue backend.
// Throws if setQueueBackend() has not been called.
//
pub fn getQueueBackend() !IQueueBackend {
    if (_backend) |backend| {
        return backend;
    }
    return errors.throwError("Queue backend not initialised \u{2014} call setQueueBackend() at process startup.", .{});
}

const std = @import("std");
const task_queue_zig = @import("ziggy-core").task_queue;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const TaskPriority = task_queue_zig.types.TaskPriority;
const UnsubscribeFn = task_queue_zig.types.UnsubscribeFn;
const TaskAddedCallback = task_queue_zig.types.TaskAddedCallback;
const TasksCancelledCallback = task_queue_zig.types.TasksCancelledCallback;
const WorkerTaskCompletionCallback = task_queue_zig.types.WorkerTaskCompletionCallback;
const TaskMessageCallback = task_queue_zig.types.TaskMessageCallback;

//
// What one call to addTask was given, so a test can assert on the priority it asked for.
//
pub const IRecordedTask = struct {
    // The handler name.
    type: []const u8,

    // The priority asked for, or null when none was named.
    priority: ?TaskPriority,
};

//
// A queue backend that records what it was asked to add and never completes anything. A handler that queues a task and does not wait for it needs nothing more. The backend
// must outlive every queue created on it.
//
pub const RecordingQueueBackend = struct {
    // Owns the recorded tasks.
    allocator: std.mem.Allocator,

    // Every task added through this backend, in order.
    addedTasks: std.ArrayList(IRecordedTask),

    //
    // Creates the backend.
    //
    pub fn init(allocator: std.mem.Allocator) RecordingQueueBackend {
        return .{
            .allocator = allocator,
            .addedTasks = .empty,
        };
    }

    //
    // Gets the IQueueBackend interface of this backend.
    //
    pub fn queueBackend(self: *RecordingQueueBackend) IQueueBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // How many of the added tasks are of the given type.
    //
    pub fn countOfType(self: *RecordingQueueBackend, taskType: []const u8) usize {
        var count: usize = 0;
        for (self.addedTasks.items) |task| {
            if (std.mem.eql(u8, task.type, taskType)) {
                count += 1;
            }
        }
        return count;
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
    // Records the task.
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, taskType: []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        _ = io;
        _ = data;
        _ = source;
        const self: *RecordingQueueBackend = @ptrCast(@alignCast(ptr));
        try self.addedTasks.append(self.allocator, .{
            .type = try self.allocator.dupe(u8, taskType),
            .priority = priority,
        });
        return allocator.dupe(u8, taskId orelse "generated-id");
    }

    //
    // Nothing is subscribed.
    //
    fn onTaskAdded(ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return nothingSubscribed();
    }

    //
    // Nothing is subscribed.
    //
    fn onTaskComplete(ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return nothingSubscribed();
    }

    //
    // Nothing is subscribed.
    //
    fn onTaskMessage(ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = messageType;
        _ = callback;
        return nothingSubscribed();
    }

    //
    // Nothing is subscribed.
    //
    fn onAnyTaskMessage(ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return nothingSubscribed();
    }

    //
    // Nothing to cancel, because nothing runs.
    //
    fn cancelTasks(ptr: *anyopaque, source: []const u8) void {
        _ = ptr;
        _ = source;
    }

    //
    // Nothing is subscribed.
    //
    fn onTasksCancelled(ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return nothingSubscribed();
    }

    //
    // Nothing to shut down.
    //
    fn shutdown(ptr: *anyopaque) void {
        _ = ptr;
    }

    //
    // The unsubscribe function of a subscription that was never made.
    //
    fn nothingSubscribed() UnsubscribeFn {
        return .{
            .context = null,
            .key = 0,
            .function = ignoreUnsubscribe,
        };
    }

    //
    // Does nothing, because nothing was subscribed.
    //
    fn ignoreUnsubscribe(context: ?*anyopaque, key: usize) void {
        _ = context;
        _ = key;
    }
};

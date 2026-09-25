const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const queue_backend = task_queue_zig.queue_backend;
const types = task_queue_zig.types;
const IQueueBackend = queue_backend.IQueueBackend;
const setQueueBackend = queue_backend.setQueueBackend;
const getQueueBackend = queue_backend.getQueueBackend;
const errors = utils.errors;

//
// Minimal no-op backend for testing the singleton helpers.
//
const NoOpBackend = struct {
    // Unused. Present because an IQueueBackend must point at a value with an address.
    unused: u8,

    //
    // Gets the IQueueBackend interface for this backend.
    //
    fn queueBackend(self: *NoOpBackend) IQueueBackend {
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
    // Returns "task-id".
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, @"type": []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?types.TaskPriority) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = @"type";
        _ = data;
        _ = source;
        _ = taskId;
        _ = priority;
        return "task-id";
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
        _ = ptr;
        _ = source;
        _ = callback;
        return no_unsubscribe;
    }

    //
    // Does nothing.
    //
    fn shutdown(ptr: *anyopaque) void {
        _ = ptr;
    }
};

test "queue-backend singleton: getQueueBackend throws before setQueueBackend is called" {
    // Force the singleton to null so getQueueBackend throws.
    setQueueBackend(null);
    try std.testing.expectError(error.Thrown, getQueueBackend());
    try std.testing.expectEqualStrings("Queue backend not initialised \u{2014} call setQueueBackend() at process startup.", errors.lastErrorMessage());
}

test "queue-backend singleton: getQueueBackend returns the backend set by setQueueBackend" {
    var backend: NoOpBackend = .{ .unused = 0 };
    setQueueBackend(backend.queueBackend());
    defer setQueueBackend(null);
    try std.testing.expect((try getQueueBackend()).ptr == @as(*anyopaque, &backend));
}

test "queue-backend singleton: calling setQueueBackend a second time replaces the previously registered backend" {
    var backend1: NoOpBackend = .{ .unused = 0 };
    var backend2: NoOpBackend = .{ .unused = 0 };
    setQueueBackend(backend1.queueBackend());
    setQueueBackend(backend2.queueBackend());
    defer setQueueBackend(null);
    try std.testing.expect((try getQueueBackend()).ptr == @as(*anyopaque, &backend2));
    try std.testing.expect((try getQueueBackend()).ptr != @as(*anyopaque, &backend1));
}

test "IQueueBackend forwards every method to the implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var backend: NoOpBackend = .{ .unused = 0 };
    const interface = backend.queueBackend();
    try std.testing.expectEqualStrings("task-id", try interface.addTask(arena.allocator(), std.testing.io, "t", .null, "s", null, null));
    const unsubscribe = try interface.onTaskComplete(.{ .context = null, .function = undefined });
    unsubscribe.call();
    interface.cancelTasks("s");
    interface.shutdown();
}

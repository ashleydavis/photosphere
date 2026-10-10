const std = @import("std");
const api_zig = @import("api-zig");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const loadAssets = api_zig.load_assets.loadAssets;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const setQueueBackend = task_queue_zig.queue_backend.setQueueBackend;
const types = task_queue_zig.types;
const TaskPriority = types.TaskPriority;
const UnsubscribeFn = types.UnsubscribeFn;
const TaskAddedCallback = types.TaskAddedCallback;
const TaskMessageCallback = types.TaskMessageCallback;
const TasksCancelledCallback = types.TasksCancelledCallback;
const WorkerTaskCompletionCallback = types.WorkerTaskCompletionCallback;

const io = std.testing.io;

//
// What one call to addTask was given, so a test can assert on the priority it asked for.
//
const IRecordedTask = struct {
    // The handler name.
    type: []const u8,

    // The input data, as JSON text.
    dataJson: []const u8,

    // The explicit task id, or null when the queue was left to mint one.
    taskId: ?[]const u8,

    // The priority asked for, or null when none was named.
    priority: ?TaskPriority,
};

//
// A queue backend that records what it was asked to add and does nothing else. loadAssets only ever
// queues, so this is the whole of what it touches.
//
const RecordingQueueBackend = struct {
    // Allocates the recorded tasks.
    allocator: std.mem.Allocator,

    // Every task added through this backend, in order.
    addedTasks: std.ArrayList(IRecordedTask) = .empty,

    //
    // Gets the IQueueBackend interface of this backend.
    //
    fn queueBackend(self: *RecordingQueueBackend) IQueueBackend {
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

    //
    // Records the task.
    //
    fn addTaskErased(ptr: *anyopaque, allocator: std.mem.Allocator, backendIo: std.Io, taskType: []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        _ = allocator;
        _ = backendIo;
        _ = source;
        const self: *RecordingQueueBackend = @ptrCast(@alignCast(ptr));
        try self.addedTasks.append(self.allocator, .{
            .type = taskType,
            .dataJson = try std.json.Stringify.valueAlloc(self.allocator, data, .{}),
            .taskId = taskId,
            .priority = priority,
        });
        return taskId orelse "generated-id";
    }

    //
    // Nothing is ever in flight here, so a subscription has nothing to remove.
    //
    fn noSubscription() UnsubscribeFn {
        return .{
            .context = null,
            .key = 0,
            .function = removeNothing,
        };
    }

    //
    // Removes a subscription that was never kept.
    //
    fn removeNothing(context: ?*anyopaque, key: usize) void {
        _ = context;
        _ = key;
    }

    //
    // Nothing subscribed.
    //
    fn onTaskAddedErased(ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return noSubscription();
    }

    //
    // Nothing subscribed.
    //
    fn onTaskCompleteErased(ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return noSubscription();
    }

    //
    // Nothing subscribed.
    //
    fn onTaskMessageErased(ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = messageType;
        _ = callback;
        return noSubscription();
    }

    //
    // Nothing subscribed.
    //
    fn onAnyTaskMessageErased(ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return noSubscription();
    }

    //
    // Nothing is ever running here, so there is nothing to cancel.
    //
    fn cancelTasksErased(ptr: *anyopaque, source: []const u8) void {
        _ = ptr;
        _ = source;
    }

    //
    // Nothing subscribed.
    //
    fn onTasksCancelledErased(ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return noSubscription();
    }

    //
    // Nothing to shut down.
    //
    fn shutdownErased(ptr: *anyopaque) void {
        _ = ptr;
    }
};

test "loadAssets queues the load as interactive, because the user is waiting on an empty gallery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var backend: RecordingQueueBackend = .{
        .allocator = allocator,
    };
    setQueueBackend(backend.queueBackend());
    defer setQueueBackend(null);
    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const queue = try TaskQueue.init(allocator, io, uuidGenerator.uuidGenerator(), "/photos/db");
    defer queue.deinit();

    try loadAssets(allocator, queue, "/photos/db");

    try std.testing.expectEqual(@as(usize, 1), backend.addedTasks.items.len);
    try std.testing.expectEqual(TaskPriority.Interactive, backend.addedTasks.items[0].priority.?);
}

test "loadAssets queues a load-assets task naming the database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var backend: RecordingQueueBackend = .{
        .allocator = allocator,
    };
    setQueueBackend(backend.queueBackend());
    defer setQueueBackend(null);
    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const queue = try TaskQueue.init(allocator, io, uuidGenerator.uuidGenerator(), "/photos/db");
    defer queue.deinit();

    try loadAssets(allocator, queue, "/photos/db");

    try std.testing.expectEqualStrings("load-assets", backend.addedTasks.items[0].type);
    try std.testing.expectEqualStrings("/photos/db", backend.addedTasks.items[0].taskId.?);
    try std.testing.expectEqualStrings(
        "{\"databasePath\":\"/photos/db\",\"job\":{\"id\":\"load:/photos/db\",\"name\":\"Loading assets\",\"cancelSource\":\"/photos/db\"}}",
        backend.addedTasks.items[0].dataJson,
    );
}

test "loadAssets cancels by the database path, which is the source its caller's queue is tagged with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var backend: RecordingQueueBackend = .{
        .allocator = allocator,
    };
    setQueueBackend(backend.queueBackend());
    defer setQueueBackend(null);
    var uuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const queue = try TaskQueue.init(allocator, io, uuidGenerator.uuidGenerator(), "/photos/db");
    defer queue.deinit();

    try loadAssets(allocator, queue, "/photos/db");

    // Callers build their TaskQueue with the database path as its source, and cancelTasks() takes a source. A cancel source that
    // did not match it would leave the Cancel button doing nothing at all.
    const data = try std.json.parseFromSliceLeaky(std.json.Value, allocator, backend.addedTasks.items[0].dataJson, .{});
    try std.testing.expectEqualStrings("/photos/db", data.object.get("job").?.object.get("cancelSource").?.string);
    try std.testing.expectEqualStrings(queue.source, data.object.get("job").?.object.get("cancelSource").?.string);
}

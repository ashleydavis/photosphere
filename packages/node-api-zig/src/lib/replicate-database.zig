const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const replicate_module = @import("replicate.zig");
const errors = utils.errors;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const TaskStatus = task_queue_zig.types.TaskStatus;
const ITaskMessageData = task_queue_zig.types.ITaskMessageData;
const IReplicationResult = replicate_module.IReplicationResult;
const IReplicateDatabaseData = api.replicate_database_types.IReplicateDatabaseData;
const IReplicateProgressMessage = api.replicate_database_types.IReplicateProgressMessage;

//
// Progress callback fired for each progress message emitted by the replicate-database worker.
// (Zig: a closure; `function` is called with `context`. The progress string is only valid during the call.)
//
pub const ReplicateProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, progress: []const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: ReplicateProgressCallback, progress: []const u8) void {
        self.function(self.context, progress);
    }
};

//
// Converts the replicate-database task data to the JSON value that is queued (like JSON.stringify, optional keys
// that are not set are left out). (No TypeScript counterpart: TypeScript queues the object itself.)
//
pub fn replicateDatabaseDataToJson(allocator: std.mem.Allocator, data: IReplicateDatabaseData) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, data, .{ .emit_null_optional_fields = false });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Forwards replicate-progress task messages to the ReplicateProgressCallback
// (TypeScript: the `({ message }) => { onProgress(message.progress); }` arrow function).
//
fn onReplicateProgressMessage(context: ?*anyopaque, data: ITaskMessageData) anyerror!void {
    const onProgress: *const ReplicateProgressCallback = @ptrCast(@alignCast(context.?));
    const message = switch (data.message) {
        .object => |object| object,
        else => {
            return;
        },
    };
    const progress = message.get("progress") orelse {
        return;
    };
    switch (progress) {
        .string => |text| onProgress.call(text),
        else => {},
    }
}

//
// Replicates a database via the replicate-database background task and waits for completion.
// Both the CLI and the desktop dialog call this: it encapsulates the TaskQueue dance (subscribe,
// addTask, awaitTask, shutdown) so callers do not duplicate it.
//
// The task is queued against the registered IQueueBackend (set up at process startup by the caller:
// WorkerPoolBun in the CLI, ElectronRendererQueueBackend in the renderer).
//
// Throws the task error message when replication fails; returns the replication summary on success.
//
pub fn replicateDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    uuidGenerator: IUuidGenerator,
    data: IReplicateDatabaseData,
    onProgress: ?*const ReplicateProgressCallback,
) !IReplicationResult {
    const queue = try TaskQueue.init(allocator, io, uuidGenerator, data.sourcePath);
    defer queue.deinit();

    if (onProgress) |progressCallback| {
        _ = try queue.onTaskMessage("replicate-progress", .{
            .context = @constCast(progressCallback),
            .function = onReplicateProgressMessage,
        });
    }

    const taskId = try queue.addTask("replicate-database", try replicateDatabaseDataToJson(allocator, data), null);
    const result = try queue.awaitTask(taskId);
    queue.shutdown();

    const taskResult = result orelse {
        return errors.throwError("Replication was cancelled before completion", .{});
    };
    if (taskResult.status != TaskStatus.Succeeded) {
        const errorMessage = taskResult.errorMessage orelse "";
        return errors.throwError("{s}", .{if (errorMessage.len > 0) errorMessage else "Replication failed"});
    }
    return try std.json.parseFromValueLeaky(IReplicationResult, allocator, taskResult.outputs orelse .null, .{ .ignore_unknown_fields = true });
}

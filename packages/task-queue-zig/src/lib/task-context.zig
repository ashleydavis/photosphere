//
// TaskContext: implements ITaskContext for a single worker task.
//
const std = @import("std");
const utils = @import("utils-zig");
const types = @import("types.zig");
const ITaskContext = types.ITaskContext;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;

//
// The function that sends a task message back to the caller (TypeScript: `(message: any) => void`).
// This name has no TypeScript counterpart. The message is only valid during the call.
//
pub const SendMessageFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // Sends the message.
    function: *const fn (context: ?*anyopaque, message: std.json.Value) void,

    //
    // Invokes the function.
    //
    pub fn call(self: SendMessageFn, message: std.json.Value) void {
        self.function(self.context, message);
    }
};

//
// Implements ITaskContext for a single worker task.
//
pub const TaskContext = struct {
    //
    // Generates unique identifiers.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Provides the current timestamp.
    //
    timestampProvider: ITimestampProvider,

    //
    // Unique identifier for the session this task belongs to.
    //
    sessionId: []const u8,

    //
    // The unique ID of the currently executing task.
    //
    taskId: []const u8,

    //
    // Whether this task has been cancelled (atomic: cancel is called from another thread than the task's).
    //
    _isCancelled: std.atomic.Value(bool),

    //
    // Sends a message back to the caller.
    //
    sendMessageFn: SendMessageFn,

    //
    // Creates the context of a task.
    //
    pub fn init(
        uuidGenerator: IUuidGenerator,
        timestampProvider: ITimestampProvider,
        sessionId: []const u8,
        taskId: []const u8,
        sendMessageFn: SendMessageFn,
    ) TaskContext {
        return .{
            .uuidGenerator = uuidGenerator,
            .timestampProvider = timestampProvider,
            .sessionId = sessionId,
            .taskId = taskId,
            ._isCancelled = std.atomic.Value(bool).init(false),
            .sendMessageFn = sendMessageFn,
        };
    }

    //
    // Gets the ITaskContext interface for this context (the TaskContext must not move while it is used).
    //
    pub fn taskContext(self: *TaskContext) ITaskContext {
        return .{
            .uuidGenerator = self.uuidGenerator,
            .timestampProvider = self.timestampProvider,
            .sessionId = self.sessionId,
            .taskId = self.taskId,
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The ITaskContext functions of this context.
    //
    const vtable: ITaskContext.VTable = .{
        .sendMessage = sendMessageErased,
        .isCancelled = isCancelledErased,
    };

    //
    // Sends a message back to the caller via the main process.
    //
    pub fn sendMessage(self: *TaskContext, msg: std.json.Value) void {
        self.sendMessageFn.call(msg);
    }

    //
    // Marks this task as cancelled.
    //
    pub fn cancel(self: *TaskContext) void {
        self._isCancelled.store(true, .release);
    }

    //
    // Returns true if this task has been cancelled.
    //
    pub fn isCancelled(self: *TaskContext) bool {
        return self._isCancelled.load(.acquire);
    }

    //
    // ITaskContext.sendMessage for this implementation.
    //
    fn sendMessageErased(ptr: *anyopaque, message: std.json.Value) void {
        const self: *TaskContext = @ptrCast(@alignCast(ptr));
        self.sendMessage(message);
    }

    //
    // ITaskContext.isCancelled for this implementation.
    //
    fn isCancelledErased(ptr: *anyopaque) bool {
        const self: *TaskContext = @ptrCast(@alignCast(ptr));
        return self.isCancelled();
    }
};

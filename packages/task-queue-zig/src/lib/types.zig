//
// Shared types for task queue system
// These types are used by both the main task queue and worker code
//
// Task data, task outputs and task messages are JSON-serializable values in TypeScript (they are
// posted to Bun workers). In Zig they are `std.json.Value`, so that handlers and backends stay
// generic; typed code converts with std.json.parseFromValueLeaky and std.json.Stringify.
//
// Memory: a value passed to a callback (a result, a message, the data given to a handler) is only
// valid for the duration of the call. A callee that keeps any of it must copy it with its own
// allocator. Callbacks may be invoked from any thread unless stated otherwise.
//

const std = @import("std");
const utils = @import("utils-zig");
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;

//
// Task context with all dependencies needed for task execution
//
pub const ITaskContext = struct {
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

    // Pointer to the implementation of sendMessage and isCancelled.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of ITaskContext provides.
    //
    pub const VTable = struct {
        // Sends a message from the task handler back to the caller.
        sendMessage: *const fn (ptr: *anyopaque, message: std.json.Value) void,

        // Returns true if this task has been cancelled and should stop as soon as possible.
        isCancelled: *const fn (ptr: *anyopaque) bool,
    };

    //
    // Sends a message from the task handler back to the caller.
    // The message only has to stay valid during the call (it is copied if it has to be kept).
    //
    pub fn sendMessage(self: ITaskContext, message: std.json.Value) void {
        self.vtable.sendMessage(self.ptr, message);
    }

    //
    // Returns true if this task has been cancelled and should stop as soon as possible.
    //
    pub fn isCancelled(self: ITaskContext) bool {
        return self.vtable.isCancelled(self.ptr);
    }
};

//
// Task handler function type
// Returns the result payload (can be any JSON value).
// The allocator belongs to the task (an arena that lives until the task's completion has been
// delivered), so the handler does not free what it allocates. The returned value and everything
// it points to must be allocated with it (or be static).
//
pub const TaskHandler = *const fn (allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: ITaskContext) anyerror!std.json.Value;

//
// Task status enumeration
//
pub const TaskStatus = enum {
    // The task is queued and waiting for a worker ("pending").
    Pending,

    // The task is being executed ("running").
    Running,

    // The task handler returned a result ("succeeded").
    Succeeded,

    // The task handler threw an error ("failed").
    Failed,

    //
    // Gets the TypeScript string value of the status ("pending", "running", "succeeded" or "failed").
    //
    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .Pending => "pending",
            .Running => "running",
            .Succeeded => "succeeded",
            .Failed => "failed",
        };
    }
};

//
// Task data structure
//
pub const ITask = struct {
    //
    // Unique identifier for this task.
    //
    id: []const u8,

    //
    // The type name used to look up the registered handler.
    //
    type: []const u8,

    //
    // Current lifecycle state of the task.
    //
    status: TaskStatus,

    //
    // Input data passed to the task handler.
    //
    data: std.json.Value,

    //
    // Source tag used to group and cancel related tasks (e.g. a database path).
    //
    source: []const u8,

    //
    // When the task was created (milliseconds since the Unix epoch).
    //
    createdAt: i64,

    //
    // When execution started (set by the worker pool when dispatched).
    //
    startedAt: ?i64 = null,

    //
    // When execution completed (set by the worker pool on completion).
    //
    completedAt: ?i64 = null,
};

//
// The serialized error of a failed task (TypeScript: the `Error` deserialized from serializeError output).
//
pub const ITaskError = struct {
    //
    // The error class name (e.g. "Error", "FatalError", "WrappedError").
    //
    name: []const u8,

    //
    // The error message.
    //
    message: []const u8,
};

//
// Result returned when a task finishes (success or failure).
// (The `= null` defaults let std.json parse results that leave optional keys out.)
//
pub const ITaskResult = struct {
    //
    // The ID of the task that produced this result.
    //
    taskId: []const u8,

    //
    // Whether the task succeeded or failed.
    //
    status: TaskStatus,

    //
    // Deserialized error object when status is Failed.
    //
    @"error": ?ITaskError = null,

    //
    // Convenience field: error?.message || "Unknown error".
    //
    errorMessage: ?[]const u8 = null,

    //
    // The actual result data returned by the handler.
    //
    outputs: ?std.json.Value = null,

    //
    // The type of the task that produced this result.
    //
    type: []const u8,

    //
    // The input data passed to the task when it was queued.
    //
    inputs: std.json.Value,
};

//
// Low-level completion callback used by worker pool implementations.
// (A Zig closure: `function` is called with `context`. Errors are caught and logged by the caller.)
//
pub const WorkerTaskCompletionCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function. The result is only valid during the call.
    function: *const fn (context: ?*anyopaque, result: ITaskResult) anyerror!void,

    //
    // Invokes the callback.
    //
    pub fn call(self: WorkerTaskCompletionCallback, result: ITaskResult) anyerror!void {
        return self.function(self.context, result);
    }
};

//
// Task message data structure passed to message callbacks.
//
pub const ITaskMessageData = struct {
    //
    // The ID of the task that sent this message.
    //
    taskId: []const u8,

    //
    // The message payload.
    //
    message: std.json.Value,
};

//
// Callback invoked when a task sends an arbitrary message to the client.
// (A Zig closure: `function` is called with `context`. Errors are caught and logged by the caller.)
//
pub const TaskMessageCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function. The data is only valid during the call.
    function: *const fn (context: ?*anyopaque, data: ITaskMessageData) anyerror!void,

    //
    // Invokes the callback.
    //
    pub fn call(self: TaskMessageCallback, data: ITaskMessageData) anyerror!void {
        return self.function(self.context, data);
    }
};

//
// Unsubscribe function returned by event listener registrations.
// (A Zig closure: `function` is called with `context` and the `key` that identifies the registration,
// where TypeScript captures the registered callback in an arrow function.)
//
pub const UnsubscribeFn = struct {
    // The object the callback was registered with.
    context: ?*anyopaque,

    // Identifies the registration within the object.
    key: usize,

    // Removes the registration.
    function: *const fn (context: ?*anyopaque, key: usize) void,

    //
    // Removes the registration.
    //
    pub fn call(self: UnsubscribeFn) void {
        self.function(self.context, self.key);
    }
};

//
// Typed completion callback for consumers of the task queue.
// TypeScript adds compile-time types for result.inputs and result.outputs; in Zig they are
// std.json.Value, so this is the same closure type as WorkerTaskCompletionCallback.
//
pub const TaskCompletionCallback = WorkerTaskCompletionCallback;

//
// A registered task message callback entry pairing a message type filter with its callback.
//
pub const IMessageCallbackEntry = struct {
    //
    // The message type this callback is registered for.
    //
    messageType: []const u8,

    //
    // The callback to invoke when a message with the matching type is received.
    //
    callback: TaskMessageCallback,
};

//
// Callback that fires when a task is added (TypeScript: `(taskId: string) => void`).
// This name has no TypeScript counterpart (TypeScript writes the function type inline).
//
pub const TaskAddedCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function. The task ID is only valid during the call.
    function: *const fn (context: ?*anyopaque, taskId: []const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: TaskAddedCallback, taskId: []const u8) void {
        self.function(self.context, taskId);
    }
};

//
// Callback that fires when the tasks of a source are cancelled (TypeScript: `() => void`).
// This name has no TypeScript counterpart (TypeScript writes the function type inline).
//
pub const TasksCancelledCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: TasksCancelledCallback) void {
        self.function(self.context);
    }
};

//
// Returns the `type` of a task message, or null when the message is not an object with a string
// `type` (TypeScript: `message && typeof message === "object" && "type" in message ? message.type : undefined`;
// only string types can equal a registered message type).
// This function has no TypeScript counterpart: the expression is repeated inline in TypeScript.
//
pub fn messageTypeOf(message: std.json.Value) ?[]const u8 {
    switch (message) {
        .object => |object| {
            const type_value = object.get("type") orelse return null;
            return switch (type_value) {
                .string => |text| text,
                else => null,
            };
        },
        else => return null,
    }
}

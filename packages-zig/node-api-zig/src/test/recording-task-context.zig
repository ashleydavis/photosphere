const std = @import("std");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;

//
// A task context for the tests of the worker handlers.
//
// It records every message the handler sends and reports the task cancelled once isCancelled has been called more than
// cancelAfterCalls times.
//
pub const RecordingTaskContext = struct {
    // Owns the recorded messages. Must outlive the context.
    allocator: std.mem.Allocator,

    // Deterministic uuids.
    uuidGenerator: TestUuidGenerator,

    // Deterministic time, used when clockOverride is null.
    testClock: TestTimestampProvider,

    // The clock the context hands to the handler instead of testClock, or null to use testClock.
    clockOverride: ?ITimestampProvider,

    // Every message sent so far, in order, each copied so it stays valid after the call that sent it.
    messages: std.ArrayList(std.json.Value),

    // How many times isCancelled may be called before it starts to answer true, or null to never cancel.
    cancelAfterCalls: ?u64,

    // How many times isCancelled has been called.
    cancelChecks: u64,

    //
    // Fills in the context. It must not move afterwards, because the task context points at it.
    //
    pub fn init(self: *RecordingTaskContext, allocator: std.mem.Allocator, cancelAfterCalls: ?u64, clockOverride: ?ITimestampProvider) !void {
        self.* = .{
            .allocator = allocator,
            .uuidGenerator = try TestUuidGenerator.init(allocator),
            .testClock = .{},
            .clockOverride = clockOverride,
            .messages = .empty,
            .cancelAfterCalls = cancelAfterCalls,
            .cancelChecks = 0,
        };
    }

    //
    // Gets the ITaskContext of this context.
    //
    pub fn taskContext(self: *RecordingTaskContext) ITaskContext {
        return .{
            .uuidGenerator = self.uuidGenerator.uuidGenerator(),
            .timestampProvider = self.clockOverride orelse self.testClock.timestampProvider(),
            .sessionId = "session-1",
            .taskId = "task-1",
            .maxConcurrentChildTasks = 10,
            .hostRequester = null,
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The messages whose type is the given one, in the order they were sent.
    //
    pub fn messagesOfType(self: *RecordingTaskContext, messageType: []const u8) ![]const std.json.Value {
        var matching: std.ArrayList(std.json.Value) = .empty;
        for (self.messages.items) |message| {
            if (task_queue_zig.types.messageTypeOf(message)) |foundType| {
                if (std.mem.eql(u8, foundType, messageType)) {
                    try matching.append(self.allocator, message);
                }
            }
        }
        return matching.items;
    }

    //
    // The ITaskContext functions of this context.
    //
    const vtable: ITaskContext.VTable = .{
        .sendMessage = sendMessageErased,
        .isCancelled = isCancelledErased,
    };

    //
    // Records a message, failing the test run loudly when it cannot be copied.
    //
    fn sendMessageErased(ptr: *anyopaque, message: std.json.Value) void {
        const self: *RecordingTaskContext = @ptrCast(@alignCast(ptr));
        const text = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch @panic("could not copy a task message");
        const copy = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, text, .{}) catch @panic("could not copy a task message");
        self.messages.append(self.allocator, copy) catch @panic("could not record a task message");
    }

    //
    // Counts the call and reports the task cancelled once more calls have been made than cancelAfterCalls.
    //
    fn isCancelledErased(ptr: *anyopaque) bool {
        const self: *RecordingTaskContext = @ptrCast(@alignCast(ptr));
        self.cancelChecks += 1;
        const limit = self.cancelAfterCalls orelse {
            return false;
        };
        return self.cancelChecks > limit;
    }
};

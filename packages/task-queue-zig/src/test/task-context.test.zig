const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const TaskContext = task_queue_zig.task_context.TaskContext;
const SendMessageFn = task_queue_zig.task_context.SendMessageFn;

//
// Records the messages passed to the send-message function (the jest.fn() of the TypeScript tests).
//
const MessageRecorder = struct {
    // Number of calls.
    calls: usize,

    // The type field of the last message.
    lastType: []const u8,

    // The value field of the last message.
    lastValue: i64,

    //
    // Records a message.
    //
    fn record(context: ?*anyopaque, message: std.json.Value) void {
        const self: *MessageRecorder = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.lastType = message.object.get("type").?.string;
        self.lastValue = message.object.get("value").?.integer;
    }

    //
    // Gets the send-message function that records into this recorder.
    //
    fn sendMessageFn(self: *MessageRecorder) SendMessageFn {
        return .{ .context = self, .function = record };
    }
};

test "TaskContext: isCancelled returns false initially" {
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: MessageRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "session-1", "task-1", recorder.sendMessageFn(), 10);

    try std.testing.expect(!context.isCancelled());
}

test "TaskContext: cancel causes isCancelled to return true" {
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: MessageRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "session-1", "task-1", recorder.sendMessageFn(), 10);

    context.cancel();

    try std.testing.expect(context.isCancelled());
    try std.testing.expect(context.taskContext().isCancelled());
}

test "TaskContext: sendMessage invokes the injected sendMessageFn with the correct argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: MessageRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "session-1", "task-1", recorder.sendMessageFn(), 10);

    const msg = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"progress\",\"value\":42}", .{});
    context.sendMessage(msg);

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("progress", recorder.lastType);
    try std.testing.expectEqual(@as(i64, 42), recorder.lastValue);

    // Through the ITaskContext interface too.
    context.taskContext().sendMessage(msg);
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
}

test "TaskContext: everything the task needs is exposed as provided" {
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var recorder: MessageRecorder = .{ .calls = 0, .lastType = "", .lastValue = 0 };
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "my-session", "my-task", recorder.sendMessageFn(), 7);

    try std.testing.expect(context.uuidGenerator.ptr == @as(*anyopaque, &uuid_generator));
    try std.testing.expect(context.timestampProvider.ptr == @as(*anyopaque, &timestamp_provider));
    try std.testing.expectEqualStrings("my-session", context.sessionId);
    try std.testing.expectEqualStrings("my-task", context.taskId);
    const interface = context.taskContext();
    try std.testing.expectEqualStrings("my-session", interface.sessionId);
    try std.testing.expectEqualStrings("my-task", interface.taskId);

    // How many child tasks a task may run at once comes from the platform that built the
    // context, because only it knows what the machine can take.
    try std.testing.expectEqual(@as(u32, 7), context.maxConcurrentChildTasks);
    try std.testing.expectEqual(@as(u32, 7), interface.maxConcurrentChildTasks);
}

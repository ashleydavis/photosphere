const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const TaskContext = task_queue_zig.task_context.TaskContext;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;

//
// A task context whose events go nowhere, for the tests of handlers that use only the generators, the session id
// and the cancel flag of their context.
// The context must not move while it is used.
//
pub const TestTaskContext = struct {
    // Deterministic time.
    timestampProvider: TestTimestampProvider,

    // The task context.
    context: TaskContext,

    //
    // Drops a message.
    //
    fn ignoreMessage(context: ?*anyopaque, _: std.Io, _: std.mem.Allocator, message: std.json.Value) void {
        _ = context;
        _ = message;
    }

    //
    // Fills in the context. The session id is "test-session" and the task id "test-task".
    //
    pub fn init(self: *TestTaskContext, uuidGenerator: utils.uuid_generator.IUuidGenerator) void {
        self.timestampProvider = .{};
        self.context = TaskContext.init(uuidGenerator, self.timestampProvider.timestampProvider(), "test-session", "test-task", .{
            .context = null,
            .function = ignoreMessage,
        }, 10);
    }
};

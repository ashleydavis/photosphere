const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const types = task_queue_zig.types;
const ITaskContext = types.ITaskContext;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;

//
// Records the messages a handler sends through a task context (the jest.fn() of the TypeScript tests).
//
const MessageRecorder = struct {
    // Number of messages sent.
    calls: usize,

    // The last message, serialized to JSON so it can be compared after the call returns.
    lastMessage: []const u8,

    // Allocator for lastMessage.
    allocator: std.mem.Allocator,

    //
    // ITaskContext.sendMessage for the recorder.
    //
    fn sendMessage(ptr: *anyopaque, message: std.json.Value) void {
        const self: *MessageRecorder = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.lastMessage = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch unreachable;
    }

    //
    // ITaskContext.isCancelled for the recorder.
    //
    fn isCancelled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    //
    // The ITaskContext functions of the recorder.
    //
    const vtable: ITaskContext.VTable = .{
        .sendMessage = sendMessage,
        .isCancelled = isCancelled,
    };
};

//
// The generators the test context carries (unused by sendJobProgress).
//
const Generators = struct {
    // Generates UUIDs.
    uuidGenerator: utils.random_uuid_generator.RandomUuidGenerator,

    // Provides timestamps.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,
};

//
// Builds a task context that records the messages a handler sends through it.
//
fn makeContext(recorder: *MessageRecorder, generators: *Generators) ITaskContext {
    return .{
        .uuidGenerator = generators.uuidGenerator.uuidGenerator(),
        .timestampProvider = generators.timestampProvider.timestampProvider(),
        .sessionId = "session-1",
        .taskId = "task-1",
        .maxConcurrentChildTasks = 1,
        .ptr = recorder,
        .vtable = &MessageRecorder.vtable,
    };
}

test "sends the whole job with every report, so a listener that joined late learns all of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: MessageRecorder = .{
        .calls = 0,
        .lastMessage = "",
        .allocator = arena.allocator(),
    };
    var generators: Generators = .{
        .uuidGenerator = .{},
        .timestampProvider = .{},
    };
    const context = makeContext(&recorder, &generators);

    try sendJobProgress(arena.allocator(), context, .{
        .id = "job-1",
        .name = "Importing photos",
        .cancelSource = "session-1",
    }, 5000, "12 imported");

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Importing photos\",\"cancelSource\":\"session-1\"},\"startedAt\":5000,\"progressMessage\":\"12 imported\"}", recorder.lastMessage);
}

test "carries a job that has not said what it is doing yet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: MessageRecorder = .{
        .calls = 0,
        .lastMessage = "",
        .allocator = arena.allocator(),
    };
    var generators: Generators = .{
        .uuidGenerator = .{},
        .timestampProvider = .{},
    };
    const context = makeContext(&recorder, &generators);

    try sendJobProgress(arena.allocator(), context, .{
        .id = "job-1",
        .name = "Syncing database",
    }, 5000, null);

    // (Zig: an undefined progressMessage is left out of the message, as JSON.stringify leaves it out.)
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Syncing database\"},\"startedAt\":5000}", recorder.lastMessage);
}

test "sends nothing for a task that carries no job tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: MessageRecorder = .{
        .calls = 0,
        .lastMessage = "",
        .allocator = arena.allocator(),
    };
    var generators: Generators = .{
        .uuidGenerator = .{},
        .timestampProvider = .{},
    };
    const context = makeContext(&recorder, &generators);

    try sendJobProgress(arena.allocator(), context, null, 5000, "12 imported");

    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
}

const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const worker = task_queue_zig.worker;
const types = task_queue_zig.types;
const TaskContext = task_queue_zig.task_context.TaskContext;
const errors = utils.errors;

//
// A handler that returns its data under the key "echo".
//
fn echoHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "echo", data);
    try object.put(allocator, "taskId", .{ .string = context.taskId });
    return .{ .object = object };
}

//
// A handler that returns 1.
//
fn oneHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return .{ .integer = 1 };
}

//
// A handler that throws.
//
fn throwingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return errors.throwError("Handler failed", .{});
}

//
// Ignores sent messages.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

test "registerHandler and getHandler" {
    try worker.registerHandler("worker-test-one", oneHandler);
    try std.testing.expect(worker.getHandler("worker-test-one") == oneHandler);
    try std.testing.expect(worker.getHandler("worker-test-missing") == null);

    // Registering again replaces the handler.
    try worker.registerHandler("worker-test-one", echoHandler);
    try std.testing.expect(worker.getHandler("worker-test-one") == echoHandler);
    try worker.registerHandler("worker-test-one", oneHandler);
}

test "getRegisteredHandlerTypes lists types in registration order" {
    try worker.registerHandler("worker-test-order-a", oneHandler);
    try worker.registerHandler("worker-test-order-b", oneHandler);
    const registered = worker.getRegisteredHandlerTypes();
    var index_a: ?usize = null;
    var index_b: ?usize = null;
    for (registered, 0..) |registered_type, index| {
        if (std.mem.eql(u8, registered_type, "worker-test-order-a")) {
            index_a = index;
        }
        if (std.mem.eql(u8, registered_type, "worker-test-order-b")) {
            index_b = index;
        }
    }
    try std.testing.expect(index_a.? < index_b.?);
}

test "executeTaskHandler runs the registered handler with the data and context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "s", "task-7", .{ .context = null, .function = ignoreMessage });

    try worker.registerHandler("worker-test-echo", echoHandler);
    const outputs = try worker.executeTaskHandler(arena.allocator(), std.testing.io, "worker-test-echo", .{ .string = "hi" }, context.taskContext());
    try std.testing.expectEqualStrings("hi", outputs.object.get("echo").?.string);
    try std.testing.expectEqualStrings("task-7", outputs.object.get("taskId").?.string);
}

test "executeTaskHandler propagates handler errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "s", "t", .{ .context = null, .function = ignoreMessage });

    try worker.registerHandler("worker-test-throw", throwingHandler);
    try std.testing.expectError(error.Thrown, worker.executeTaskHandler(arena.allocator(), std.testing.io, "worker-test-throw", .null, context.taskContext()));
    try std.testing.expectEqualStrings("Handler failed", errors.lastErrorMessage());
}

test "executeTaskHandler throws when no handler is registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider(), "s", "t", .{ .context = null, .function = ignoreMessage });

    try worker.registerHandler("worker-test-available", oneHandler);
    try std.testing.expectError(error.Thrown, worker.executeTaskHandler(arena.allocator(), std.testing.io, "worker-test-nope", .null, context.taskContext()));
    const message = errors.lastErrorMessage();
    try std.testing.expect(std.mem.startsWith(u8, message, "No handler registered for task type: worker-test-nope. Available handlers: "));
    try std.testing.expect(std.mem.indexOf(u8, message, "worker-test-available") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, ", ") != null);
}

const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const types = task_queue_zig.types;

test "TaskStatus.toString returns the TypeScript enum values" {
    try std.testing.expectEqualStrings("pending", types.TaskStatus.Pending.toString());
    try std.testing.expectEqualStrings("running", types.TaskStatus.Running.toString());
    try std.testing.expectEqualStrings("succeeded", types.TaskStatus.Succeeded.toString());
    try std.testing.expectEqualStrings("failed", types.TaskStatus.Failed.toString());
}

test "messageTypeOf returns the string type of an object message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const typed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"type\":\"replicate-progress\",\"progress\":\"x\"}", .{});
    try std.testing.expectEqualStrings("replicate-progress", types.messageTypeOf(typed).?);
    const untyped = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"progress\":\"x\"}", .{});
    try std.testing.expect(types.messageTypeOf(untyped) == null);
    const number_type = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"type\":5}", .{});
    try std.testing.expect(types.messageTypeOf(number_type) == null);
    try std.testing.expect(types.messageTypeOf(.{ .string = "type" }) == null);
    try std.testing.expect(types.messageTypeOf(.null) == null);
}

test "ITaskResult round-trips through JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result: types.ITaskResult = .{
        .taskId = "t1",
        .status = .Failed,
        .@"error" = .{ .name = "Error", .message = "boom" },
        .errorMessage = "boom",
        .outputs = null,
        .type = "verify-file",
        .inputs = .{ .string = "in" },
    };
    const json = try std.json.Stringify.valueAlloc(allocator, result, .{});
    const parsed = try std.json.parseFromSliceLeaky(types.ITaskResult, allocator, json, .{});
    try std.testing.expectEqualStrings("t1", parsed.taskId);
    try std.testing.expectEqual(types.TaskStatus.Failed, parsed.status);
    try std.testing.expectEqualStrings("boom", parsed.@"error".?.message);
    try std.testing.expectEqualStrings("in", parsed.inputs.string);
}

//
// Counts the calls of a callback closure.
//
fn countCall(context: ?*anyopaque, taskId: []const u8) void {
    _ = taskId;
    const counter: *usize = @ptrCast(@alignCast(context.?));
    counter.* += 1;
}

//
// Counts the calls of an unsubscribe closure and records the key.
//
fn recordUnsubscribe(context: ?*anyopaque, key: usize) void {
    const recorded_key: *usize = @ptrCast(@alignCast(context.?));
    recorded_key.* = key;
}

test "callback closures call their function with their context" {
    var counter: usize = 0;
    const callback: types.TaskAddedCallback = .{ .context = &counter, .function = countCall };
    callback.call("a");
    callback.call("b");
    try std.testing.expectEqual(@as(usize, 2), counter);

    var recorded_key: usize = 0;
    const unsubscribe: types.UnsubscribeFn = .{ .context = &recorded_key, .key = 42, .function = recordUnsubscribe };
    unsubscribe.call();
    try std.testing.expectEqual(@as(usize, 42), recorded_key);
}

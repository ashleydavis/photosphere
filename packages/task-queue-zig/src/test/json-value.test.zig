const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const cloneJsonValue = task_queue_zig.json_value.cloneJsonValue;

test "cloneJsonValue makes a deep copy that outlives the original" {
    var copy_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer copy_arena.deinit();
    const text = "{\"nested\":{\"array\":[1,2.5,\"three\",null,true,{\"key\":\"value\"}]},\"big\":123456789012345678901234567890,\"empty\":{}}";

    var copy: std.json.Value = undefined;
    {
        var original_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer original_arena.deinit();
        const original = try std.json.parseFromSliceLeaky(std.json.Value, original_arena.allocator(), text, .{});
        copy = try cloneJsonValue(copy_arena.allocator(), original);
    }

    const serialized = try std.json.Stringify.valueAlloc(copy_arena.allocator(), copy, .{});
    try std.testing.expectEqualStrings(text, serialized);
}

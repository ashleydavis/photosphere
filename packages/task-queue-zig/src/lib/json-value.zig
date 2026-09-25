//
// This file has no TypeScript counterpart. TypeScript copies task data, results and messages
// implicitly (structured clone when posting to workers, garbage collection otherwise); Zig backends
// copy std.json.Value trees explicitly with cloneJsonValue when they have to keep them.
//

const std = @import("std");

//
// Returns a deep copy of a JSON value, allocated with `allocator` (strings, arrays and objects are copied).
//
pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |boolean| .{ .bool = boolean },
        .integer => |integer| .{ .integer = integer },
        .float => |float| .{ .float = float },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .array => |array| blk: {
            var copy = std.json.Array.init(allocator);
            try copy.ensureTotalCapacity(array.items.len);
            for (array.items) |item| {
                copy.appendAssumeCapacity(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = copy };
        },
        .object => |object| blk: {
            var copy: std.json.ObjectMap = .empty;
            try copy.ensureTotalCapacity(allocator, object.count());
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                copy.putAssumeCapacity(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = copy };
        },
    };
}

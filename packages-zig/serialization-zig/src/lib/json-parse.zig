//
// No TypeScript counterpart: `JSON.parse`, producing the JavaScript value it returns as a BsonValue (the model of a
// JavaScript value, see bson.zig). Numbers are JS numbers, objects keep JavaScript's property order (array index keys
// first in ascending order, then the other keys in the order they first appear) and a repeated key keeps its first
// position with its last value.
//

const std = @import("std");
const bson = @import("bson.zig");
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;

//
// Converts a parsed JSON value to the JavaScript value JSON.parse gives.
//
fn toJsValue(allocator: std.mem.Allocator, value: std.json.Value) !BsonValue {
    return switch (value) {
        .null => .null,
        .bool => |boolean| .{ .boolean = boolean },
        .integer => |integer| .{ .number = @floatFromInt(integer) },
        .float => |float| .{ .number = float },
        .number_string => |text| .{ .number = try std.fmt.parseFloat(f64, text) },
        .string => |text| .{ .string = text },
        .array => |items| blk: {
            const elements = try allocator.alloc(BsonValue, items.items.len);
            for (items.items, 0..) |item, index| {
                elements[index] = try toJsValue(allocator, item);
            }
            break :blk .{ .array = elements };
        },
        .object => |object| blk: {
            var document: BsonDocument = .{};
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try document.put(allocator, entry.key_ptr.*, try toJsValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .document = document };
        },
    };
}

//
// Parses JSON text like `JSON.parse(text)`.
//
pub fn jsonParse(allocator: std.mem.Allocator, text: []const u8) !BsonValue {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{
        .duplicate_field_behavior = .use_last,
        .parse_numbers = true,
    });
    return toJsValue(allocator, value);
}

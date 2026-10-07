const std = @import("std");

//
// Gets the strings of a JSON array.
//
pub fn jsonStrings(allocator: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| {
        try strings.append(allocator, item.string);
    }
    return strings.items;
}

//
// Gets a JSON number as an integer.
//
pub fn jsonInteger(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => -1,
    };
}

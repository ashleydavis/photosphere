//
// Small helpers for building and reading JSON messages.
//

const std = @import("std");

//
// Converts any value that std.json can serialise to JSON text allocated with the allocator. An optional field that is
// null is left out, as JSON.stringify leaves out an undefined property.
//
pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
}

//
// Returns a string field of a JSON object, or null when the value is not an object or the field is missing or not a string.
//
pub fn getString(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) {
        return null;
    }
    const field = value.object.get(name) orelse {
        return null;
    };
    if (field != .string) {
        return null;
    }
    return field.string;
}

//
// Returns an integer field of a JSON object, or null when the value is not an object or the field is missing or not an integer.
//
pub fn getInteger(value: std.json.Value, name: []const u8) ?i64 {
    if (value != .object) {
        return null;
    }
    const field = value.object.get(name) orelse {
        return null;
    };
    if (field != .integer) {
        return null;
    }
    return field.integer;
}

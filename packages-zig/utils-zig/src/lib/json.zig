//
// Small helpers for building JSON text.
//

const std = @import("std");

//
// Converts a value that std.json can serialise (a struct, a slice, a string, a number) to compact JSON text allocated with the
// allocator. The fields are written in the order they are declared. An optional field that is null is left out, as JSON.stringify
// leaves out an undefined property.
//
pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
}

//
// A piece of JSON text that is already built. Put it in a value given to stringify and it is written out as it is, without being
// parsed and written again, so the bytes of the text are kept.
//
pub const Raw = struct {
    // The JSON text.
    text: []const u8,

    //
    // Called by std.json when a Raw is written: writes the text as one JSON value.
    //
    pub fn jsonStringify(self: Raw, json_writer: anytype) !void {
        try json_writer.beginWriteRaw();
        try json_writer.writer.writeAll(self.text);
        json_writer.endWriteRaw();
    }
};

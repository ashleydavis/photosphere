const std = @import("std");
const serialization_zig = @import("serialization-zig");
const js_value = @import("js-value.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;

//
// No TypeScript counterpart: the TypeScript code calls the npm `json-stable-stringify` package (version 1.3.0,
// `stringify(obj)` with no options) from `hashRecord`. This is a port of that package's index.js for the values npm
// bson produces when it deserializes a record:
//
// - `toJSON()` is applied first (Date -> ISO string or null, Binary -> base64, UUID -> dashed hex, ObjectId -> hex).
// - Primitives are written with `JSON.stringify` (non-finite numbers become null).
// - Arrays keep their order; an element that stringifies to undefined is written as null.
// - Object keys are sorted with the default Array.prototype.sort order (UTF-16 code units); a field whose value
//   stringifies to undefined is left out.
//
// Returns null when the whole value stringifies to undefined (the JS function returns undefined).
//
pub fn stringify(allocator: std.mem.Allocator, value: BsonValue) !?[]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const written = try writeStable(allocator, &output.writer, value);
    if (!written) {
        return null;
    }
    return output.written();
}

//
// Stringifies a document (the argument hashRecord passes: the record fields).
//
pub fn stringifyDocument(allocator: std.mem.Allocator, document: BsonDocument) ![]const u8 {
    return (try stringify(allocator, .{ .document = document })) orelse unreachable;
}

//
// Sort predicate for field keys: the default Array.prototype.sort order (UTF-16 code units).
//
fn keyLessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return js_value.compareUtf16(left, right) < 0;
}

//
// Writes one value (the inner `stringify(parent, key, node, level)` of the npm package).
// Returns false when the value is undefined and nothing was written.
//
fn writeStable(allocator: std.mem.Allocator, writer: *std.Io.Writer, rawValue: BsonValue) !bool {
    const value = try js_value.applyToJson(allocator, rawValue);
    switch (value) {
        .undefined => {
            return false;
        },
        .number => |number| {
            if (std.math.isFinite(number)) {
                try js_value.writeNumber(writer, number);
            }
            else {
                try writer.writeAll("null");
            }
        },
        .string => |text| {
            try js_value.writeJsonString(writer, text);
        },
        .boolean => |boolean| {
            try writer.writeAll(if (boolean) "true" else "false");
        },
        .null => {
            try writer.writeAll("null");
        },
        .array => |elements| {
            try writer.writeAll("[");
            for (elements, 0..) |element, elementIndex| {
                if (elementIndex > 0) {
                    try writer.writeAll(",");
                }
                if (!try writeStable(allocator, writer, element)) {
                    try writer.writeAll("null");
                }
            }
            try writer.writeAll("]");
        },
        .document => |document| {
            const keys = try allocator.alloc([]const u8, document.fields.items.len);
            for (document.fields.items, 0..) |field, fieldIndex| {
                keys[fieldIndex] = field.key;
            }
            std.mem.sort([]const u8, keys, {}, keyLessThan);
            try writer.writeAll("{");
            var wroteField = false;
            for (keys) |key| {
                var fieldOutput: std.Io.Writer.Allocating = .init(allocator);
                if (!try writeStable(allocator, &fieldOutput.writer, document.get(key).?)) {
                    continue;
                }
                if (wroteField) {
                    try writer.writeAll(",");
                }
                try js_value.writeJsonString(writer, key);
                try writer.writeAll(":");
                try writer.writeAll(fieldOutput.written());
                wroteField = true;
            }
            try writer.writeAll("}");
        },
        else => {
            // Every other value has been converted by toJSON above.
            unreachable;
        },
    }
    return true;
}

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;

//
// Builds one property of a JS object literal (TypeScript: `key: value`).
//
pub fn property(key: []const u8, value: BsonValue) bson.BsonField {
    return .{
        .key = key,
        .value = value,
    };
}

//
// Builds a JS string value.
//
pub fn stringValue(value: []const u8) BsonValue {
    return .{
        .string = value,
    };
}

//
// Builds a JS number value.
//
pub fn numberValue(value: f64) BsonValue {
    return .{
        .number = value,
    };
}

//
// Builds a JS object literal from its properties, in order.
//
pub fn objectValue(allocator: std.mem.Allocator, properties: []const bson.BsonField) !BsonValue {
    return .{
        .document = try BsonDocument.fromFields(allocator, properties),
    };
}

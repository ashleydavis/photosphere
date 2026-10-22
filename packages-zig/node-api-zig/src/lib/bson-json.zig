const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const applyToJson = bdb.js_value.applyToJson;

//
// Converts a BSON value to the JSON value of a task event (Zig task events are std.json.Value).
//
// Dates, binaries and ObjectIds become the strings JSON.stringify makes of them. A whole number becomes a JSON integer,
// where a number with a fraction becomes a float. A field whose value is undefined is left out of a document and
// written as null in an array, as JSON.stringify does.
//
pub fn bsonValueToJson(allocator: std.mem.Allocator, rawValue: BsonValue) anyerror!std.json.Value {
    const value = try applyToJson(allocator, rawValue);
    switch (value) {
        .number => |number| {
            return numberToJson(number);
        },
        .string => |text| {
            return .{
                .string = text,
            };
        },
        .boolean => |boolean| {
            return .{
                .bool = boolean,
            };
        },
        .null, .undefined => {
            return .null;
        },
        .document => |document| {
            return .{
                .object = try bsonDocumentToJsonObject(allocator, document),
            };
        },
        .array => |elements| {
            var array = try std.json.Array.initCapacity(allocator, elements.len);
            for (elements) |element| {
                array.appendAssumeCapacity(try bsonValueToJson(allocator, element));
            }
            return .{
                .array = array,
            };
        },
        .double, .int32, .int64, .date, .binary, .objectId => {
            // applyToJson has already turned these into numbers, documents or strings, as JSON.stringify writes them.
            unreachable;
        },
    }
}

//
// Converts a BSON document to a JSON object, leaving out the fields whose value is undefined.
//
pub fn bsonDocumentToJsonObject(allocator: std.mem.Allocator, document: BsonDocument) anyerror!std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    for (document.fields.items) |field| {
        if (field.value == .undefined) {
            continue;
        }
        try object.put(allocator, field.key, try bsonValueToJson(allocator, field.value));
    }
    return object;
}

//
// Converts a JS number to a JSON integer when it is a whole number a JSON integer holds exactly, and to a float otherwise.
// A NaN or infinite number becomes null, as JSON.stringify writes it.
//
fn numberToJson(number: f64) std.json.Value {
    if (!std.math.isFinite(number)) {
        return .null;
    }
    const maxExactInteger: f64 = 9007199254740991;
    if (@floor(number) == number and @abs(number) <= maxExactInteger) {
        return .{
            .integer = @intFromFloat(number),
        };
    }
    return .{
        .float = number,
    };
}

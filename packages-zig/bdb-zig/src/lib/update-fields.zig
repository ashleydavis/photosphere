const std = @import("std");
const serialization_zig = @import("serialization-zig");
const js_value = @import("js-value.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;

//
// Recursively updates fields by merging updates into existing fields.
// Treats input data as immutable and returns a new object with updated fields.
// Handles nested objects recursively, and deletions (undefined values).
// (Zig: the fields and the updates are JavaScript values, so that null, undefined and the non-plain objects a
// record holds behave as they do in TypeScript, where a date updated with another date keeps the old one.)
//
pub fn updateFields(allocator: std.mem.Allocator, oldFields: BsonValue, updates: BsonValue) !BsonValue {
    var currentFields = oldFields;

    // If oldFields is undefined/null, start with empty object.
    if (!js_value.isObject(currentFields)) {
        currentFields = .{ .document = .empty };
    }

    // If no updates, return the original fields.
    if (updates == .null or updates == .undefined or (try js_value.objectKeys(allocator, updates)).len == 0) {
        return currentFields;
    }

    // Create a new root object for immutability.
    var updatedFields: BsonDocument = .empty;
    for (try js_value.objectKeys(allocator, currentFields)) |key| {
        try updatedFields.put(allocator, key, try js_value.getProperty(currentFields, key));
    }

    for (try js_value.objectKeys(allocator, updates)) |key| {
        if (try js_value.getProperty(updates, key) == .undefined) {
            // Field is being deleted
            _ = updatedFields.remove(key);
        }
        else {
            const newValue = try js_value.getProperty(updates, key);
            const oldValue = updatedFields.get(key) orelse .undefined;

            // Check if both old and new values are nested objects (not arrays)
            const isNewObject = js_value.isObject(newValue);
            const isOldObject = js_value.isObject(oldValue);
            if (isNewObject and isOldObject) {
                // Both are nested objects - recurse
                try updatedFields.put(allocator, key, try updateFields(allocator, oldValue, newValue));
            }
            else {
                // Replace the field value (including when converting to/from object)
                try updatedFields.put(allocator, key, newValue);
            }
        }
    }

    return .{ .document = updatedFields };
}

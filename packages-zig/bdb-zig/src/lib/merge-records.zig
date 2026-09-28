const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const js_value = @import("js-value.zig");
const collection = @import("collection.zig");
const shard = @import("shard.zig");
const errors = utils.errors;
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const Metadata = collection.Metadata;
const IInternalRecord = shard.IInternalRecord;

//
// Checks if a value is a primitive, undefined, null, or array.
// Arrays are treated as atomic values (winner-takes-all) rather than merged field-by-field.
//
fn isPrimitive(value: BsonValue) bool {
    return !js_value.isObject(value);
}

//
// The metadata of a value to be merged (TypeScript: the inline type of MergeValue.metadata).
//
pub const MergeValueMetadata = struct {
    //
    // The timestamp of the value.
    //
    timestamp: f64,

    //
    // Metadata for nested fields (null for undefined).
    //
    fields: ?BsonDocument,
};

//
// A value to be merged.
// A simplified data structure with minimal optional fields.
//
pub const MergeValue = struct {
    //
    // The value to be merged.
    //
    value: BsonValue,

    //
    // The metadata for the value.
    //
    metadata: MergeValueMetadata,
};

//
// Reads a number that may be missing (TypeScript: the operand of `??`): null for a missing, undefined or null value.
// (No TypeScript counterpart.) Throws for a value that is not a number, which is not ported.
//
fn optionalNumber(value: ?BsonValue) !?f64 {
    const present = value orelse {
        return null;
    };
    switch (present) {
        .number => |number| {
            return number;
        },
        .null, .undefined => {
            return null;
        },
        else => {
            return errors.throwError("A metadata timestamp that is a {s} value is not ported", .{@tagName(present)});
        },
    }
}

//
// Reads a number as a condition (TypeScript: `value` in `value || other` or `if (value)`): the number when it is
// truthy, null when it is missing, zero or NaN. (No TypeScript counterpart.)
//
fn truthyNumber(value: ?BsonValue) !?f64 {
    const number = try optionalNumber(value) orelse {
        return null;
    };
    if (number == 0 or std.math.isNan(number)) {
        return null;
    }
    return number;
}

//
// Reads a metadata object that may be missing (TypeScript: the operand of `?.`): null for a missing, undefined or null
// value. (No TypeScript counterpart.) Throws for a value that is not an object, which is not ported.
//
fn optionalMetadata(value: ?BsonValue) !?Metadata {
    const present = value orelse {
        return null;
    };
    switch (present) {
        .document => |document| {
            return document;
        },
        .null, .undefined => {
            return null;
        },
        else => {
            return errors.throwError("Metadata that is a {s} value is not ported", .{@tagName(present)});
        },
    }
}

//
// Converts the metadata of a merge value to the Metadata object it is stored as (TypeScript: the metadata object
// itself). (No TypeScript counterpart.)
//
fn metadataToDocument(allocator: std.mem.Allocator, metadata: MergeValueMetadata) !Metadata {
    return BsonDocument.fromFields(allocator, &.{
        .{
            .key = "timestamp",
            .value = .{ .number = metadata.timestamp },
        },
        .{
            .key = "fields",
            .value = if (metadata.fields) |fields| .{ .document = fields } else .undefined,
        },
    });
}

//
// Merges two sets of fields recursively based on their metadata timestamps.
//
pub fn mergeFields(allocator: std.mem.Allocator, value1: MergeValue, value2: MergeValue) anyerror!MergeValue {

    var allKeys: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try js_value.objectKeys(allocator, value1.value)) |key| {
        try allKeys.put(allocator, key, {});
    }
    for (try js_value.objectKeys(allocator, value2.value)) |key| {
        try allKeys.put(allocator, key, {});
    }

    if (value1.metadata.fields) |fields| { // Accounts for deleted fields.
        for (fields.fields.items) |field| {
            try allKeys.put(allocator, field.key, {});
        }
    }

    if (value2.metadata.fields) |fields| { // Accounts for deleted fields.
        for (fields.fields.items) |field| {
            try allKeys.put(allocator, field.key, {});
        }
    }

    var mergeResultValue: BsonDocument = .empty;
    var mergeResultFields: BsonDocument = .empty;

    for (allKeys.keys()) |key| {
        const fieldMetadata1 = if (value1.metadata.fields) |fields| try optionalMetadata(fields.get(key)) else null;
        const fieldMetadata2 = if (value2.metadata.fields) |fields| try optionalMetadata(fields.get(key)) else null;
        const field1: MergeValue = .{
            .value = try js_value.getProperty(value1.value, key),
            .metadata = .{
                .timestamp = (if (fieldMetadata1) |metadata| try optionalNumber(metadata.get("timestamp")) else null) orelse value1.metadata.timestamp,
                .fields = (if (fieldMetadata1) |metadata| try optionalMetadata(metadata.get("fields")) else null) orelse .empty,
            },
        };
        const field2: MergeValue = .{
            .value = try js_value.getProperty(value2.value, key),
            .metadata = .{
                .timestamp = (if (fieldMetadata2) |metadata| try optionalNumber(metadata.get("timestamp")) else null) orelse value2.metadata.timestamp,
                .fields = (if (fieldMetadata2) |metadata| try optionalMetadata(metadata.get("fields")) else null) orelse .empty,
            },
        };
        const merged = try mergeValues(allocator, field1, field2);
        try mergeResultValue.put(allocator, key, merged.value);
        try mergeResultFields.put(allocator, key, .{ .document = try metadataToDocument(allocator, merged.metadata) });
    }

    return .{
        .value = .{ .document = mergeResultValue },
        .metadata = .{
            // Use Math.min because the root timestamp is a default for fields without explicit timestamps.
            // Using Math.min ensures fields without explicit timestamps don't appear newer than they should be.
            .timestamp = @min(value1.metadata.timestamp, value2.metadata.timestamp),
            .fields = mergeResultFields,
        },
    };
}

//
// Merges two values recursively based on their metadata timestamps.
// If both sides have a timestamp, the one with the newer timestamp wins.
// If one side has a timestamp and the other does not, the one with the timestamp side wins.
//
pub fn mergeValues(allocator: std.mem.Allocator, value1: MergeValue, value2: MergeValue) anyerror!MergeValue {

    const timestamp1 = value1.metadata.timestamp;
    const timestamp2 = value2.metadata.timestamp;

    if (isPrimitive(value1.value) or isPrimitive(value2.value)) {
        if (value1.value == .undefined) {
            // There is nothing for value 1, so value 2 wins.
            return value2;
        }
        else if (value2.value == .undefined) {
            // There is nothing for value 2, so value 1 wins.
            return value1;
        }

        // Value 1 or value 2 is a primitive, other side can be anything.
        // The one with the newer timestamp wins.
        return if (timestamp1 > timestamp2) value1 else value2;
    }
    else {
        // Both sides are objects. So merge them recursively.
        return mergeFields(allocator, value1, value2);
    }
}

//
// Cleans up empty fields in metadata recursively.
// Returns a new metadata object with empty fields removed.
//
pub fn cleanupMetadata(allocator: std.mem.Allocator, metadata: Metadata, timestamp: f64) anyerror!?Metadata {

    var cleanedMetadata: Metadata = .empty;
    try cleanedMetadata.put(allocator, "timestamp", metadata.get("timestamp") orelse .undefined);
    var cleanedFields: ?BsonDocument = null;

    if (try optionalMetadata(metadata.get("fields"))) |metadataFields| {
        for (metadataFields.fields.items) |field| {
            const fieldMetadataInput = try optionalMetadata(field.value) orelse {
                return errors.throwError("Metadata of field {s} that is missing is not ported", .{field.key});
            };
            const fieldMetadata = try cleanupMetadata(allocator, fieldMetadataInput, (try truthyNumber(metadata.get("timestamp"))) orelse timestamp);
            if (fieldMetadata) |cleanedField| {
                const fieldTimestamp = try truthyNumber(cleanedField.get("timestamp"));
                const nestedFields = try optionalMetadata(cleanedField.get("fields"));
                if (fieldTimestamp != null and fieldTimestamp.? > timestamp) {
                    if (cleanedFields == null) {
                        cleanedFields = .empty;
                    }
                    try cleanedFields.?.put(allocator, field.key, .{ .document = cleanedField });
                }
                else if (nestedFields != null and nestedFields.?.count() > 0) {
                    if (cleanedFields == null) {
                        cleanedFields = .empty;
                    }
                    try cleanedFields.?.put(allocator, field.key, .{ .document = cleanedField });
                }
            }
        }
    }

    if (cleanedFields) |fields| {
        try cleanedMetadata.put(allocator, "fields", .{ .document = fields });
    }

    const cleanedTimestamp = try truthyNumber(cleanedMetadata.get("timestamp"));
    if (cleanedFields != null and cleanedFields.?.count() > 0) {
        return cleanedMetadata;
    }
    else if (cleanedTimestamp == null or cleanedTimestamp.? <= timestamp) {
        return null;
    }
    else {
        return cleanedMetadata;
    }
}

//
// Merges two database records, combining their fields based on timestamp.
// Fields with the greater timestamp win. Both records must have the same _id.
// Returns a new IInternalRecord with merged fields and metadata.
//
pub fn mergeRecords(allocator: std.mem.Allocator, record1: IInternalRecord, record2: IInternalRecord) !IInternalRecord {
    if (!std.mem.eql(u8, record1._id, record2._id)) {
        return errors.throwError("Cannot merge records with different IDs: {s} vs {s}", .{ record1._id, record2._id });
    }

    const value1: MergeValue = .{
        .value = .{ .document = record1.fields },
        .metadata = .{
            .timestamp = (try truthyNumber(record1.metadata.get("timestamp"))) orelse 0,
            .fields = try optionalMetadata(record1.metadata.get("fields")),
        },
    };
    const value2: MergeValue = .{
        .value = .{ .document = record2.fields },
        .metadata = .{
            .timestamp = (try truthyNumber(record2.metadata.get("timestamp"))) orelse 0,
            .fields = try optionalMetadata(record2.metadata.get("fields")),
        },
    };

    // Merge fields recursively.
    const result = try mergeFields(allocator, value1, value2);

    // Clean up empty fields in metadata.
    const cleanedMetadata = try cleanupMetadata(allocator, try metadataToDocument(allocator, result.metadata), 0);

    const merged: IInternalRecord = .{
        ._id = record1._id,
        .fields = result.value.document,
        .metadata = cleanedMetadata orelse .empty,
    };

    return merged;
}

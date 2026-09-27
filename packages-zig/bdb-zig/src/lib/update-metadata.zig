const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const js_value = @import("js-value.zig");
const collection = @import("collection.zig");
const errors = utils.errors;
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const Metadata = collection.Metadata;

//
// Recursively updates metadata timestamps for fields that were changed.
// For nested objects, creates nested metadata structures.
// Returns a new metadata object (immutable) with only changed parts updated.
// (Zig: the fields and the updates are JavaScript values, as in updateFields; the timestamp is a JS number.)
//
pub fn updateMetadata(
    allocator: std.mem.Allocator,
    fields: BsonValue,
    updates: BsonValue,
    metadata: Metadata,
    timestamp: f64,
) !Metadata {
    if (updates == .null or updates == .undefined or (try js_value.objectKeys(allocator, updates)).len == 0) {
        // No updates to, return original metadata unchanged.
        return metadata;
    }

    //
    // PARTIAL FIX. The full one is still to come.
    //
    // A write is ordered after the record it was applied to, whatever the writing machine's clock
    // says. `timestamp` is that machine's clock reading, while the record's own timestamp came from
    // whichever machine wrote the record, which is usually a different one. On a device running
    // behind that machine, the reading is lower than the record's timestamp even though the write
    // happened later, and the sync merge then reads the edit as the older value and keeps the one it
    // replaced. Nothing reports it: the merged record comes out identical to the record already
    // stored, so the sync reports success and the edit is gone.
    //
    // That is what smoke test 45 was failing on. The emulator runs about 22 seconds behind the host,
    // and the test reaches its edit about 26 seconds after the host writes the record, so the edit
    // was being stamped about 4 seconds above the record and the test passed or failed on that
    // margin. Lifting the write above the record removes the margin, because an edit can no longer
    // be ordered before the value it replaced.
    //
    // What this does NOT fix: two machines editing the same record independently are still ordered
    // against each other by two unrelated wall clocks, so the one with the faster clock still wins
    // whichever wrote last. Removing that needs ordering that does not come from a clock at all
    // (vector clocks or hybrid logical clocks).
    //
    // This replaces an early return that skipped stamping altogether when the record was already
    // stamped at or above the writing clock. updateFields writes the new value either way, so that
    // path applied the edit and recorded nothing about when it was made, losing it by a shorter
    // route.
    //
    const writeTimestamp = @max(timestamp, try metadataTimestamp(metadata) + 1);

    // Start with all existing fields, then update/overwrite as needed.
    const existingFields = try metadataObject(metadata.get("fields") orelse .undefined);
    var newFields: BsonDocument = .{ .fields = try existingFields.fields.clone(allocator) };

    for (try js_value.objectKeys(allocator, updates)) |key| {
        if (try js_value.getProperty(updates, key) == .undefined) {
            // Field is being deleted - track deletion timestamp.
            try newFields.put(allocator, key, try timestampMetadata(allocator, writeTimestamp));
            continue;
        }

        const newValue = try js_value.getProperty(updates, key);
        const oldValue = try js_value.getProperty(fields, key);
        if (js_value.strictEquals(oldValue, newValue)) {
            // Value didn't change.
            continue;
        }

        // Value changed - handle nested objects or leaf fields.
        // Check if both old and new values are nested objects (not arrays) - same logic as updateFields.
        const isNewObject = js_value.isObject(newValue);
        const isOldObject = js_value.isObject(oldValue);
        if (isNewObject and isOldObject) {
            // Both are nested objects - recurse (same logic as updateFields).
            const nestedResult = try updateMetadata(allocator, oldValue, newValue, try metadataObject(existingFields.get(key) orelse .undefined), writeTimestamp);

            // Check if nested metadata actually has tracked fields.
            const nestedFields = try metadataObject(nestedResult.get("fields") orelse .undefined);
            const hasTrackedFields = nestedFields.count() > 0;
            if (hasTrackedFields) {
                // Something changed in the nested object and it has tracked fields.
                try newFields.put(allocator, key, .{ .document = nestedResult });
            }
            else {
                // No tracked fields - remove from newFields.
                _ = newFields.remove(key);
            }
        }
        else {
            // Primivite value or converting to/from object.
            try newFields.put(allocator, key, try timestampMetadata(allocator, writeTimestamp));
        }
    }

    // Return new metadata with updated fields.
    return BsonDocument.fromFields(allocator, &.{
        .{
            .key = "timestamp",
            .value = metadata.get("timestamp") orelse .undefined,
        },
        .{
            .key = "fields",
            .value = .{ .document = newFields },
        },
    });
}

//
// Returns `metadata.timestamp ?? 0` (No TypeScript counterpart: TypeScript reads the property inline). Throws for a
// timestamp that is not a number, whose `+ 1` is not ported.
//
fn metadataTimestamp(metadata: Metadata) !f64 {
    const value = metadata.get("timestamp") orelse .undefined;
    switch (value) {
        .number => |number| {
            return number;
        },
        .null, .undefined => {
            return 0;
        },
        else => {
            return errors.throwError("A metadata timestamp that is a {s} value is not ported", .{@tagName(value)});
        },
    }
}

//
// Returns `value || {}` for a metadata object (No TypeScript counterpart: TypeScript writes it inline). Throws for a
// value that is neither a document nor missing, which is not ported.
//
fn metadataObject(value: BsonValue) !Metadata {
    switch (value) {
        .document => |document| {
            return document;
        },
        .null, .undefined => {
            return .empty;
        },
        else => {
            return errors.throwError("Metadata that is a {s} value is not ported", .{@tagName(value)});
        },
    }
}

//
// Builds the leaf metadata `{ timestamp: writeTimestamp }` (No TypeScript counterpart: TypeScript writes the object
// literal inline).
//
fn timestampMetadata(allocator: std.mem.Allocator, writeTimestamp: f64) !BsonValue {
    return .{
        .document = try BsonDocument.fromFields(allocator, &.{
            .{
                .key = "timestamp",
                .value = .{ .number = writeTimestamp },
            },
        }),
    };
}

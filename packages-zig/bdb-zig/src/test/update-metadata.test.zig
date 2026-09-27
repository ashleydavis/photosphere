const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const Metadata = bdb.collection.Metadata;
const updateMetadata = bdb.update_metadata.updateMetadata;
const property = helpers.property;
const stringValue = helpers.stringValue;
const numberValue = helpers.numberValue;
const objectValue = helpers.objectValue;

//
// Returns `metadata.fields` (null when it is undefined).
//
fn fieldsOf(metadata: Metadata) ?BsonDocument {
    const value = metadata.get("fields") orelse {
        return null;
    };
    if (value != .document) {
        return null;
    }
    return value.document;
}

//
// Returns `metadata.fields![key]` (null when it is undefined).
//
fn entry(metadata: Metadata, key: []const u8) ?Metadata {
    const fields = fieldsOf(metadata) orelse {
        return null;
    };
    const value = fields.get(key) orelse {
        return null;
    };
    if (value != .document) {
        return null;
    }
    return value.document;
}

//
// Returns `metadata.timestamp` (null when it is undefined).
//
fn timestampOf(metadata: Metadata) ?f64 {
    const value = metadata.get("timestamp") orelse {
        return null;
    };
    if (value != .number) {
        return null;
    }
    return value.number;
}

//
// Builds a Metadata object literal.
//
fn metadataOf(allocator: std.mem.Allocator, properties: []const bson.BsonField) !Metadata {
    return (try objectValue(allocator, properties)).document;
}

//
// Builds the leaf metadata literal `{ timestamp }`.
//
fn leaf(allocator: std.mem.Allocator, timestamp: f64) !BsonValue {
    return objectValue(allocator, &.{property("timestamp", numberValue(timestamp))});
}

test "should always create fields metadata when field changes, regardless of timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 999;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Field metadata should be created
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expectEqual(@as(?f64, 999), timestampOf(entry(result, "name").?));
}

test "should create fields metadata when field changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{});

    const result = try updateMetadata(allocator, fields, updates, metadata, 2000);

    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
    try std.testing.expect(entry(result, "age") == null);
}

test "should not create metadata entry for unchanged values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", numberValue(30)) }); // age unchanged
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
    try std.testing.expect(entry(result, "age") == null);
}

test "should update metadata entry when value changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    var metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 1500)),
        })),
    });
    const timestamp = 2000;

    // First update changes name
    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);
    try std.testing.expect(entry(result, "name") != null);

    // Second update changes it back
    const fields2 = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const updates2 = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const timestamp2 = 2500;
    metadata = result; // Need to update for next call
    const result2 = try updateMetadata(allocator, fields2, updates2, metadata, timestamp2);

    // Should still have metadata since it changed
    try std.testing.expectEqual(@as(?f64, 2500), timestampOf(entry(result2, "name").?));
}

test "should preserve metadata entry when value is unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("John"))}); // Same value
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 1500)),
        })),
    });
    const timestamp = 2000;

    // Update with same value - metadata should be preserved
    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Metadata should still exist with original timestamp
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expectEqual(@as(?f64, 1500), timestampOf(entry(result, "name").?)); // Original timestamp preserved
}

test "should handle deleting a field (undefined value)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", .undefined) });
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("age", try leaf(allocator, 1500)),
        })),
    });
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "name") != null);
    // Deletion timestamp should be preserved when newer than parent
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "age").?)); // Deletion timestamp
}

test "should handle nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("New York")),
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "address") != null);

    const addressMeta = entry(result, "address").?;
    try std.testing.expect(fieldsOf(addressMeta) != null);
    try std.testing.expect(entry(addressMeta, "street") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(addressMeta, "street").?));
    try std.testing.expect(entry(addressMeta, "city") == null); // Unchanged
}

test "should handle deeply nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("country", try objectValue(allocator, &.{
                property("code", stringValue("US")),
                property("name", stringValue("United States")),
            })),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            //fio: ...fields.address,
            property("country", try objectValue(allocator, &.{
                property("code", stringValue("CA")),
                property("name", stringValue("Canada")),
            })),
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "address") != null);

    const addressMeta = entry(result, "address").?;
    const countryMeta = entry(addressMeta, "country").?;
    try std.testing.expect(fieldsOf(countryMeta) != null);
    try std.testing.expect(entry(countryMeta, "code") != null);
    try std.testing.expect(entry(countryMeta, "name") != null);
}

test "should handle arrays (treat as leaf values)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var oldTags = [_]BsonValue{ stringValue("a"), stringValue("b") };
    var newTags = [_]BsonValue{ stringValue("c"), stringValue("d") };
    const fields = try objectValue(allocator, &.{property("tags", .{ .array = &oldTags })});
    const updates = try objectValue(allocator, &.{property("tags", .{ .array = &newTags })});
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Arrays should be treated as leaf values, not nested objects
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "tags") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "tags").?));
}

test "should handle null values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("email", .null) });
    const updates = try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("john@example.com")) });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "name") != null);
    try std.testing.expect(entry(result, "email") != null);
}

test "should handle mixed updates (some nested, some leaf)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
        property("age", numberValue(30)),
    });
    const updates = try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("New York")),
        })),
        property("age", numberValue(31)),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "name") != null);
    try std.testing.expect(entry(result, "address") != null);
    const addressMeta3 = entry(result, "address").?;
    try std.testing.expect(entry(addressMeta3, "street") != null);
    try std.testing.expect(entry(addressMeta3, "city") == null);
    try std.testing.expect(entry(result, "age") != null);
}

test "should handle updating nested object where some fields are new" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("New York")), // New field
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "address") != null);
    const addressMeta4 = entry(result, "address").?;
    try std.testing.expect(entry(addressMeta4, "street") != null);
    try std.testing.expect(entry(addressMeta4, "city") != null); // New field gets timestamp
}

test "should preserve existing nested metadata structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("Boston")),
        })),
    });
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("address", try objectValue(allocator, &.{
                property("fields", try objectValue(allocator, &.{
                    property("street", try leaf(allocator, 500)),
                })),
            })),
        })),
    });
    const timestamp = 2000;
    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);
    const addressMeta = entry(result, "address").?;
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(addressMeta, "street").?));
    try std.testing.expect(entry(addressMeta, "city") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(addressMeta, "city").?));
}

test "should handle empty updates object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{});
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;
    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Should not create fields if no updates
    try std.testing.expect(fieldsOf(result) == null);
}

test "should handle updating single field multiple times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    var metadata = try metadataOf(allocator, &.{});

    // First update
    const updates1 = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const result1 = try updateMetadata(allocator, fields, updates1, metadata, 2000);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result1, "name").?));

    // Second update
    const fields2 = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const updates2 = try objectValue(allocator, &.{property("name", stringValue("Bob"))});
    metadata = result1; // Need to update for next call
    const result2 = try updateMetadata(allocator, fields2, updates2, metadata, 3000);
    try std.testing.expectEqual(@as(?f64, 3000), timestampOf(entry(result2, "name").?));
}

test "should handle updating nested object to null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", .null),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // When nested object is set to null, it becomes a leaf value (has timestamp)
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "address").?));
    try std.testing.expect(entry(result, "address").?.get("fields") == null);
}

test "should handle updating null to nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", .null),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const timestamp = 2000;
    const result = try updateMetadata(allocator, fields, updates, try metadataOf(allocator, &.{}), timestamp);

    // When updating from null to nested object, it becomes a nested object (no timestamp).
    try std.testing.expect(entry(result, "address") != null);

    // Should recurse into nested object.
    const addressMeta = entry(result, "address").?;
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(addressMeta));
    try std.testing.expect(fieldsOf(addressMeta) == null);
}

test "should handle empty nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{})),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "address") != null);
    const addressMeta7 = entry(result, "address").?;
    try std.testing.expect(entry(addressMeta7, "street") != null);
}

test "should handle boolean values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("active", .{ .boolean = false })});
    const updates = try objectValue(allocator, &.{property("active", .{ .boolean = true })});
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "active") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "active").?));
}

test "should handle number values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("count", numberValue(0))});
    const updates = try objectValue(allocator, &.{property("count", numberValue(5))});
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "count") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "count").?));
}

test "should handle string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("text", stringValue("old"))});
    const updates = try objectValue(allocator, &.{property("text", stringValue("new"))});
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "text") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "text").?));
}

test "should always track field metadata regardless of parent timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", numberValue(31)) });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000; // Same as parent

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // We always track field metadata now, regardless of parent timestamp
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "age").?));
}

test "should handle nested object optimization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("Boston")),
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000; // Same as parent

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // We always track field metadata now, even if timestamp equals parent
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "address") != null);
    const addressMeta8 = entry(result, "address").?;
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(addressMeta8, "street").?));
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(addressMeta8, "city").?));
}

test "should handle partial nested object updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
            property("zip", stringValue("10001")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("New York")), // Unchanged
            property("zip", stringValue("10001")), // Unchanged
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    const addressMeta9 = entry(result, "address").?;
    try std.testing.expect(entry(addressMeta9, "street") != null);
    try std.testing.expect(entry(addressMeta9, "city") == null);
    try std.testing.expect(entry(addressMeta9, "zip") == null);
}

test "should handle updating multiple nested objects at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("home", try objectValue(allocator, &.{property("street", stringValue("123 Main"))})),
        property("work", try objectValue(allocator, &.{property("street", stringValue("456 Oak"))})),
    });
    const updates = try objectValue(allocator, &.{
        property("home", try objectValue(allocator, &.{property("street", stringValue("789 Pine"))})),
        property("work", try objectValue(allocator, &.{property("street", stringValue("456 Oak"))})), // Unchanged
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expect(entry(result, "home") != null);
    const homeMeta = entry(result, "home").?;
    try std.testing.expect(entry(homeMeta, "street") != null);
    // work didn't change, so no metadata should be created for it
    try std.testing.expect(entry(result, "work") == null);
}

test "should handle deleting nested field within nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
            property("zip", stringValue("10001")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
            property("zip", .undefined), // Delete zip
        })),
    });
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("address", try objectValue(allocator, &.{
                property("fields", try objectValue(allocator, &.{
                    property("zip", try leaf(allocator, 1500)),
                })),
            })),
        })),
    });
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // zip was deleted with timestamp 2000
    // Deletion timestamp should be preserved
    const addressMeta10 = entry(result, "address").?;
    try std.testing.expect(fieldsOf(addressMeta10) != null);
    try std.testing.expect(entry(addressMeta10, "zip") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(addressMeta10, "zip").?)); // Deletion timestamp
}

// These two used to assert that a write from a clock at or below the record's timestamp was left
// unstamped. updateFields wrote the value anyway, so the record ended up holding a new value with
// nothing saying when it was made, and the next sync merge read it as the older side and threw it
// away. A write is now stamped above the record it changed instead. See the comment block in
// update-metadata.zig.

test "should stamp the write above the record when metadata.timestamp is greater than update timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(3000)),
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 2500)),
        })),
    });
    const timestamp = 2000; // Older than metadata.timestamp

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // The record's own timestamp is untouched; the changed field is lifted above it.
    try std.testing.expectEqual(@as(?f64, 3000), timestampOf(result));
    try std.testing.expectEqual(@as(?f64, 3001), timestampOf(entry(result, "name").?));
}

test "should stamp the write above the record when metadata.timestamp equals update timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(2000)),
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 1500)),
        })),
    });
    const timestamp = 2000; // Equal to metadata.timestamp

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(result));
    try std.testing.expectEqual(@as(?f64, 2001), timestampOf(entry(result, "name").?));
}

test "should use the writing clock when it is already above the record" {
    // The ordinary case, where the machine making the edit is not running behind the one that
    // wrote the record. The clock reading is used as it stands, not lifted.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(2000)),
    });
    const timestamp = 5000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expectEqual(@as(?f64, 5000), timestampOf(entry(result, "name").?));
}

test "should stamp a deletion above the record when the writing clock is behind it" {
    // Deletions are stamped on the same path and lose the same way: a tombstone below the record
    // it removes is read as the older side and the deleted value comes back.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", .undefined)});
    const metadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(3000)),
    });
    const timestamp = 1000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    try std.testing.expectEqual(@as(?f64, 3001), timestampOf(entry(result, "name").?));
}

test "should preserve root timestamp in result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(1000)),
    });
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Root timestamp should be preserved
    try std.testing.expectEqual(@as(?f64, 1000), timestampOf(result));
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
}

test "should preserve existing fields metadata not in updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)), property("email", stringValue("john@example.com")) });
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))}); // Only updating name
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("age", try leaf(allocator, 1500)),
            property("email", try leaf(allocator, 1600)),
        })),
    });
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Updated field should have new timestamp
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
    // Other fields should be preserved
    try std.testing.expectEqual(@as(?f64, 1500), timestampOf(entry(result, "age").?));
    try std.testing.expectEqual(@as(?f64, 1600), timestampOf(entry(result, "email").?));
}

test "should preserve existing nested metadata when all nested fields unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")), // Unchanged
            property("city", stringValue("New York")), // Unchanged
        })),
    });
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("address", try objectValue(allocator, &.{
                property("fields", try objectValue(allocator, &.{
                    property("street", try leaf(allocator, 1500)),
                    property("city", try leaf(allocator, 1500)),
                })),
            })),
        })),
    });
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Since all fields in address are unchanged in this update,
    // existing nested metadata should be preserved (function doesn't remove existing metadata)
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "address") != null);
    try std.testing.expectEqual(@as(?f64, 1500), timestampOf(entry(entry(result, "address").?, "street").?));
    try std.testing.expectEqual(@as(?f64, 1500), timestampOf(entry(entry(result, "address").?, "city").?));
}

test "should handle converting object to array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var items = [_]BsonValue{ numberValue(1), numberValue(2), numberValue(3) };
    const fields = try objectValue(allocator, &.{
        property("items", try objectValue(allocator, &.{ property("a", numberValue(1)), property("b", numberValue(2)) })),
    });
    const updates = try objectValue(allocator, &.{
        property("items", .{ .array = &items }), // Converting object to array
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Arrays are treated as leaf values
    try std.testing.expect(entry(result, "items") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "items").?));
    try std.testing.expect(entry(result, "items").?.get("fields") == null);
}

test "should handle converting array to object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var items = [_]BsonValue{ numberValue(1), numberValue(2), numberValue(3) };
    const fields = try objectValue(allocator, &.{
        property("items", .{ .array = &items }),
    });
    const updates = try objectValue(allocator, &.{
        property("items", try objectValue(allocator, &.{ property("a", numberValue(1)), property("b", numberValue(2)) })), // Converting array to object
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Object should be treated as nested, but since it's a type change, it becomes a leaf
    try std.testing.expect(entry(result, "items") != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "items").?));
    try std.testing.expect(entry(result, "items").?.get("fields") == null);
}

test "should handle null updates parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates: BsonValue = .null;
    const metadata = try metadataOf(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 1500)),
        })),
    });
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Should return original metadata unchanged
    try std.testing.expect(result.fields.items.ptr == metadata.fields.items.ptr);
}

test "should not mutate original metadata object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const metadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("age", try leaf(allocator, 1500)),
        })),
    });
    const timestamp = 2000;

    const originalMetadata = try metadataOf(allocator, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("age", try leaf(allocator, 1500)),
        })),
    });
    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Original metadata should be unchanged
    try std.testing.expectEqual(timestampOf(originalMetadata), timestampOf(metadata));
    try std.testing.expectEqual(timestampOf(entry(originalMetadata, "age").?), timestampOf(entry(metadata, "age").?));
    try std.testing.expect(entry(metadata, "name") == null);

    // Result should be a new object
    try std.testing.expect(result.fields.items.ptr != metadata.fields.items.ptr);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
}

test "should not create nested metadata when all nested fields unchanged from empty metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("New York")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")), // Unchanged
            property("city", stringValue("New York")), // Unchanged
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Since all fields are unchanged and we started with empty metadata,
    // the recursive call processes unchanged values and skips them,
    // resulting in nested metadata with no tracked fields, which gets deleted
    // Since address wasn't in existingFields, newFields remains empty {}
    try std.testing.expect(fieldsOf(result) != null);
    try std.testing.expect(entry(result, "address") == null);
}

test "should handle nested object to array conversion in nested field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var items = [_]BsonValue{ numberValue(1), numberValue(2) };
    const fields = try objectValue(allocator, &.{
        property("data", try objectValue(allocator, &.{
            property("items", try objectValue(allocator, &.{property("a", numberValue(1))})),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("data", try objectValue(allocator, &.{
            property("items", .{ .array = &items }), // Converting nested object to array
        })),
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Should track the nested change
    const dataMeta = entry(result, "data").?;
    try std.testing.expect(fieldsOf(dataMeta) != null);
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(dataMeta, "items").?));
    try std.testing.expect(entry(dataMeta, "items").?.get("fields") == null);
}

test "should handle updating to undefined when field does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("nonexistent", .undefined), // Deleting a field that doesn't exist
    });
    const metadata = try metadataOf(allocator, &.{});
    const timestamp = 2000;

    const result = try updateMetadata(allocator, fields, updates, metadata, timestamp);

    // Should still track deletion timestamp for undefined field
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "name").?));
    try std.testing.expectEqual(@as(?f64, 2000), timestampOf(entry(result, "nonexistent").?));
}

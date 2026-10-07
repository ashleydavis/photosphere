//
// Tests for cleanupMetadata (port of src/tests/cleanup-metadata.test.ts).
//

const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const js_object_builders = @import("js-object-builders.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const Metadata = bdb.collection.Metadata;
const cleanupMetadata = bdb.merge_records.cleanupMetadata;
const property = js_object_builders.property;
const numberValue = js_object_builders.numberValue;
const objectValue = js_object_builders.objectValue;

//
// The largest integer a JavaScript number holds exactly (Number.MAX_SAFE_INTEGER).
//
const MAX_SAFE_INTEGER: f64 = 9007199254740991;

//
// Builds the metadata literal `{ timestamp }`.
//
fn leaf(allocator: std.mem.Allocator, timestamp: f64) !BsonValue {
    return objectValue(allocator, &.{property("timestamp", numberValue(timestamp))});
}

//
// Builds the metadata literal `{ timestamp, fields }`.
//
fn node(allocator: std.mem.Allocator, timestamp: f64, fields: []const bson.BsonField) !BsonValue {
    return objectValue(allocator, &.{
        property("timestamp", numberValue(timestamp)),
        property("fields", try objectValue(allocator, fields)),
    });
}

//
// Builds the metadata literal `{ timestamp, fields }` as a Metadata.
//
fn metadataOf(allocator: std.mem.Allocator, timestamp: f64, fields: []const bson.BsonField) !Metadata {
    return (try node(allocator, timestamp, fields)).document;
}

//
// Reads `metadata.fields` (null when it is undefined).
//
fn fieldsOf(metadata: Metadata) ?BsonDocument {
    const fields = metadata.get("fields") orelse {
        return null;
    };
    if (fields == .undefined) {
        return null;
    }
    return fields.document;
}

//
// Reads `fields[key]` (null when it is undefined).
//
fn child(fields: BsonDocument, key: []const u8) ?Metadata {
    const entry = fields.get(key) orelse {
        return null;
    };
    if (entry == .undefined) {
        return null;
    }
    return entry.document;
}

//
// Reads `metadata.timestamp`.
//
fn timestampOf(metadata: Metadata) f64 {
    return metadata.get("timestamp").?.number;
}

test "should return undefined for metadata with timestamp less than or equal to cutoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = (try leaf(allocator, 1000)).document;

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result == null);
}

test "should return metadata with timestamp greater than cutoff when no fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = (try leaf(allocator, 3000)).document;

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 3000), timestampOf(result.?));
    try std.testing.expect(fieldsOf(result.?) == null);
}

test "should return undefined when timestamp is equal to cutoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = (try leaf(allocator, 2000)).document;

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result == null);
}

test "should preserve fields with timestamps greater than cutoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("field1", try leaf(allocator, 3000)),
        property("field2", try leaf(allocator, 2500)),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(result.?));
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field1") != null);
    try std.testing.expectEqual(@as(f64, 3000), timestampOf(child(fieldsOf(result.?).?, "field1").?));
    try std.testing.expect(child(fieldsOf(result.?).?, "field2") != null);
    try std.testing.expectEqual(@as(f64, 2500), timestampOf(child(fieldsOf(result.?).?, "field2").?));
}

test "should remove fields with timestamps less than or equal to cutoff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("field1", try leaf(allocator, 3000)),
        property("field2", try leaf(allocator, 1500)), // removed
        property("field3", try leaf(allocator, 2000)), // removed (equal)
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field1") != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field2") == null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field3") == null);
}

test "should preserve fields with nested fields even if timestamp is old" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("nested", try node(allocator, 1500, &.{ // old timestamp
            property("inner", try leaf(allocator, 3000)), // but has new nested field
        })),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expect(fieldsOf(result.?) != null);
    const nested = child(fieldsOf(result.?).?, "nested");
    try std.testing.expect(nested != null);
    try std.testing.expect(fieldsOf(nested.?) != null);
    try std.testing.expectEqual(@as(f64, 3000), timestampOf(child(fieldsOf(nested.?).?, "inner").?));
}

test "should remove fields with no nested fields and old timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("field1", try leaf(allocator, 3000)),
        property("field2", try node(allocator, 1500, &.{})), // empty nested fields
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field1") != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field2") == null); // removed because timestamp is old and no valid nested fields
}

test "should recursively clean up nested metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("level1", try node(allocator, 2000, &.{
            property("level2", try node(allocator, 1500, &.{ // should be removed
                property("level3", try leaf(allocator, 3000)), // should be preserved
            })),
            property("level2b", try leaf(allocator, 500)), // should be removed
        })),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    const level1 = child(fieldsOf(result.?).?, "level1");
    try std.testing.expect(level1 != null);
    try std.testing.expect(fieldsOf(level1.?) != null);
    const level2 = child(fieldsOf(level1.?).?, "level2");
    try std.testing.expect(level2 != null); // preserved because it has nested fields
    try std.testing.expectEqual(@as(f64, 3000), timestampOf(child(fieldsOf(level2.?).?, "level3").?));
    try std.testing.expect(child(fieldsOf(level1.?).?, "level2b") == null); // removed
}

test "should return undefined when root timestamp is old and no valid fields remain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("field1", try leaf(allocator, 1500)),
        property("field2", try leaf(allocator, 1800)),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result == null);
}

test "should return metadata when root timestamp is old but valid fields exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("field1", try leaf(allocator, 1500)),
        property("field2", try leaf(allocator, 3000)), // valid field
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(result.?));
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field2") != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field1") == null);
}

test "should handle deeply nested structures with all valid timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 5000, &.{
        property("a", try node(allocator, 4000, &.{
            property("b", try node(allocator, 3000, &.{
                property("c", try leaf(allocator, 6000)),
            })),
        })),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 5000), timestampOf(result.?));
    const a = child(fieldsOf(result.?).?, "a");
    try std.testing.expect(a != null);
    const b = child(fieldsOf(a.?).?, "b");
    try std.testing.expect(b != null);
    try std.testing.expect(child(fieldsOf(b.?).?, "c") != null);
}

test "should handle metadata without timestamp property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = (try objectValue(allocator, &.{
        property("fields", try objectValue(allocator, &.{property("field1", try leaf(allocator, 3000))})),
    })).document;

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field1") != null);
}

test "should handle empty fields object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{});

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result == null);
}

test "should handle undefined fields property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = (try leaf(allocator, 3000)).document;

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 3000), timestampOf(result.?));
    try std.testing.expect(fieldsOf(result.?) == null);
}

test "should use provided timestamp as fallback when metadata timestamp is undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = (try objectValue(allocator, &.{
        property("fields", try objectValue(allocator, &.{
            property("field1", try node(allocator, 1500, &.{property("inner", try leaf(allocator, 3000))})),
        })),
    })).document;

    // When cleaning nested field, if it has no timestamp, use the provided timestamp
    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    // field1 has timestamp 1500 < 2000, but has nested fields
    // The nested field inner has timestamp 3000 > 2000
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "field1") != null);
}

test "should preserve complex nested structure with mixed timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("user", try node(allocator, 2500, &.{
            property("name", try leaf(allocator, 3000)),
            property("email", try leaf(allocator, 1500)), // old
            property("address", try node(allocator, 1800, &.{ // old
                property("street", try leaf(allocator, 3500)), // new
                property("city", try leaf(allocator, 1200)), // old
            })),
        })),
        property("settings", try node(allocator, 500, &.{ // old
            property("theme", try leaf(allocator, 4000)), // new
        })),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    const user = child(fieldsOf(result.?).?, "user");
    try std.testing.expect(user != null);
    try std.testing.expect(child(fieldsOf(user.?).?, "name") != null);
    try std.testing.expect(child(fieldsOf(user.?).?, "email") == null);
    const address = child(fieldsOf(user.?).?, "address");
    try std.testing.expect(address != null); // preserved because has nested fields
    try std.testing.expect(child(fieldsOf(address.?).?, "street") != null);
    try std.testing.expect(child(fieldsOf(address.?).?, "city") == null);
    const settings = child(fieldsOf(result.?).?, "settings");
    try std.testing.expect(settings != null); // preserved because has nested fields
    try std.testing.expect(child(fieldsOf(settings.?).?, "theme") != null);
}

test "should handle cutoff timestamp of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("field1", try leaf(allocator, -100)),
        property("field2", try leaf(allocator, 500)),
    });

    const result = try cleanupMetadata(allocator, metadata, 0);

    // field1 (-100) and field2 (500) both have timestamps < root timestamp (1000)
    // So when cleaning them with root timestamp 1000 as cutoff, both are removed
    // But root timestamp 1000 > 0, so metadata is returned without fields
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(result.?));
    try std.testing.expect(fieldsOf(result.?) == null);
}

test "should handle very large timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, MAX_SAFE_INTEGER, &.{
        property("field1", try leaf(allocator, MAX_SAFE_INTEGER - 1)),
    });

    const result = try cleanupMetadata(allocator, metadata, MAX_SAFE_INTEGER - 2);

    // field1 has timestamp Number.MAX_SAFE_INTEGER - 1
    // When cleaning with root timestamp (Number.MAX_SAFE_INTEGER) as cutoff,
    // field1 is removed because (Number.MAX_SAFE_INTEGER - 1) <= Number.MAX_SAFE_INTEGER
    // But root timestamp > cutoff, so metadata is returned without fields
    try std.testing.expect(result != null);
    try std.testing.expectEqual(MAX_SAFE_INTEGER, timestampOf(result.?));
    try std.testing.expect(fieldsOf(result.?) == null);
}

test "should remove all nested fields when they are all old" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("level1", try node(allocator, 1500, &.{
            property("level2", try node(allocator, 1200, &.{
                property("level3", try leaf(allocator, 1800)),
            })),
        })),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    // All timestamps are < 2000, but the nested structure is preserved
    // because level3 has fields (empty object from cleanup), so the structure
    // is kept even though timestamps are old
    try std.testing.expect(result != null);
    // The structure is preserved because nested fields exist
    try std.testing.expect(fieldsOf(result.?) != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "level1") != null);
}

test "should preserve structure when only leaf nodes are new" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1000, &.{
        property("a", try node(allocator, 500, &.{
            property("b", try node(allocator, 300, &.{
                property("c", try leaf(allocator, 5000)), // only this is new
            })),
        })),
    });

    const result = try cleanupMetadata(allocator, metadata, 2000);

    try std.testing.expect(result != null);
    const a = child(fieldsOf(result.?).?, "a");
    try std.testing.expect(a != null);
    const b = child(fieldsOf(a.?).?, "b");
    try std.testing.expect(b != null);
    const c = child(fieldsOf(b.?).?, "c");
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(f64, 5000), timestampOf(c.?));
}

// mergeRecords calls this with a cutoff of 0, and the recursion then measures each field against
// the record's own timestamp rather than that 0. So an edited field keeps its stamp only while
// that stamp is above the record's. When the winning side's field carries no stamp of its own and
// has inherited the record's, the two are equal and the entry is dropped, which is what leaves a
// merged record byte-for-byte identical to the one it was merged into. This holds the surviving
// case still: a field genuinely edited after the record was created keeps its timestamp.
test "a field stamped later than the record survives the cleanup mergeRecords performs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1786316805276, &.{
        property("description", try leaf(allocator, 1786316809381)),
    });

    const result = try cleanupMetadata(allocator, metadata, 0);

    try std.testing.expect(result != null);
    try std.testing.expect(child(fieldsOf(result.?).?, "description") != null);
    try std.testing.expectEqual(@as(f64, 1786316809381), timestampOf(child(fieldsOf(result.?).?, "description").?));
}

test "a field stamped no later than the record is dropped by the cleanup mergeRecords performs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = try metadataOf(allocator, 1786316805276, &.{
        property("description", try leaf(allocator, 1786316805276)),
    });

    const result = try cleanupMetadata(allocator, metadata, 0);

    try std.testing.expect(result != null);
    try std.testing.expect(fieldsOf(result.?) == null);
}

//
// Tests for mergeFields (port of src/tests/merge-fields.test.ts).
//

const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const js_object_builders = @import("js-object-builders.zig");
const to_equal = @import("to-equal.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const MergeValue = bdb.merge_records.MergeValue;
const mergeFields = bdb.merge_records.mergeFields;
const property = js_object_builders.property;
const stringValue = js_object_builders.stringValue;
const numberValue = js_object_builders.numberValue;
const objectValue = js_object_builders.objectValue;
const toEqual = to_equal.toEqual;

//
// Builds a merge value without nested field metadata (TypeScript: `{ value, metadata: { timestamp } }`).
//
fn plain(value: BsonValue, timestamp: f64) MergeValue {
    return .{
        .value = value,
        .metadata = .{
            .timestamp = timestamp,
            .fields = null,
        },
    };
}

//
// Builds a merge value with field metadata (TypeScript: `{ value, metadata: { timestamp, fields } }`).
//
fn withFields(value: BsonValue, timestamp: f64, fields: BsonDocument) MergeValue {
    return .{
        .value = value,
        .metadata = .{
            .timestamp = timestamp,
            .fields = fields,
        },
    };
}

//
// Builds a document from its properties.
//
fn documentOf(allocator: std.mem.Allocator, properties: []const bson.BsonField) !BsonDocument {
    return BsonDocument.fromFields(allocator, properties);
}

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
// Reads `fields[key].timestamp`.
//
fn timestampOf(fields: BsonDocument, key: []const u8) f64 {
    return fields.get(key).?.document.get("timestamp").?.number;
}

//
// Reads `fields[key].fields`.
//
fn nestedFields(fields: BsonDocument, key: []const u8) BsonDocument {
    return fields.get(key).?.document.get("fields").?.document;
}

//
// Reads `value[key]` of a document value (undefined when it has no such field).
//
fn get(value: BsonValue, key: []const u8) BsonValue {
    return value.document.get(key) orelse .undefined;
}

test "should merge simple flat objects with different timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }), 1000);
    const value2 = plain(try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }), 2000);

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{
        property("name", stringValue("Jane")), // newer timestamp wins
        property("age", numberValue(30)), // only in value 1
        property("email", stringValue("jane@example.com")), // only in value 2
    })));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp); // Math.min of both timestamps
    try std.testing.expect(result.metadata.fields != null);
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "name"));
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(result.metadata.fields.?, "age"));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "email"));
}

test "should merge when value1 has newer timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }), 2000);
    const value2 = plain(try objectValue(allocator, &.{property("name", stringValue("Jane"))}), 1000);

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(get(result.value, "name").eql(stringValue("John"))); // value1 has newer timestamp
    try std.testing.expect(get(result.value, "age").eql(numberValue(30)));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp); // Math.min
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "name"));
}

test "should handle empty objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{}), 1000);
    const value2 = plain(try objectValue(allocator, &.{}), 2000);

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{})));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp);
    try std.testing.expect(toEqual(.{ .document = result.metadata.fields.? }, try objectValue(allocator, &.{})));
}

test "should merge nested objects recursively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{
            property("user", try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) })),
            property("settings", try objectValue(allocator, &.{property("theme", stringValue("dark"))})),
        }),
        1000,
        try documentOf(allocator, &.{
            property("user", try node(allocator, 1000, &.{
                property("name", try leaf(allocator, 1000)),
                property("age", try leaf(allocator, 1000)),
            })),
            property("settings", try node(allocator, 1000, &.{property("theme", try leaf(allocator, 1000))})),
        }),
    );
    const value2 = withFields(
        try objectValue(allocator, &.{
            property("user", try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) })),
            property("settings", try objectValue(allocator, &.{ property("theme", stringValue("light")), property("fontSize", numberValue(14)) })),
        }),
        2000,
        try documentOf(allocator, &.{
            property("user", try node(allocator, 2000, &.{
                property("name", try leaf(allocator, 2000)),
                property("email", try leaf(allocator, 2000)),
            })),
            property("settings", try node(allocator, 2000, &.{
                property("theme", try leaf(allocator, 2000)),
                property("fontSize", try leaf(allocator, 2000)),
            })),
        }),
    );

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(toEqual(get(result.value, "user"), try objectValue(allocator, &.{
        property("name", stringValue("Jane")), // newer timestamp
        property("age", numberValue(30)), // value2 doesn't have age (undefined), so value1 wins
        property("email", stringValue("jane@example.com")), // only in value2
    })));
    try std.testing.expect(toEqual(get(result.value, "settings"), try objectValue(allocator, &.{
        property("theme", stringValue("light")), // newer timestamp
        property("fontSize", numberValue(14)), // only in value2
    })));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(nestedFields(result.metadata.fields.?, "user"), "name"));
    // age: value1 has it, value2 doesn't (undefined), so value1 wins
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(nestedFields(result.metadata.fields.?, "user"), "age"));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(nestedFields(result.metadata.fields.?, "settings"), "theme"));
}

test "should handle fields with field-level metadata timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }),
        1000,
        try documentOf(allocator, &.{property("name", try leaf(allocator, 1500))}), // name has newer timestamp than root
    );
    const value2 = withFields(
        try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }),
        2000,
        try documentOf(allocator, &.{property("name", try leaf(allocator, 1200))}), // name has older timestamp than root but newer than value1 root
    );

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(get(result.value, "name").eql(stringValue("John"))); // value1.name timestamp (1500) > value2.name timestamp (1200)
    try std.testing.expectEqual(@as(f64, 1500), timestampOf(result.metadata.fields.?, "name"));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp); // Math.min of root timestamps
}

test "should handle deleted fields (fields in metadata but not in value)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }),
        1000,
        try documentOf(allocator, &.{property("email", try leaf(allocator, 1500))}), // deleted field in metadata
    );
    const value2 = withFields(
        try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }),
        2000,
        try documentOf(allocator, &.{property("email", try leaf(allocator, 2000))}),
    );

    const result = try mergeFields(allocator, value1, value2);

    // value2.email has newer timestamp, so it should win
    try std.testing.expect(get(result.value, "email").eql(stringValue("jane@example.com")));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "email"));
}

test "should handle both sides having deleted fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{property("name", stringValue("John"))}),
        1000,
        try documentOf(allocator, &.{
            property("age", try leaf(allocator, 500)), // deleted with old timestamp
            property("email", try leaf(allocator, 1500)), // deleted with newer timestamp
        }),
    );
    const value2 = withFields(
        try objectValue(allocator, &.{property("name", stringValue("Jane"))}),
        2000,
        try documentOf(allocator, &.{
            property("age", try leaf(allocator, 1800)), // deleted with newer timestamp
            property("phone", try leaf(allocator, 2000)), // deleted
        }),
    );

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(get(result.value, "name").eql(stringValue("Jane"))); // value2 has newer root timestamp
    try std.testing.expect(get(result.value, "age") == .undefined);
    try std.testing.expect(get(result.value, "email") == .undefined);
    try std.testing.expect(get(result.value, "phone") == .undefined);

    // Fields with newer timestamps should be in metadata
    try std.testing.expectEqual(@as(f64, 1800), timestampOf(result.metadata.fields.?, "age")); // value2 wins
    // email: value1 has timestamp 1500, value2 doesn't have it (timestamp 2000 from root)
    // value2 wins (2000 > 1500), so timestamp should be 2000
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "email"));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "phone"));
}

test "should merge arrays as primitives (treated as values, not merged)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{
        property("items", .{ .array = try allocator.dupe(BsonValue, &.{ numberValue(1), numberValue(2), numberValue(3) }) }),
        property("tags", .{ .array = try allocator.dupe(BsonValue, &.{ stringValue("a"), stringValue("b") }) }),
    }), 1000);
    const value2 = plain(try objectValue(allocator, &.{
        property("items", .{ .array = try allocator.dupe(BsonValue, &.{ numberValue(4), numberValue(5) }) }),
        property("tags", .{ .array = try allocator.dupe(BsonValue, &.{stringValue("c")}) }),
    }), 2000);

    const result = try mergeFields(allocator, value1, value2);

    // Arrays are objects but mergeFields will try to merge them
    // Since they're not primitives, mergeValues will recursively call mergeFields
    // But arrays as objects will have numeric keys merged
    try std.testing.expect(result.value.document.get("items") != null);
    try std.testing.expect(result.value.document.get("tags") != null);
    try std.testing.expect(result.metadata.fields != null);
}

test "should handle null and undefined values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("age", .null),
        property("email", .undefined),
    }), 1000);
    const value2 = plain(try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", numberValue(30)) }), 2000);

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(get(result.value, "name").eql(stringValue("Jane")));
    try std.testing.expect(get(result.value, "age").eql(numberValue(30))); // value2 wins (newer timestamp)
    try std.testing.expect(get(result.value, "email") == .undefined);
}

test "should preserve deeply nested field metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{property("level1", try objectValue(allocator, &.{
            property("level2", try objectValue(allocator, &.{
                property("level3", try objectValue(allocator, &.{property("value", stringValue("deep"))})),
            })),
        }))}),
        1000,
        try documentOf(allocator, &.{property("level1", try node(allocator, 1000, &.{
            property("level2", try node(allocator, 1000, &.{
                property("level3", try node(allocator, 1000, &.{property("value", try leaf(allocator, 1000))})),
            })),
        }))}),
    );
    const value2 = withFields(
        try objectValue(allocator, &.{property("level1", try objectValue(allocator, &.{
            property("level2", try objectValue(allocator, &.{
                property("level3", try objectValue(allocator, &.{property("value", stringValue("updated"))})),
            })),
        }))}),
        2000,
        try documentOf(allocator, &.{property("level1", try node(allocator, 2000, &.{
            property("level2", try node(allocator, 2000, &.{
                property("level3", try node(allocator, 2000, &.{property("value", try leaf(allocator, 2000))})),
            })),
        }))}),
    );

    const result = try mergeFields(allocator, value1, value2);

    const level3 = get(get(get(result.value, "level1"), "level2"), "level3");
    try std.testing.expect(get(level3, "value").eql(stringValue("updated")));
    const level1Fields = nestedFields(result.metadata.fields.?, "level1");
    const level2Fields = nestedFields(level1Fields, "level2");
    const level3Fields = nestedFields(level2Fields, "level3");
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(level3Fields, "value"));
}

test "should handle fields with same timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{property("name", stringValue("John"))}), 1000);
    const value2 = plain(try objectValue(allocator, &.{property("name", stringValue("Jane"))}), 1000);

    const result = try mergeFields(allocator, value1, value2);

    // When timestamps are equal, value2 wins (timestamp1 > timestamp2 check is false)
    try std.testing.expect(get(result.value, "name").eql(stringValue("Jane")));
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(result.metadata.fields.?, "name"));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp);
}

test "should merge when value1 has all keys and value2 has subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{
        property("a", numberValue(1)),
        property("b", numberValue(2)),
        property("c", numberValue(3)),
        property("d", numberValue(4)),
    }), 1000);
    const value2 = plain(try objectValue(allocator, &.{property("b", numberValue(20))}), 2000);

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{
        property("a", numberValue(1)), // value2 doesn't have 'a' (undefined), so value1 wins
        property("b", numberValue(20)), // value2 wins (newer timestamp)
        property("c", numberValue(3)), // value2 doesn't have 'c' (undefined), so value1 wins
        property("d", numberValue(4)), // value2 doesn't have 'd' (undefined), so value1 wins
    })));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "b"));
    try std.testing.expectEqual(@as(f64, 1000), timestampOf(result.metadata.fields.?, "a")); // value2 doesn't have 'a' (undefined), so value1 wins
}

test "should merge when value2 has all keys and value1 has subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{property("b", numberValue(2))}), 2000);
    const value2 = plain(try objectValue(allocator, &.{
        property("a", numberValue(10)),
        property("b", numberValue(20)),
        property("c", numberValue(30)),
        property("d", numberValue(40)),
    }), 1000);

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{
        property("a", numberValue(10)), // value1 doesn't have 'a' (undefined), so value2 wins
        property("b", numberValue(2)), // value1 wins (newer timestamp)
        property("c", numberValue(30)), // value1 doesn't have 'c' (undefined), so value2 wins
        property("d", numberValue(40)), // value1 doesn't have 'd' (undefined), so value2 wins
    })));
}

test "should handle field metadata without fields property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{property("name", stringValue("John"))}),
        1000,
        try documentOf(allocator, &.{property("name", try leaf(allocator, 1500))}), // no fields property
    );
    const value2 = withFields(
        try objectValue(allocator, &.{property("name", stringValue("Jane"))}),
        2000,
        try documentOf(allocator, &.{property("name", try leaf(allocator, 1200))}),
    );

    const result = try mergeFields(allocator, value1, value2);

    try std.testing.expect(get(result.value, "name").eql(stringValue("John")));
    try std.testing.expectEqual(@as(f64, 1500), timestampOf(result.metadata.fields.?, "name"));
    try std.testing.expect(toEqual(.{ .document = nestedFields(result.metadata.fields.?, "name") }, try objectValue(allocator, &.{})));
}

test "should use root timestamp as default for fields without explicit timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = withFields(
        try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }),
        1000,
        try documentOf(allocator, &.{property("name", try leaf(allocator, 1500))}), // age doesn't have explicit timestamp
    );
    const value2 = plain(try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", numberValue(25)) }), 2000); // no field-level metadata

    const result = try mergeFields(allocator, value1, value2);

    // age from value1 should use root timestamp 1000
    // age from value2 should use root timestamp 2000
    // value2.age wins (2000 > 1000)
    try std.testing.expect(get(result.value, "age").eql(numberValue(25)));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "age"));
    // name: value1 has timestamp 1500, value2 has timestamp 2000 (root)
    // value2.name wins (2000 > 1500), so timestamp should be 2000
    try std.testing.expect(get(result.value, "name").eql(stringValue("Jane")));
    try std.testing.expectEqual(@as(f64, 2000), timestampOf(result.metadata.fields.?, "name"));
}

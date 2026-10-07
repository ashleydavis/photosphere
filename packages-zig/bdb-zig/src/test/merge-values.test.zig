//
// Tests for mergeValues (port of src/tests/merge-values.test.ts).
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
const mergeValues = bdb.merge_records.mergeValues;
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
// Builds the field metadata literal `{ name: { timestamp } }` for the given fields.
//
fn fieldTimestamps(allocator: std.mem.Allocator, key: []const u8, timestamp: f64) !BsonDocument {
    return (try objectValue(allocator, &.{property(key, try objectValue(allocator, &.{property("timestamp", numberValue(timestamp))}))})).document;
}

test "should return value1 when it has newer timestamp and both are primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("hello"), 2000);
    const value2 = plain(stringValue("world"), 1000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("hello")));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should return value2 when it has newer timestamp and both are primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("hello"), 1000);
    const value2 = plain(stringValue("world"), 2000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("world")));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should return value2 when timestamps are equal and both are primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("hello"), 1000);
    const value2 = plain(stringValue("world"), 1000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("world")));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp);
}

test "should handle number primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(numberValue(42), 2000);
    const value2 = plain(numberValue(100), 1000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(numberValue(42)));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should handle boolean primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(.{ .boolean = true }, 1000);
    const value2 = plain(.{ .boolean = false }, 2000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(.{ .boolean = false }));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should handle null as primitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(.null, 2000);
    const value2 = plain(stringValue("not null"), 1000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value == .null);
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should handle undefined as primitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(.undefined, 2000);
    const value2 = plain(stringValue("defined"), 1000);

    const result = try mergeValues(allocator, value1, value2);

    // value1 is undefined, so value2 wins regardless of timestamp
    try std.testing.expect(result.value.eql(stringValue("defined")));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp);
}

test "should merge objects when both are objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }), 1000);
    const value2 = plain(try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }), 2000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("age", numberValue(30)),
        property("email", stringValue("jane@example.com")),
    })));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp); // Math.min from mergeFields
    try std.testing.expect(result.metadata.fields != null);
}

test "should return primitive when one side is primitive and other is object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("string"), 1000);
    const value2 = plain(try objectValue(allocator, &.{property("complex", stringValue("object"))}), 2000);

    const result = try mergeValues(allocator, value1, value2);

    // value1 is primitive, value2 is object (both are primitives or one is primitive)
    // value2 has newer timestamp (2000 > 1000), so value2 wins
    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{property("complex", stringValue("object"))})));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should return primitive when other side is primitive and one is object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{property("complex", stringValue("object"))}), 2000);
    const value2 = plain(stringValue("string"), 1000);

    const result = try mergeValues(allocator, value1, value2);

    // value1 has newer timestamp, so it wins (even though it's an object)
    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{property("complex", stringValue("object"))})));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should handle arrays as primitives (winner-takes-all by timestamp)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(.{ .array = try allocator.dupe(BsonValue, &.{ numberValue(1), numberValue(2), numberValue(3) }) }, 1000);
    const value2 = plain(.{ .array = try allocator.dupe(BsonValue, &.{ numberValue(4), numberValue(5) }) }, 2000);

    // Arrays are treated as primitives: the newer timestamp wins entirely
    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, .{ .array = try allocator.dupe(BsonValue, &.{ numberValue(4), numberValue(5) }) }));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should preserve array type when merging labels fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(.{ .array = try allocator.dupe(BsonValue, &.{stringValue("starred")}) }, 1000);
    const value2 = plain(.{ .array = try allocator.dupe(BsonValue, &.{stringValue("starred")}) }, 2000);

    const result = try mergeValues(allocator, value1, value2);

    // Result must remain an array, not become a plain object with numeric keys
    try std.testing.expect(result.value == .array);
    try std.testing.expect(toEqual(result.value, .{ .array = try allocator.dupe(BsonValue, &.{stringValue("starred")}) }));
}

test "should handle empty objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{}), 1000);
    const value2 = plain(try objectValue(allocator, &.{}), 2000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(toEqual(result.value, try objectValue(allocator, &.{})));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp);
    try std.testing.expect(toEqual(.{ .document = result.metadata.fields.? }, try objectValue(allocator, &.{})));
}

test "should merge deeply nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{property("level1", try objectValue(allocator, &.{
        property("level2", try objectValue(allocator, &.{property("value", stringValue("deep1"))})),
    }))}), 1000);
    const value2 = plain(try objectValue(allocator, &.{property("level1", try objectValue(allocator, &.{
        property("level2", try objectValue(allocator, &.{ property("value", stringValue("deep2")), property("other", stringValue("field")) })),
    }))}), 2000);

    const result = try mergeValues(allocator, value1, value2);

    const level2 = result.value.document.get("level1").?.document.get("level2").?;
    try std.testing.expect(level2.document.get("value").?.eql(stringValue("deep2")));
    try std.testing.expect(level2.document.get("other").?.eql(stringValue("field")));
    try std.testing.expect(result.metadata.fields != null);
}

test "should handle primitive string vs number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("text"), 2000);
    const value2 = plain(numberValue(123), 1000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("text")));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should handle primitive boolean vs string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(.{ .boolean = true }, 1000);
    const value2 = plain(stringValue("false"), 2000);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("false")));
    try std.testing.expectEqual(@as(f64, 2000), result.metadata.timestamp);
}

test "should merge objects with nested primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1: MergeValue = .{
        .value = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }),
        .metadata = .{
            .timestamp = 1000,
            .fields = try fieldTimestamps(allocator, "name", 1500),
        },
    };
    const value2: MergeValue = .{
        .value = try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", numberValue(25)) }),
        .metadata = .{
            .timestamp = 2000,
            .fields = try fieldTimestamps(allocator, "age", 1800),
        },
    };

    const result = try mergeValues(allocator, value1, value2);

    // value1.name has explicit timestamp 1500, value2.name uses root timestamp 2000
    // value2.name wins (2000 > 1500)
    try std.testing.expect(result.value.document.get("name").?.eql(stringValue("Jane")));
    // value2.age has timestamp 1800, value1.age has root timestamp 1000
    // value2.age wins (1800 > 1000)
    try std.testing.expect(result.value.document.get("age").?.eql(numberValue(25)));
}

test "should handle Date objects as objects (not primitives)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // new Date('2023-01-01') and new Date('2023-12-31').
    const value1 = plain(.{ .date = 1672531200000 }, 1000);
    const value2 = plain(.{ .date = 1703980800000 }, 2000);

    // Date objects are objects (not primitives), so they should be merged
    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value != .undefined);
    try std.testing.expect(result.metadata.fields != null);
}

test "should handle mixed primitive types with equal timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(numberValue(42), 1000);
    const value2 = plain(stringValue("forty-two"), 1000);

    const result = try mergeValues(allocator, value1, value2);

    // When timestamps are equal, value2 wins (timestamp1 > timestamp2 is false)
    try std.testing.expect(result.value.eql(stringValue("forty-two")));
    try std.testing.expectEqual(@as(f64, 1000), result.metadata.timestamp);
}

test "should handle object with null nested value vs object with defined nested value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(try objectValue(allocator, &.{property("field", .null)}), 2000);
    const value2 = plain(try objectValue(allocator, &.{property("field", stringValue("value"))}), 1000);

    const result = try mergeValues(allocator, value1, value2);

    // Both are objects, so merge fields
    // value1.field has timestamp 2000, value2.field has timestamp 1000
    // So value1.field (null) should win
    try std.testing.expect(result.value.document.get("field").? == .null);
}

test "should handle very large timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const maxSafeInteger: f64 = 9007199254740991;
    const value1 = plain(stringValue("value1"), maxSafeInteger);
    const value2 = plain(stringValue("value2"), maxSafeInteger - 1);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("value1")));
    try std.testing.expectEqual(maxSafeInteger, result.metadata.timestamp);
}

test "should handle zero timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("value1"), 0);
    const value2 = plain(stringValue("value2"), 1);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("value2")));
    try std.testing.expectEqual(@as(f64, 1), result.metadata.timestamp);
}

test "should handle negative timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value1 = plain(stringValue("value1"), -100);
    const value2 = plain(stringValue("value2"), -200);

    const result = try mergeValues(allocator, value1, value2);

    try std.testing.expect(result.value.eql(stringValue("value1"))); // -100 > -200
    try std.testing.expectEqual(@as(f64, -100), result.metadata.timestamp);
}

// An absent field and an empty one are not the same thing here, and the difference decides
// whether a sync can lose an edit. These two hold that distinction still: it is what made smoke
// test 45 fail while the host-side sync tests, whose fixture record had no description field at
// all, went on passing.

test "an absent value loses to a present one whichever side it is on and whatever the timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const absentIsNewer = try mergeValues(allocator, plain(.undefined, 9000), plain(stringValue("present"), 1000));
    try std.testing.expect(absentIsNewer.value.eql(stringValue("present")));

    const absentIsNewerOnTheOtherSide = try mergeValues(allocator, plain(stringValue("present"), 1000), plain(.undefined, 9000));
    try std.testing.expect(absentIsNewerOnTheOtherSide.value.eql(stringValue("present")));
}

test "an empty string is a value rather than an absence, so it competes on its timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const emptyIsNewer = try mergeValues(allocator, plain(stringValue(""), 9000), plain(stringValue("present"), 1000));
    try std.testing.expect(emptyIsNewer.value.eql(stringValue("")));

    const emptyIsOlder = try mergeValues(allocator, plain(stringValue(""), 1000), plain(stringValue("present"), 9000));
    try std.testing.expect(emptyIsOlder.value.eql(stringValue("present")));
}

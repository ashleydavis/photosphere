//
// Tests for bson.zig. The golden fixtures in fixtures/bson were serialized by the npm `bson` library (see fixtures/generate.ts).
//

const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const bson = serialization_zig.bson;
const errors = utils.errors;
const BsonDocument = bson.BsonDocument;
const BsonValue = bson.BsonValue;
const BsonField = bson.BsonField;

//
// The Io used by the tests.
//
const io = std.testing.io;

//
// Reads a BSON fixture file.
//
fn readBsonFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const fixture_path = try std.fmt.allocPrint(allocator, "src/test/fixtures/bson/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .unlimited);
}

//
// Builds a document from fields.
//
fn document(allocator: std.mem.Allocator, fields: []const BsonField) !BsonDocument {
    return BsonDocument.fromFields(allocator, fields);
}

//
// Builds an array value.
//
fn array(allocator: std.mem.Allocator, elements: []const BsonValue) !BsonValue {
    return .{ .array = try allocator.dupe(BsonValue, elements) };
}

//
// Checks a case against its fixtures:
//   - serializing the document gives the bytes npm bson serialized for the same JS value (<name>.bson),
//   - deserializing those bytes and serializing again gives what TypeScript writes when it does the same (<name>.reencoded.bson).
// Returns the deserialized document.
//
fn expectFixture(allocator: std.mem.Allocator, name: []const u8, expected_document: ?BsonDocument) !BsonDocument {
    const expected_bytes = try readBsonFixture(allocator, try std.fmt.allocPrint(allocator, "{s}.bson", .{name}));
    if (expected_document) |value| {
        const actual_bytes = try bson.serialize(allocator, value);
        try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
    }
    const decoded = try bson.deserialize(allocator, expected_bytes);
    const reencoded_expected = try readBsonFixture(allocator, try std.fmt.allocPrint(allocator, "{s}.reencoded.bson", .{name}));
    try std.testing.expectEqualSlices(u8, reencoded_expected, try bson.serialize(allocator, decoded));
    return decoded;
}

test "serialize and deserialize an empty document match npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const decoded = try expectFixture(allocator, "empty", BsonDocument.empty);
    try std.testing.expectEqual(@as(usize, 0), decoded.count());
}

test "serialize and deserialize strings match npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "a", .value = .{ .string = "hello" } },
        .{ .key = "unicode", .value = .{ .string = "🚀 émojis 中文" } },
        .{ .key = "empty", .value = .{ .string = "" } },
    });
    const decoded = try expectFixture(allocator, "strings", value);
    try std.testing.expect(decoded.eql(value));
}

test "serialize numbers like npm bson: int32 for safe integers in range, otherwise double" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "zero", .value = .{ .number = 0 } },
        .{ .key = "one", .value = .{ .number = 1 } },
        .{ .key = "neg", .value = .{ .number = -1 } },
        .{ .key = "int32max", .value = .{ .number = 2147483647 } },
        .{ .key = "int32min", .value = .{ .number = -2147483648 } },
        .{ .key = "above", .value = .{ .number = 2147483648 } },
        .{ .key = "below", .value = .{ .number = -2147483649 } },
        .{ .key = "pi", .value = .{ .number = 3.14159 } },
        .{ .key = "negzero", .value = .{ .number = -0.0 } },
        .{ .key = "safe", .value = .{ .number = 9007199254740991 } },
        // The JS literal 9007199254740993 is not representable and rounds to 9007199254740992.
        .{ .key = "unsafe", .value = .{ .number = 9007199254740992.0 } },
        .{ .key = "nan", .value = .{ .number = std.math.nan(f64) } },
        .{ .key = "inf", .value = .{ .number = std.math.inf(f64) } },
        .{ .key = "ninf", .value = .{ .number = -std.math.inf(f64) } },
        .{ .key = "frac", .value = .{ .number = 0.5 } },
    });
    const decoded = try expectFixture(allocator, "numbers", value);
    try std.testing.expectEqual(@as(f64, 2147483648), decoded.get("above").?.number);
    try std.testing.expect(std.math.signbit(decoded.get("negzero").?.number));
    try std.testing.expect(std.math.isNan(decoded.get("nan").?.number));
}

test "serialize bigint as int64 and deserialize small int64 as a JS number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "big", .value = .{ .int64 = 1234567890123456789 } },
        .{ .key = "small", .value = .{ .int64 = 5 } },
        .{ .key = "neg", .value = .{ .int64 = -5 } },
    });
    const decoded = try expectFixture(allocator, "bigint", value);
    try std.testing.expectEqual(@as(i64, 1234567890123456789), decoded.get("big").?.int64);
    try std.testing.expectEqual(@as(f64, 5), decoded.get("small").?.number);
    try std.testing.expectEqual(@as(f64, -5), decoded.get("neg").?.number);
}

test "deserialize int64 promotes values within 2^53 to JS numbers (promoteLongs)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "small", .value = .{ .int64 = 42 } },
        .{ .key = "limit", .value = .{ .int64 = 9007199254740992 } },
        .{ .key = "large", .value = .{ .int64 = 9007199254740993 } },
        .{ .key = "negLarge", .value = .{ .int64 = -9223372036854775808 } },
    });
    const decoded = try expectFixture(allocator, "long", value);
    try std.testing.expectEqual(@as(f64, 42), decoded.get("small").?.number);
    try std.testing.expectEqual(@as(f64, 9007199254740992), decoded.get("limit").?.number);
    try std.testing.expectEqual(@as(i64, 9007199254740993), decoded.get("large").?.int64);
    try std.testing.expectEqual(@as(i64, -9223372036854775808), decoded.get("negLarge").?.int64);
}

test "serialize booleans, null and undefined (left out) like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "t", .value = .{ .boolean = true } },
        .{ .key = "f", .value = .{ .boolean = false } },
        .{ .key = "n", .value = .null },
        .{ .key = "u", .value = .undefined },
    });
    const decoded = try expectFixture(allocator, "constants", value);
    try std.testing.expect(decoded.get("u") == null);
    try std.testing.expectEqual(true, decoded.get("t").?.boolean);
}

test "deserialize the BSON undefined type as undefined and leave it out when re-serializing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const decoded = try expectFixture(allocator, "undefined-wire", null);
    try std.testing.expect(decoded.get("u").? == .undefined);
    try std.testing.expectEqual(@as(f64, 1), decoded.get("x").?.number);
}

test "serialize and deserialize dates like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "d", .value = .{ .date = 1672531200000 } },
        .{ .key = "epoch", .value = .{ .date = 0 } },
        .{ .key = "neg", .value = .{ .date = -86400000 } },
        .{ .key = "ms", .value = .{ .date = 1700000000123 } },
    });
    const decoded = try expectFixture(allocator, "dates", value);
    try std.testing.expect(decoded.eql(value));
}

test "serialize and deserialize Buffer, UUID and Binary like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var uuid: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&uuid, "89171cd9a6524047b8691154bf2c95a1");
    const value = try document(allocator, &.{
        .{ .key = "buf", .value = .{ .binary = .{ .subType = 0, .data = "hello" } } },
        .{ .key = "empty", .value = .{ .binary = .{ .subType = 0, .data = "" } } },
        .{ .key = "uuid", .value = .{ .binary = .{ .subType = 4, .data = &uuid } } },
        .{ .key = "user", .value = .{ .binary = .{ .subType = 0x80, .data = &.{ 1, 2, 3 } } } },
        .{ .key = "old", .value = .{ .binary = .{ .subType = 2, .data = &.{ 4, 5 } } } },
    });
    const decoded = try expectFixture(allocator, "binary", value);
    try std.testing.expect(decoded.eql(value));
}

test "serialize and deserialize ObjectId like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object_id: [12]u8 = undefined;
    _ = try std.fmt.hexToBytes(&object_id, "507f1f77bcf86cd799439011");
    const value = try document(allocator, &.{.{ .key = "id", .value = .{ .objectId = object_id } }});
    const decoded = try expectFixture(allocator, "object-id", value);
    try std.testing.expect(decoded.eql(value));
}

test "serialize the Int32 and Double wrappers like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "i", .value = .{ .int32 = 5 } },
        .{ .key = "d", .value = .{ .double = 5 } },
    });
    const decoded = try expectFixture(allocator, "wrappers", value);
    try std.testing.expectEqual(@as(f64, 5), decoded.get("i").?.number);
    try std.testing.expectEqual(@as(f64, 5), decoded.get("d").?.number);
}

test "serialize and deserialize nested documents and arrays like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const deep = try document(allocator, &.{
        .{ .key = "level", .value = .{ .number = 3 } },
        .{ .key = "data", .value = .{ .string = "deep value" } },
    });
    const nested = try document(allocator, &.{
        .{ .key = "array", .value = try array(allocator, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } }) },
        .{ .key = "bool", .value = .{ .boolean = true } },
        .{ .key = "date", .value = .{ .date = 1672531200000 } },
        .{ .key = "deep", .value = .{ .document = deep } },
    });
    const inner = try document(allocator, &.{.{ .key = "x", .value = .{ .number = 1 } }});
    const value = try document(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
        .{ .key = "nested", .value = .{ .document = nested } },
        .{ .key = "tags", .value = try array(allocator, &.{ .{ .string = "tag1" }, .{ .string = "tag2" } }) },
        .{ .key = "mixed", .value = try array(allocator, &.{
            .{ .number = 1 },
            .{ .string = "two" },
            .null,
            .undefined,
            .{ .document = inner },
            try array(allocator, &.{.{ .number = 2 }}),
        }) },
    });
    const decoded = try expectFixture(allocator, "nested", value);
    const mixed = decoded.get("mixed").?.array;
    try std.testing.expectEqual(@as(usize, 6), mixed.len);
    try std.testing.expect(mixed[3] == .null);
    try std.testing.expectEqualStrings("deep value", decoded.get("nested").?.document.get("deep").?.document.get("data").?.string);
}

test "document keys follow JS property order (array indexes first)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{
        .{ .key = "b", .value = .{ .number = 1 } },
        .{ .key = "2", .value = .{ .string = "two" } },
        .{ .key = "a", .value = .{ .number = 2 } },
        .{ .key = "1", .value = .{ .string = "one" } },
        .{ .key = "01", .value = .{ .string = "not an index" } },
    });
    const keys = [_][]const u8{ "1", "2", "b", "a", "01" };
    for (keys, value.fields.items) |key, field| {
        try std.testing.expectEqualStrings(key, field.key);
    }
    _ = try expectFixture(allocator, "key-order", value);
}

test "BsonDocument put replaces an existing key in place, get and remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var value = try document(allocator, &.{
        .{ .key = "a", .value = .{ .number = 1 } },
        .{ .key = "b", .value = .{ .number = 2 } },
    });
    try value.put(allocator, "a", .{ .string = "replaced" });
    try std.testing.expectEqualStrings("a", value.fields.items[0].key);
    try std.testing.expectEqualStrings("replaced", value.get("a").?.string);
    try std.testing.expect(value.get("missing") == null);
    value.getPtr("b").?.* = .{ .boolean = true };
    try std.testing.expectEqual(true, value.get("b").?.boolean);
    try std.testing.expect(value.remove("a"));
    try std.testing.expect(!value.remove("a"));
    try std.testing.expectEqual(@as(usize, 1), value.count());
}

test "BsonValue eql compares deeply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try document(allocator, &.{.{ .key = "list", .value = try array(allocator, &.{ .{ .number = 1 }, .{ .string = "x" } }) }});
    const same = try document(allocator, &.{.{ .key = "list", .value = try array(allocator, &.{ .{ .number = 1 }, .{ .string = "x" } }) }});
    const different = try document(allocator, &.{.{ .key = "list", .value = try array(allocator, &.{ .{ .number = 1 }, .{ .string = "y" } }) }});
    try std.testing.expect(first.eql(same));
    try std.testing.expect(!first.eql(different));
    try std.testing.expect(!(BsonValue{ .number = 1 }).eql(.{ .int32 = 1 }));
}

test "serialize rejects keys with null bytes like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try document(allocator, &.{.{ .key = "a\x00b", .value = .null }});
    try std.testing.expectError(error.Thrown, bson.serialize(allocator, value));
    try std.testing.expectEqualStrings("key a\x00b must not contain null bytes", errors.lastErrorMessage());
}

test "deserialize rejects corrupted BSON like npm bson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.Thrown, bson.deserialize(allocator, &.{ 4, 0, 0, 0 }));
    try std.testing.expectEqualStrings("bson size must be >= 5, is 4", errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, bson.deserialize(allocator, &.{ 6, 0, 0, 0, 0 }));
    try std.testing.expectEqualStrings("buffer length 5 must === bson size 6", errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, bson.deserialize(allocator, &.{ 5, 0, 0, 0, 1 }));
    try std.testing.expectEqualStrings("One object, sized correctly, with a spot for an EOO, but the EOO isn't 0x00", errors.lastErrorMessage());

    // { a: <type 0x0B regex> } is not supported.
    try std.testing.expectError(error.Thrown, bson.deserialize(allocator, &.{ 10, 0, 0, 0, 0x0B, 'a', 0, 0, 0, 0 }));
    try std.testing.expectEqualStrings("Detected unknown BSON type b for fieldname \"a\"", errors.lastErrorMessage());

    // { b: <boolean 2> } is illegal.
    try std.testing.expectError(error.Thrown, bson.deserialize(allocator, &.{ 9, 0, 0, 0, 0x08, 'b', 0, 2, 0 }));
    try std.testing.expectEqualStrings("illegal boolean type value", errors.lastErrorMessage());

    // { s: <string with invalid UTF-8> }.
    try std.testing.expectError(error.Thrown, bson.deserialize(allocator, &.{ 14, 0, 0, 0, 0x02, 's', 0, 2, 0, 0, 0, 0xFF, 0, 0 }));
    try std.testing.expectEqualStrings("Invalid UTF-8 string in BSON document", errors.lastErrorMessage());
}

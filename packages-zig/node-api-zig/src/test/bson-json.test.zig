const std = @import("std");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const bsonValueToJson = node_api.bson_json.bsonValueToJson;
const bsonDocumentToJsonObject = node_api.bson_json.bsonDocumentToJsonObject;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;

test "a whole number becomes a JSON integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try bsonValueToJson(arena.allocator(), .{ .number = 640 });

    try std.testing.expectEqual(@as(i64, 640), value.integer);
}

test "a number with a fraction becomes a JSON float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try bsonValueToJson(arena.allocator(), .{ .number = 1.5 });

    try std.testing.expectEqual(@as(f64, 1.5), value.float);
}

test "a number that is not finite becomes null, as JSON.stringify writes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try bsonValueToJson(arena.allocator(), .{ .number = std.math.inf(f64) });

    try std.testing.expect(value == .null);
}

test "strings, booleans, null and undefined convert to their JSON counterparts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("text", (try bsonValueToJson(allocator, .{ .string = "text" })).string);
    try std.testing.expect((try bsonValueToJson(allocator, .{ .boolean = true })).bool);
    try std.testing.expect((try bsonValueToJson(allocator, .null)) == .null);
    try std.testing.expect((try bsonValueToJson(allocator, .undefined)) == .null);
}

test "an int32 becomes a JSON integer and an int64 becomes the low, high and unsigned fields of its Long, as JSON.stringify writes them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(@as(i64, -7), (try bsonValueToJson(allocator, .{ .int32 = -7 })).integer);
    const long = (try bsonValueToJson(allocator, .{ .int64 = 5000000000 })).object;
    try std.testing.expectEqual(@as(i64, 705032704), long.get("low").?.integer);
    try std.testing.expectEqual(@as(i64, 1), long.get("high").?.integer);
    try std.testing.expect(!long.get("unsigned").?.bool);
}

test "a date becomes its ISO string, as JSON.stringify writes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try bsonValueToJson(arena.allocator(), .{ .date = 1767225600000 });

    try std.testing.expectEqualStrings("2026-01-01T00:00:00.000Z", value.string);
}

test "an array converts its elements, and an undefined element becomes null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var elements = [_]BsonValue{
        .{ .string = "a" },
        .undefined,
        .{ .number = 2 },
    };

    const value = try bsonValueToJson(allocator, .{ .array = &elements });

    try std.testing.expectEqual(@as(usize, 3), value.array.items.len);
    try std.testing.expectEqualStrings("a", value.array.items[0].string);
    try std.testing.expect(value.array.items[1] == .null);
    try std.testing.expectEqual(@as(i64, 2), value.array.items[2].integer);
}

test "a document converts its fields in order and leaves out a field whose value is undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const inner = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "lat",
            .value = .{ .number = 1.5 },
        },
    });
    const document = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = "asset-1" },
        },
        .{
            .key = "missing",
            .value = .undefined,
        },
        .{
            .key = "coordinates",
            .value = .{ .document = inner },
        },
    });

    const object = try bsonDocumentToJsonObject(allocator, document);

    try std.testing.expectEqual(@as(u32, 2), object.count());
    try std.testing.expectEqualStrings("asset-1", object.get("_id").?.string);
    try std.testing.expect(object.get("missing") == null);
    try std.testing.expectEqual(@as(f64, 1.5), object.get("coordinates").?.object.get("lat").?.float);
    try std.testing.expectEqualStrings("_id", object.keys()[0]);
    try std.testing.expectEqualStrings("coordinates", object.keys()[1]);
}

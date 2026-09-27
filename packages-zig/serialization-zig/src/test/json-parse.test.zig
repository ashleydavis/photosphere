const std = @import("std");
const serialization = @import("serialization-zig");
const jsonParse = serialization.json_parse.jsonParse;

test "jsonParse gives numbers, strings, booleans, null, arrays and objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try jsonParse(arena.allocator(), "{\"a\":1,\"b\":2.5,\"c\":\"x\",\"d\":true,\"e\":null,\"f\":[1,\"y\"],\"g\":123456789012345678901234567890}");
    const document = value.document;
    try std.testing.expectEqual(@as(f64, 1), document.get("a").?.number);
    try std.testing.expectEqual(@as(f64, 2.5), document.get("b").?.number);
    try std.testing.expectEqualStrings("x", document.get("c").?.string);
    try std.testing.expect(document.get("d").?.boolean);
    try std.testing.expect(document.get("e").? == .null);
    try std.testing.expectEqual(@as(usize, 2), document.get("f").?.array.len);
    try std.testing.expectEqual(@as(f64, 1.2345678901234568e29), document.get("g").?.number);
}

test "jsonParse keeps JavaScript's property order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = (try jsonParse(arena.allocator(), "{\"z\":1,\"10\":2,\"a\":3,\"2\":4,\"z\":5}")).document;
    const keys = [_][]const u8{ "2", "10", "z", "a" };
    try std.testing.expectEqual(keys.len, document.fields.items.len);
    for (keys, document.fields.items) |key, field| {
        try std.testing.expectEqualStrings(key, field.key);
    }

    // A repeated key keeps its first position with its last value.
    try std.testing.expectEqual(@as(f64, 5), document.get("z").?.number);
}

test "jsonParse fails on text that is not JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SyntaxError, jsonParse(arena.allocator(), "{not json"));
}

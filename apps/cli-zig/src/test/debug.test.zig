const std = @import("std");
const cli = @import("cli-zig");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization = @import("serialization-zig");
const BsonDocument = serialization.bson.BsonDocument;

//
// Expects the debug edit value parser to refuse the value, with a message containing the given text.
//
fn expectParseFieldValueError(allocator: std.mem.Allocator, value: []const u8, fieldType: []const u8, expectedText: []const u8) !void {
    try std.testing.expectError(error.Thrown, cli.debug.parseFieldValue(allocator, value, fieldType));
    const message = utils.errors.errorMessage(error.Thrown);
    try std.testing.expect(std.mem.indexOf(u8, message, expectedText) != null);
}

test "parseFieldValue parses a number, and refuses text that is not one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(f64, 42.5), (try cli.debug.parseFieldValue(allocator, "42.5", "number")).number);
    try std.testing.expectEqual(@as(f64, -3), (try cli.debug.parseFieldValue(allocator, "-3", "NUMBER")).number);
    try expectParseFieldValueError(allocator, "forty", "number", "Invalid number value: forty");
}

test "parseFieldValue keeps a string as it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a, b", (try cli.debug.parseFieldValue(arena.allocator(), "a, b", "string")).string);
}

test "parseFieldValue stores a date as its ISO string, and refuses text that is not one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("2024-03-05T00:00:00.000Z", (try cli.debug.parseFieldValue(allocator, "2024-03-05", "date")).string);
    try std.testing.expectEqualStrings("2024-03-05T10:20:30.000Z", (try cli.debug.parseFieldValue(allocator, "2024-03-05T10:20:30Z", "date")).string);
    try expectParseFieldValueError(allocator, "not a date", "date", "Invalid date value: not a date");
}

test "parseFieldValue reads true and false in each spelling, and refuses anything else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "true", "TRUE", "1", "yes" }) |text| {
        try std.testing.expect((try cli.debug.parseFieldValue(allocator, text, "boolean")).boolean);
    }
    for ([_][]const u8{ "false", "False", "0", "no" }) |text| {
        try std.testing.expect(!(try cli.debug.parseFieldValue(allocator, text, "boolean")).boolean);
    }
    try expectParseFieldValueError(allocator, "maybe", "boolean", "Invalid boolean value: maybe");
}

test "parseFieldValue splits a string array at commas, trimming each item and leaving out the empty ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = (try cli.debug.parseFieldValue(arena.allocator(), " red, ,green ,blue,", "string-array")).array;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("red", items[0].string);
    try std.testing.expectEqualStrings("green", items[1].string);
    try std.testing.expectEqualStrings("blue", items[2].string);
}

test "parseFieldValue parses JSON, and refuses text that is not JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try cli.debug.parseFieldValue(allocator, "{\"count\":2,\"tags\":[\"a\"]}", "json");
    try std.testing.expectEqual(@as(f64, 2), value.document.get("count").?.number);
    try std.testing.expectEqualStrings("a", value.document.get("tags").?.array[0].string);
    try expectParseFieldValueError(allocator, "{oops", "json", "Invalid JSON value: {oops");
}

test "parseFieldValue refuses a type it does not know, naming the types it does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectParseFieldValueError(arena.allocator(), "1", "integer", "Unknown field type: integer. Supported types: number, string, date, boolean, string-array, json");
}

test "setNestedField sets a top-level field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: BsonDocument = .empty;
    try cli.debug.setNestedField(allocator, &document, "description", .{
        .string = "hello",
    });
    try std.testing.expectEqualStrings("hello", document.get("description").?.string);
}

test "setNestedField makes the documents a dot path goes through, and replaces a value on the way that is not one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: BsonDocument = .empty;
    try document.put(allocator, "user", .{
        .string = "not a document",
    });
    try cli.debug.setNestedField(allocator, &document, "user.address.city", .{
        .string = "Brisbane",
    });
    const user = document.get("user").?.document;
    try std.testing.expectEqualStrings("Brisbane", user.get("address").?.document.get("city").?.string);

    // A second field under the same document keeps the first.
    try cli.debug.setNestedField(allocator, &document, "user.name", .{
        .string = "Ash",
    });
    const updatedUser = document.get("user").?.document;
    try std.testing.expectEqualStrings("Ash", updatedUser.get("name").?.string);
    try std.testing.expectEqualStrings("Brisbane", updatedUser.get("address").?.document.get("city").?.string);
}

test "findFirstUnsortedName finds nothing in names in natural order, including empty and single lists" {
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findFirstUnsortedName(&.{}));
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findFirstUnsortedName(&.{"a"}));
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findFirstUnsortedName(&.{ "file2", "file10", "file11" }));
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findFirstUnsortedName(&.{ "a", "a" }));
}

test "findFirstUnsortedName returns the index of the first name that sorts before the one ahead of it" {
    try std.testing.expectEqual(@as(?usize, 2), cli.debug.findFirstUnsortedName(&.{ "a", "c", "b", "a" }));
    try std.testing.expectEqual(@as(?usize, 1), cli.debug.findFirstUnsortedName(&.{ "file10", "file2" }));
}

test "utf16Substring cuts a surrogate pair as substring does, leaving the lone high surrogate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // "ab" then U+1F600, two UTF-16 code units: cutting after three units keeps its high surrogate, D83D, which a
    // UTF-8 string holds as the WTF-8 bytes ED A0 BD.
    try std.testing.expectEqualStrings("ab\xED\xA0\xBD", try cli.debug.utf16Substring(arena.allocator(), "ab\u{1F600}c", 3));
    try std.testing.expectEqualStrings("ab\u{1F600}", try cli.debug.utf16Substring(arena.allocator(), "ab\u{1F600}c", 4));

    // JSON.stringify writes a lone surrogate as an escape.
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try bdb.js_value.writeJsonString(&output.writer, "ab\xED\xA0\xBD");
    try std.testing.expectEqualStrings("\"ab\\ud83d\"", output.written());
}

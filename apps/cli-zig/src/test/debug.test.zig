const std = @import("std");
const cli = @import("cli-zig");
const bdb = @import("bdb-zig");

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

test "findUnsortedName finds nothing out of order in sorted, empty and single-name lists" {
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findUnsortedName(&.{}));
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findUnsortedName(&.{"asset/a"}));
    try std.testing.expectEqual(@as(?usize, null), cli.debug.findUnsortedName(&.{ "asset/a", "asset/b", "display/a", "thumb/a" }));
}

test "findUnsortedName returns the index of the first name that sorts before the one ahead of it" {
    try std.testing.expectEqual(@as(?usize, 2), cli.debug.findUnsortedName(&.{ "asset/a", "asset/c", "asset/b", "asset/d" }));
    try std.testing.expectEqual(@as(?usize, 1), cli.debug.findUnsortedName(&.{ "thumb/a", "asset/a" }));
}

test "parseFieldValue gives the text as a string unless it is read as JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try cli.debug.parseFieldValue(allocator, "42", false);
    try std.testing.expectEqualStrings("42", text.string);

    const number = try cli.debug.parseFieldValue(allocator, "42", true);
    try std.testing.expect(number != .string);

    const array = try cli.debug.parseFieldValue(allocator, "[\"a\",\"b\"]", true);
    try std.testing.expectEqual(@as(usize, 2), array.array.len);
    try std.testing.expectEqualStrings("b", array.array[1].string);

    try std.testing.expectError(error.SyntaxError, cli.debug.parseFieldValue(allocator, "{not json", true));
}

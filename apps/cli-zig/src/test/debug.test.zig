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

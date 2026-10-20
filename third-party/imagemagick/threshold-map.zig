const std = @import("std");

//
// Makes the C source that holds ImageMagick's built-in threshold maps from config/thresholds.xml, which is what a build with zero
// configuration compiles into MagickCore/threshold.c as MagickCore/threshold-map.h. ImageMagick's Makefile.am makes it with
//
//     { printf '%s\n  %s=\n' 'static const char *const' BuiltinMap;
//       sed -e 's/"/\\"/g; s/^.*$/    "&\\n"/; $s/$/;/' config/thresholds.xml; }
//
// and this does the same: every double quote is escaped, every line becomes a string literal that ends in a newline, and the
// last line ends the declaration with a semicolon.
//

//
// Returns the declaration of BuiltinMap for the XML in `thresholds_xml`. A final newline in the XML does not start another line, as
// sed reads it.
//
pub fn buildThresholdMap(allocator: std.mem.Allocator, thresholds_xml: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "static const char *const\n  BuiltinMap=\n");
    var text = thresholds_xml;
    if (std.mem.endsWith(u8, text, "\n")) {
        text = text[0 .. text.len - 1];
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try output.appendSlice(allocator, "    \"");
        for (line) |character| {
            if (character == '"') {
                try output.append(allocator, '\\');
            }
            try output.append(allocator, character);
        }
        try output.appendSlice(allocator, "\\n\"");
        if (lines.peek() == null) {
            try output.append(allocator, ';');
        }
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

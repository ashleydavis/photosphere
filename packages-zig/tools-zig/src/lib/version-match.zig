const std = @import("std");
const js_string = @import("utils-zig").js_string;

//
// This file has no TypeScript counterpart: it stands in for the regular expressions image.ts and
// video.ts use to pull version numbers out of tool output.
//

//
// Returns true for the characters of `[\d.-]`.
//
pub fn isVersionNumberCharacter(character: u21) bool {
    return (character >= '0' and character <= '9') or character == '.' or character == '-';
}

//
// Returns true for the characters of `\S`: everything but JavaScript's whitespace and line terminators.
//
pub fn isNonWhitespaceCharacter(character: u21) bool {
    return !js_string.isWhitespace(character);
}

//
// Equivalent of `text.match(/<prefix>(<class>+)/)?.[1]`: finds the first occurrence of `prefix`
// followed by at least one character accepted by `isMatchCharacter` and returns those characters.
// The characters are read as UTF-8; a byte that does not start a character is read as U+FFFD, as the tool's
// output is decoded.
//
pub fn matchAfter(text: []const u8, prefix: []const u8, isMatchCharacter: *const fn (character: u21) bool) ?[]const u8 {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, prefix)) |prefix_index| {
        const match_start = prefix_index + prefix.len;
        var match_end = match_start;
        while (match_end < text.len) {
            var width: usize = std.unicode.utf8ByteSequenceLength(text[match_end]) catch 1;
            var character: u21 = 0xFFFD;
            if (match_end + width <= text.len) {
                character = std.unicode.utf8Decode(text[match_end .. match_end + width]) catch 0xFFFD;
            }
            if (character == 0xFFFD) {
                width = 1;
            }
            if (!isMatchCharacter(character)) {
                break;
            }
            match_end += width;
        }
        if (match_end > match_start) {
            return text[match_start..match_end];
        }
        search_start = prefix_index + 1;
    }
    return null;
}

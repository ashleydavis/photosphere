const std = @import("std");

//
// This file has no TypeScript counterpart: it stands in for the regular expressions image.ts and
// video.ts use to pull version numbers out of tool output.
//

//
// Returns true for the characters of `[\d.-]`.
//
pub fn isVersionNumberCharacter(character: u8) bool {
    return std.ascii.isDigit(character) or character == '.' or character == '-';
}

//
// Returns true for the characters of `\S`.
//
pub fn isNonWhitespaceCharacter(character: u8) bool {
    return !std.ascii.isWhitespace(character);
}

//
// Equivalent of `text.match(/<prefix>(<class>+)/)?.[1]`: finds the first occurrence of `prefix`
// followed by at least one character accepted by `isMatchCharacter` and returns those characters.
//
pub fn matchAfter(text: []const u8, prefix: []const u8, isMatchCharacter: *const fn (character: u8) bool) ?[]const u8 {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, prefix)) |prefix_index| {
        const match_start = prefix_index + prefix.len;
        var match_end = match_start;
        while (match_end < text.len and isMatchCharacter(text[match_end])) {
            match_end += 1;
        }
        if (match_end > match_start) {
            return text[match_start..match_end];
        }
        search_start = prefix_index + 1;
    }
    return null;
}

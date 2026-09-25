//
// Stand-in for the third-party `strip-ansi` and `string-width` packages used by `wrap-ansi` (this file
// has no TypeScript counterpart in the repo). The per code point widths come from
// string-width-table.zig, which is generated from the real package. Grapheme clusters are approximated:
// a cluster is a base code point followed by zero width code points (combining marks, variation
// selectors, zero width joiners and the code point each joiner joins), skin tone modifiers and tags,
// or a pair of regional indicators. The width of a cluster is the width of its first code point
// (2 for a regional indicator pair).
//

const std = @import("std");
const width_table = @import("string-width-table.zig");

//
// The ESC character that starts an ANSI escape sequence.
//
const escape_character: u21 = 0x1B;

//
// The C1 control sequence introducer (CSI), which also starts an ANSI escape sequence.
//
const csi_character: u21 = 0x9B;

//
// The BEL character that ends an OSC escape sequence.
//
const bell_character: u21 = 0x07;

//
// True when the byte can end a CSI escape sequence (ansi-regex: [\dA-PR-TZcf-nq-uy=><~]).
//
fn isCsiFinal(byte: u8) bool {
    return std.ascii.isDigit(byte) or
        (byte >= 'A' and byte <= 'P') or
        (byte >= 'R' and byte <= 'T') or
        byte == 'Z' or
        byte == 'c' or
        (byte >= 'f' and byte <= 'n') or
        (byte >= 'q' and byte <= 'u') or
        byte == 'y' or
        byte == '=' or
        byte == '>' or
        byte == '<' or
        byte == '~';
}

//
// Returns the length in bytes of the ANSI escape sequence that starts at `index`, or 0 when there is none
// (an approximation of the `ansi-regex` pattern used by strip-ansi).
//
pub fn ansiSequenceLength(text: []const u8, index: usize) usize {
    var position = index;
    if (position >= text.len) {
        return 0;
    }
    if (text[position] == 0x1B) {
        position += 1;
    }
    else if (position + 1 < text.len and text[position] == 0xC2 and text[position + 1] == 0x9B) {
        position += 2;
    }
    else {
        return 0;
    }
    while (position < text.len and std.mem.indexOfScalar(u8, "[]()#;?", text[position]) != null) {
        position += 1;
    }

    // OSC form (tried first by the regular expression): parameters then BEL.
    if (matchOscParameters(text, position)) |bell_index| {
        return bell_index + 1 - index;
    }

    // CSI form: optional parameters then a final character.
    var csi_position = position;
    var digit_count: usize = 0;
    while (csi_position < text.len and std.ascii.isDigit(text[csi_position]) and digit_count < 4) {
        csi_position += 1;
        digit_count += 1;
    }
    if (digit_count > 0) {
        while (csi_position < text.len and text[csi_position] == ';') {
            csi_position += 1;
            var parameter_digits: usize = 0;
            while (csi_position < text.len and std.ascii.isDigit(text[csi_position]) and parameter_digits < 4) {
                csi_position += 1;
                parameter_digits += 1;
            }
        }
    }
    if (csi_position < text.len and isCsiFinal(text[csi_position])) {
        return csi_position + 1 - index;
    }

    return 0;
}

//
// True for the characters allowed in OSC parameters ([-a-zA-Z\d\/#&.:=?%@~_]).
//
fn isOscParameterCharacter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-/#&.:=?%@~_", byte) != null;
}

//
// Matches `(?:(?:;[params]+)*|[a-zA-Z\d]+(?:;[params]*)*)?\u0007` at the position and returns the index
// of the BEL, or null.
//
fn matchOscParameters(text: []const u8, start: usize) ?usize {
    // Alternative 1: (?:;[params]+)*
    var position = start;
    while (position + 1 < text.len and text[position] == ';' and isOscParameterCharacter(text[position + 1])) {
        position += 1;
        while (position < text.len and isOscParameterCharacter(text[position])) {
            position += 1;
        }
    }
    if (position < text.len and text[position] == 0x07) {
        return position;
    }

    // Alternative 2: [a-zA-Z\d]+(?:;[params]*)*
    position = start;
    while (position < text.len and std.ascii.isAlphanumeric(text[position])) {
        position += 1;
    }
    if (position == start) {
        return null;
    }
    while (position < text.len and text[position] == ';') {
        position += 1;
        while (position < text.len and isOscParameterCharacter(text[position])) {
            position += 1;
        }
    }
    if (position < text.len and text[position] == 0x07) {
        return position;
    }
    return null;
}

//
// Removes ANSI escape sequences (the `strip-ansi` package).
//
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = ansiSequenceLength(text, index);
        if (sequence_length > 0) {
            index += sequence_length;
            continue;
        }
        try result.append(allocator, text[index]);
        index += 1;
    }
    return result.items;
}

//
// The width of a single code point according to the `string-width` package.
//
pub fn codePointWidth(codePoint: u21) usize {
    var low: usize = 0;
    var high: usize = width_table.ranges.len;
    while (low < high) {
        const middle = (low + high) / 2;
        const range = width_table.ranges[middle];
        if (codePoint < range.start) {
            high = middle;
        }
        else if (codePoint > range.end) {
            low = middle + 1;
        }
        else {
            return range.width;
        }
    }
    return 1;
}

//
// True when the code point is a regional indicator (flag letters).
//
fn isRegionalIndicator(codePoint: u21) bool {
    return codePoint >= 0x1F1E6 and codePoint <= 0x1F1FF;
}

//
// True when the code point extends the preceding grapheme cluster.
//
fn isClusterExtender(codePoint: u21) bool {
    if (codePoint >= 0x1F3FB and codePoint <= 0x1F3FF) {
        return true;
    }
    if (codePoint >= 0xE0020 and codePoint <= 0xE007F) {
        return true;
    }
    return codePointWidth(codePoint) == 0 and codePoint > 0x7F and !(codePoint >= 0x80 and codePoint <= 0x9F);
}

//
// Decodes the code point at `index`, returning it and its length in bytes (invalid bytes decode as U+FFFD).
//
pub fn decodeAt(text: []const u8, index: usize) struct { codePoint: u21, length: usize } {
    const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch return .{ .codePoint = 0xFFFD, .length = 1 };
    if (index + sequence_length > text.len) {
        return .{ .codePoint = 0xFFFD, .length = 1 };
    }
    const codePoint = std.unicode.utf8Decode(text[index .. index + sequence_length]) catch return .{ .codePoint = 0xFFFD, .length = 1 };
    return .{ .codePoint = codePoint, .length = sequence_length };
}

//
// Returns the length in bytes of the grapheme cluster that starts at `index`.
//
pub fn clusterLength(text: []const u8, index: usize) usize {
    const first = decodeAt(text, index);
    var position = index + first.length;
    if (isRegionalIndicator(first.codePoint) and position < text.len) {
        const second = decodeAt(text, position);
        if (isRegionalIndicator(second.codePoint)) {
            return position + second.length - index;
        }
        return position - index;
    }
    if (first.codePoint < 0x20) {
        return position - index;
    }
    while (position < text.len) {
        const next = decodeAt(text, position);
        if (next.codePoint == 0x200D) {
            position += next.length;
            if (position < text.len) {
                position += decodeAt(text, position).length;
            }
            continue;
        }
        if (!isClusterExtender(next.codePoint)) {
            break;
        }
        position += next.length;
    }
    return position - index;
}

//
// The display width of a grapheme cluster.
//
fn clusterWidth(cluster: []const u8) usize {
    const first = decodeAt(cluster, 0);
    if (isRegionalIndicator(first.codePoint) and first.length < cluster.len) {
        return 2;
    }
    return codePointWidth(first.codePoint);
}

//
// The display width of text that contains no ANSI escape sequences.
//
fn plainWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = clusterLength(text, index);
        width += clusterWidth(text[index .. index + length]);
        index += length;
    }
    return width;
}

//
// The display width of text, ignoring ANSI escape sequences (the `string-width` package).
//
pub fn stringWidth(text: []const u8) usize {
    var width: usize = 0;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = ansiSequenceLength(text, index);
        if (sequence_length > 0) {
            width += plainWidth(text[segment_start..index]);
            index += sequence_length;
            segment_start = index;
            continue;
        }
        index += 1;
    }
    width += plainWidth(text[segment_start..]);
    return width;
}

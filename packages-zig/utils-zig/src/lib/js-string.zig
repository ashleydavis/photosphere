const std = @import("std");

//
// No TypeScript counterpart: stands in for the whitespace handling of JavaScript's String.prototype.trim,
// trimStart and trimEnd on UTF-8 text. They remove the characters of the WhiteSpace and LineTerminator
// productions of the ECMAScript specification: tab, line feed, vertical tab, form feed, carriage return, space,
// no-break space, the byte order mark, every other space separator (U+1680, U+2000 to U+200A, U+202F, U+205F and
// U+3000), and the line and paragraph separators (U+2028 and U+2029).
//

//
// Returns true when the code point is JavaScript whitespace (WhiteSpace or LineTerminator).
//
pub fn isWhitespace(codePoint: u21) bool {
    return switch (codePoint) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

//
// Returns the byte width of the JavaScript whitespace character that starts at index, or 0 when the character there
// is not whitespace (or is not valid UTF-8).
//
pub fn whitespaceWidthAt(text: []const u8, index: usize) usize {
    const width = std.unicode.utf8ByteSequenceLength(text[index]) catch {
        return 0;
    };
    if (index + width > text.len) {
        return 0;
    }
    const codePoint = std.unicode.utf8Decode(text[index .. index + width]) catch {
        return 0;
    };
    if (isWhitespace(codePoint)) {
        return width;
    }
    return 0;
}

//
// Returns the byte width of the JavaScript whitespace character that ends just before end, or 0 when the character
// there is not whitespace.
//
fn whitespaceWidthBefore(text: []const u8, end: usize) usize {
    var width: usize = 1;
    while (width <= 3 and width <= end) : (width += 1) {
        if (whitespaceWidthAt(text, end - width) == width) {
            return width;
        }
    }
    return 0;
}

//
// Removes JavaScript whitespace from the start of the text (`text.trimStart()`).
//
pub fn trimStart(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const width = whitespaceWidthAt(text, start);
        if (width == 0) {
            break;
        }
        start += width;
    }
    return text[start..];
}

//
// Removes JavaScript whitespace from the end of the text (`text.trimEnd()`).
//
pub fn trimEnd(text: []const u8) []const u8 {
    var end: usize = text.len;
    while (end > 0) {
        const width = whitespaceWidthBefore(text, end);
        if (width == 0) {
            break;
        }
        end -= width;
    }
    return text[0..end];
}

//
// Removes JavaScript whitespace from both ends of the text (`text.trim()`).
//
pub fn trim(text: []const u8) []const u8 {
    return trimEnd(trimStart(text));
}

//
// Returns the JavaScript truthiness of a string that may be undefined (`if (text)` or `while (text)`): false for
// undefined and for the empty string, true for any other string.
//
pub fn isTruthy(text: ?[]const u8) bool {
    return text != null and text.?.len > 0;
}

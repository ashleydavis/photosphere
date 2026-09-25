const std = @import("std");

//
// No TypeScript counterpart: stands in for `a.localeCompare(b, undefined, { numeric: true })`, which FileStorage uses to
// sort directory listings like S3 does. JavaScript uses ICU root collation with numeric ordering. Zig has no ICU, so
// this emulates it for the names that storage holds: every ASCII character has its ICU primary weight (control
// characters are ignorable, punctuation sorts before digits, letters compare case-insensitively first and then
// lowercase before uppercase), and each run of digits compares by numeric value. Non-ASCII characters sort after all
// ASCII characters by code point, which differs from ICU (for example ICU sorts "é" next to "e").
// The same emulation is used by merkle-tree-zig's compareNames. Golden tests compare it with localeCompare.
//

//
// Compares two strings like `left.localeCompare(right, undefined, { numeric: true })`.
// Returns negative if left < right, zero if equal, positive if left > right.
//
pub fn localeCompareNumeric(left: []const u8, right: []const u8) i32 {
    // Primary level: compare the weights of the characters, numbers by value.
    var leftElements: CollationIterator = .{ .text = left, .index = 0 };
    var rightElements: CollationIterator = .{ .text = right, .index = 0 };
    while (true) {
        const leftElement = leftElements.next();
        const rightElement = rightElements.next();
        if (leftElement == null and rightElement == null) {
            break;
        }
        if (leftElement == null) {
            return -1;
        }
        if (rightElement == null) {
            return 1;
        }
        const order = comparePrimaryWeights(leftElement.?, rightElement.?);
        if (order != 0) {
            return order;
        }
    }

    // Tertiary level: the first difference in case decides (lowercase first).
    leftElements = .{ .text = left, .index = 0 };
    rightElements = .{ .text = right, .index = 0 };
    while (true) {
        const leftElement = leftElements.next() orelse {
            break;
        };
        const rightElement = rightElements.next() orelse {
            break;
        };
        if (leftElement.tertiary < rightElement.tertiary) {
            return -1;
        }
        if (leftElement.tertiary > rightElement.tertiary) {
            return 1;
        }
    }
    return 0;
}

//
// Sort predicate for std.mem.sort: true when left sorts before right with localeCompareNumeric.
//
pub fn lessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return localeCompareNumeric(left, right) < 0;
}

//
// ICU root collation order of the ASCII characters that are not ignorable (the order `localeCompare` sorts them in).
// A lowercase letter and its uppercase letter have the same primary weight.
//
const ascii_collation_order = "\t\n\x0b\x0c\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ";

//
// The primary weight of an ignorable character (control characters).
//
const IGNORABLE_WEIGHT: u32 = 0;

//
// The primary weight of every non-ignorable ASCII character, indexed by the character.
//
const ascii_primary_weights: [128]u32 = weights: {
    var weights = [_]u32{IGNORABLE_WEIGHT} ** 128;
    var weight: u32 = 0;
    for (ascii_collation_order) |character| {
        if (character >= 'A' and character <= 'Z') {
            weights[character] = weights[character + ('a' - 'A')];
        }
        else {
            weight += 1;
            weights[character] = weight;
        }
    }
    break :weights weights;
};

//
// The primary weight of a run of digits (compared by numeric value among themselves).
//
const NUMBER_WEIGHT: u32 = ascii_primary_weights['0'];

//
// The primary weight added to the code point of a non-ASCII character.
//
const NON_ASCII_WEIGHT_BASE: u32 = 0x10000;

//
// One collation element of a string: a character, or a whole run of digits.
//
const CollationElement = struct {
    // The primary weight.
    primary: u32,

    // For a run of digits, the digits without leading zeros (empty otherwise).
    digits: []const u8,

    // The tertiary (case) weight: 1 for uppercase letters, 0 otherwise.
    tertiary: u8,
};

//
// Yields the collation elements of a string, skipping ignorable characters.
//
const CollationIterator = struct {
    // The UTF-8 string.
    text: []const u8,

    // The index of the next byte to read.
    index: usize,

    //
    // Returns the next collation element or null at the end of the string.
    //
    fn next(self: *CollationIterator) ?CollationElement {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (std.ascii.isDigit(byte)) {
                const start = self.index;
                while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) {
                    self.index += 1;
                }
                var digits = self.text[start..self.index];
                while (digits.len > 0 and digits[0] == '0') {
                    digits = digits[1..];
                }
                return .{ .primary = NUMBER_WEIGHT, .digits = digits, .tertiary = 0 };
            }
            if (byte < 0x80) {
                self.index += 1;
                const weight = ascii_primary_weights[byte];
                if (weight == IGNORABLE_WEIGHT) {
                    continue;
                }
                const tertiary: u8 = if (std.ascii.isUpper(byte)) 1 else 0;
                return .{ .primary = weight, .digits = "", .tertiary = tertiary };
            }
            const codePoint = decodeCodePoint(self.text, &self.index);
            return .{ .primary = NON_ASCII_WEIGHT_BASE + codePoint, .digits = "", .tertiary = 0 };
        }
        return null;
    }
};

//
// Decodes the UTF-8 code point at index (advancing it); invalid bytes decode as U+FFFD one byte at a time.
//
fn decodeCodePoint(text: []const u8, index: *usize) u21 {
    const sequenceLength = std.unicode.utf8ByteSequenceLength(text[index.*]) catch {
        index.* += 1;
        return 0xFFFD;
    };
    if (index.* + sequenceLength > text.len) {
        index.* += 1;
        return 0xFFFD;
    }
    const codePoint = std.unicode.utf8Decode(text[index.* .. index.* + sequenceLength]) catch {
        index.* += 1;
        return 0xFFFD;
    };
    index.* += sequenceLength;
    return codePoint;
}

//
// Compares the primary weights of two collation elements (numbers by value).
//
fn comparePrimaryWeights(left: CollationElement, right: CollationElement) i32 {
    if (left.primary != right.primary) {
        if (left.primary < right.primary) {
            return -1;
        }
        return 1;
    }
    if (left.primary == NUMBER_WEIGHT) {
        if (left.digits.len != right.digits.len) {
            if (left.digits.len < right.digits.len) {
                return -1;
            }
            return 1;
        }
        return switch (std.mem.order(u8, left.digits, right.digits)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }
    return 0;
}

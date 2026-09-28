const std = @import("std");
const js_string = @import("js-string.zig");

//
// No TypeScript counterpart: stands in for JavaScript's global `parseInt` and `parseFloat`, which the TypeScript
// code calls on text it reads from files, tools and continuation tokens. Both return a JavaScript number, so NaN is
// how they say the text holds no number.
//

//
// Returns the value of a digit in the given radix, or null when the character is not a digit of that radix.
//
fn digitValue(character: u8, radix: u8) ?u8 {
    const value: u8 = switch (character) {
        '0'...'9' => character - '0',
        'a'...'z' => character - 'a' + 10,
        'A'...'Z' => character - 'A' + 10,
        else => return null,
    };
    if (value >= radix) {
        return null;
    }
    return value;
}

//
// JavaScript's `parseInt(text, radix)`, with null for an absent radix. Leading whitespace is skipped, an optional
// sign is read, "0x" or "0X" selects radix 16 when the radix is absent or 16, and the longest run of digits of the
// radix is converted. NaN when there are no digits, or when the radix is outside 2 to 36 (0 counts as absent).
//
pub fn parseInt(text: []const u8, radix: ?u32) f64 {
    var rest = js_string.trimStart(text);
    var sign: f64 = 1;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        if (rest[0] == '-') {
            sign = -1;
        }
        rest = rest[1..];
    }

    var effectiveRadix: u32 = radix orelse 0;
    var stripPrefix = true;
    if (effectiveRadix != 0) {
        if (effectiveRadix < 2 or effectiveRadix > 36) {
            return std.math.nan(f64);
        }
        if (effectiveRadix != 16) {
            stripPrefix = false;
        }
    }
    else {
        effectiveRadix = 10;
    }
    if (stripPrefix and rest.len >= 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X')) {
        rest = rest[2..];
        effectiveRadix = 16;
    }

    var digitCount: usize = 0;
    while (digitCount < rest.len and digitValue(rest[digitCount], @intCast(effectiveRadix)) != null) {
        digitCount += 1;
    }
    if (digitCount == 0) {
        return std.math.nan(f64);
    }
    const digits = rest[0..digitCount];

    // Base 10 is converted with correct rounding, as JavaScript requires for it.
    if (effectiveRadix == 10) {
        const magnitude = std.fmt.parseFloat(f64, digits) catch {
            return std.math.nan(f64);
        };
        return sign * magnitude;
    }
    var magnitude: f64 = 0;
    for (digits) |character| {
        magnitude = magnitude * @as(f64, @floatFromInt(effectiveRadix)) + @as(f64, @floatFromInt(digitValue(character, @intCast(effectiveRadix)).?));
    }
    return sign * magnitude;
}

//
// JavaScript's `parseFloat(text)`: the longest decimal number at the start of the text (after whitespace), or NaN.
// "Infinity" with an optional sign is read as infinity.
//
pub fn parseFloat(text: []const u8) f64 {
    const trimmed = js_string.trimStart(text);
    var end: usize = 0;
    if (end < trimmed.len and (trimmed[end] == '+' or trimmed[end] == '-')) {
        end += 1;
    }
    if (std.mem.startsWith(u8, trimmed[end..], "Infinity")) {
        return if (trimmed[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    }
    const digitsStart = end;
    while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) {
        end += 1;
    }
    if (end < trimmed.len and trimmed[end] == '.') {
        end += 1;
        while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) {
            end += 1;
        }
    }
    if (end == digitsStart or (end == digitsStart + 1 and trimmed[digitsStart] == '.')) {
        return std.math.nan(f64);
    }
    // An exponent counts only when it has digits.
    if (end < trimmed.len and (trimmed[end] == 'e' or trimmed[end] == 'E')) {
        var exponentEnd = end + 1;
        if (exponentEnd < trimmed.len and (trimmed[exponentEnd] == '+' or trimmed[exponentEnd] == '-')) {
            exponentEnd += 1;
        }
        const exponentDigits = exponentEnd;
        while (exponentEnd < trimmed.len and std.ascii.isDigit(trimmed[exponentEnd])) {
            exponentEnd += 1;
        }
        if (exponentEnd > exponentDigits) {
            end = exponentEnd;
        }
    }
    return std.fmt.parseFloat(f64, trimmed[0..end]) catch std.math.nan(f64);
}

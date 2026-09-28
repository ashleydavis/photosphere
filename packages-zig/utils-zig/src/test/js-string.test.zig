const std = @import("std");
const utils = @import("utils-zig");

const js_string = utils.js_string;

//
// The expected results are what `text.trim()`, `text.trimStart()` and `text.trimEnd()` give in JavaScript.
//
test "trim removes ASCII whitespace from both ends" {
    try std.testing.expectEqualStrings("a b", js_string.trim(" \t\n\r\x0b\x0ca b\x0c\x0b\r\n\t "));
}

test "trim removes the no-break space, the byte order mark and the other space separators" {
    try std.testing.expectEqualStrings("x", js_string.trim("\u{FEFF}\u{00A0}\u{1680}\u{2000}\u{200A}\u{202F}\u{205F}\u{3000}x\u{3000}\u{00A0}\u{FEFF}"));
}

test "trim removes the line and paragraph separators" {
    try std.testing.expectEqualStrings("x", js_string.trim("\u{2028}x\u{2029}"));
}

test "trim keeps characters that are not whitespace in JavaScript" {
    try std.testing.expectEqualStrings("\u{200B}x\u{0085}", js_string.trim("\u{200B}x\u{0085}"));
}

test "trim of only whitespace is empty" {
    try std.testing.expectEqualStrings("", js_string.trim(" \u{3000}\t"));
}

test "trimStart and trimEnd each remove one end" {
    try std.testing.expectEqualStrings("x\u{3000}", js_string.trimStart("\u{3000}x\u{3000}"));
    try std.testing.expectEqualStrings("\u{3000}x", js_string.trimEnd("\u{3000}x\u{3000}"));
}

test "trim leaves invalid UTF-8 in place" {
    try std.testing.expectEqualStrings("\xffx\xe3", js_string.trim(" \xffx\xe3 "));
}

test "isTruthy is false for undefined and the empty string, true for any other string" {
    try std.testing.expect(!js_string.isTruthy(null));
    try std.testing.expect(!js_string.isTruthy(""));
    try std.testing.expect(js_string.isTruthy("0"));
    try std.testing.expect(js_string.isTruthy(" "));
}

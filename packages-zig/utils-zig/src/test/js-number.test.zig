const std = @import("std");
const utils = @import("utils-zig");

const js_number = utils.js_number;

//
// The expected values are what Bun's parseInt and parseFloat return for each text.
//
test "parseInt reads the integer at the start of the text like JavaScript" {
    try std.testing.expectEqual(@as(f64, 42), js_number.parseInt("42", null));
    try std.testing.expectEqual(@as(f64, -17), js_number.parseInt("  -17abc", null));
    try std.testing.expectEqual(@as(f64, 8), js_number.parseInt("\u{3000} 8", null));
    try std.testing.expectEqual(@as(f64, 31), js_number.parseInt("0x1F", null));
    try std.testing.expectEqual(@as(f64, 31), js_number.parseInt("0X1f", null));
    try std.testing.expectEqual(@as(f64, 12), js_number.parseInt("+12", null));
    try std.testing.expectEqual(@as(f64, 1), js_number.parseInt("1e3", null));
    try std.testing.expectEqual(@as(f64, 12), js_number.parseInt("12.9", null));
    try std.testing.expectEqual(@as(f64, 9007199254740992), js_number.parseInt("9007199254740993", null));
    try std.testing.expect(std.math.isNan(js_number.parseInt("", null)));
    try std.testing.expect(std.math.isNan(js_number.parseInt("abc", null)));
}

test "parseInt of -0 is negative zero" {
    const value = js_number.parseInt("-0", null);
    try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expect(std.math.signbit(value));
}

test "parseInt honours the radix" {
    try std.testing.expectEqual(@as(f64, 255), js_number.parseInt("ff", 16));
    try std.testing.expectEqual(@as(f64, 16), js_number.parseInt("0x10", 16));
    try std.testing.expectEqual(@as(f64, 0), js_number.parseInt("0x10", 10));
    try std.testing.expect(std.math.isNan(js_number.parseInt("10", 1)));
    try std.testing.expectEqual(@as(f64, 35), js_number.parseInt("z", 36));
    try std.testing.expectEqual(@as(f64, 12), js_number.parseInt("12", 0));
}

test "parseFloat reads the number at the start of the text like JavaScript" {
    try std.testing.expectEqual(@as(f64, 12.5), js_number.parseFloat("  12.5abc"));
    try std.testing.expectEqual(@as(f64, -3), js_number.parseFloat("-3"));
    try std.testing.expectEqual(@as(f64, 1e3), js_number.parseFloat("1e3x"));
    try std.testing.expectEqual(@as(f64, 1), js_number.parseFloat("1e"));
    try std.testing.expect(std.math.isNan(js_number.parseFloat("abc")));
    try std.testing.expect(std.math.isNan(js_number.parseFloat(".")));
    try std.testing.expect(std.math.isNan(js_number.parseFloat("+")));
    try std.testing.expectEqual(@as(f64, 3.14), js_number.parseFloat("3.14abc"));
    try std.testing.expectEqual(@as(f64, -0.5), js_number.parseFloat("-.5"));
    try std.testing.expectEqual(std.math.inf(f64), js_number.parseFloat("Infinityx"));
}

//
// JavaScript's parseFloat skips all of JavaScript's whitespace, not only ASCII whitespace.
//
test "parseFloat skips Unicode whitespace before the number" {
    try std.testing.expectEqual(@as(f64, -2500), js_number.parseFloat("\u{3000}-2.5e3x"));
}

//
// A number and the text `String(number)` gives for it in Bun.
//
const INumberText = struct {
    // The number.
    value: f64,

    // The text.
    expected: []const u8,
};

test "writeNumber matches String(number)" {
    var buffer: [64]u8 = undefined;
    const cases = [_]INumberText{
        .{ .value = 0, .expected = "0" },
        .{ .value = -0.0, .expected = "0" },
        .{ .value = -42, .expected = "-42" },
        .{ .value = 123.456, .expected = "123.456" },
        .{ .value = -0.5, .expected = "-0.5" },
        .{ .value = 0.000123, .expected = "0.000123" },
        .{ .value = 1.5e-7, .expected = "1.5e-7" },
        .{ .value = 1e-7, .expected = "1e-7" },
        .{ .value = 5e-324, .expected = "5e-324" },
        .{ .value = 1e20, .expected = "100000000000000000000" },
        .{ .value = 1e21, .expected = "1e+21" },
        .{ .value = 123e25, .expected = "1.23e+27" },
        .{ .value = -2.5e30, .expected = "-2.5e+30" },
        .{ .value = 12345678901234567000.0, .expected = "12345678901234567000" },
        .{ .value = std.math.nan(f64), .expected = "NaN" },
        .{ .value = std.math.inf(f64), .expected = "Infinity" },
        .{ .value = -std.math.inf(f64), .expected = "-Infinity" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        try js_number.writeNumber(&writer, case.value);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

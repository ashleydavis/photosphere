const std = @import("std");
const serialization = @import("serialization-zig");

const js_number = serialization.js_number;

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

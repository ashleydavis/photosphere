const std = @import("std");

//
// No TypeScript counterpart: the JavaScript number formatting the TypeScript code relies on (`String(number)`).
// Moved here from bdb-zig's js-value.zig so the packages below bdb (merkle-tree-zig) can use it; js-value.zig
// re-exports it.
//

//
// Writes a JS number like `Number.prototype.toString()`: shortest round-trip digits, decimal notation for exponents
// in [-7, 21), exponential notation (`1e+21`, `1.5e-7`) otherwise.
//
pub fn writeNumber(writer: *std.Io.Writer, value: f64) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("NaN");
        return;
    }
    if (std.math.isInf(value)) {
        if (value < 0) {
            try writer.writeAll("-Infinity");
        }
        else {
            try writer.writeAll("Infinity");
        }
        return;
    }
    if (value == 0) {
        try writer.writeAll("0");
        return;
    }

    var buffer: [std.fmt.float.min_buffer_size]u8 = undefined;
    const scientific = std.fmt.float.render(&buffer, @abs(value), .{ .mode = .scientific }) catch unreachable;
    const exponentIndex = std.mem.indexOfScalar(u8, scientific, 'e') orelse unreachable;
    var digitBuffer: [32]u8 = undefined;
    var digitCount: usize = 0;
    for (scientific[0..exponentIndex]) |character| {
        if (character != '.') {
            digitBuffer[digitCount] = character;
            digitCount += 1;
        }
    }
    while (digitCount > 1 and digitBuffer[digitCount - 1] == '0') {
        digitCount -= 1;
    }
    const digits = digitBuffer[0..digitCount];
    const exponent = std.fmt.parseInt(i32, scientific[exponentIndex + 1 ..], 10) catch unreachable;

    // n is the position of the decimal point relative to the digits (ECMAScript Number::toString).
    const pointPosition: i32 = exponent + 1;
    const digitLength: i32 = @intCast(digits.len);

    if (value < 0) {
        try writer.writeAll("-");
    }

    if (digitLength <= pointPosition and pointPosition <= 21) {
        try writer.writeAll(digits);
        var zeros = pointPosition - digitLength;
        while (zeros > 0) {
            try writer.writeAll("0");
            zeros -= 1;
        }
        return;
    }
    if (0 < pointPosition and pointPosition <= 21) {
        const split: usize = @intCast(pointPosition);
        try writer.writeAll(digits[0..split]);
        try writer.writeAll(".");
        try writer.writeAll(digits[split..]);
        return;
    }
    if (-6 < pointPosition and pointPosition <= 0) {
        try writer.writeAll("0.");
        var zeros = -pointPosition;
        while (zeros > 0) {
            try writer.writeAll("0");
            zeros -= 1;
        }
        try writer.writeAll(digits);
        return;
    }
    try writer.writeAll(digits[0..1]);
    if (digits.len > 1) {
        try writer.writeAll(".");
        try writer.writeAll(digits[1..]);
    }
    const shownExponent = pointPosition - 1;
    if (shownExponent >= 0) {
        try writer.print("e+{d}", .{shownExponent});
    }
    else {
        try writer.print("e-{d}", .{-shownExponent});
    }
}

const std = @import("std");

//
// The unit names used by formatFileSize.
//
const sizes = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };

//
// Formats file size in bytes to human readable string.
// (Zig: the number is printed with `{d}`, the shortest round trip decimal, like JavaScript's number to string
// conversion for these values.)
//
pub fn formatFileSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    if (bytes == 0) {
        return allocator.dupe(u8, "0 B");
    }
    const k: f64 = 1024;
    const bytesFloat: f64 = @floatFromInt(bytes);
    const unitIndex: usize = @intFromFloat(@floor(@log(bytesFloat) / @log(k)));
    const value = bytesFloat / std.math.pow(f64, k, @floatFromInt(unitIndex));
    const rounded = @floor(value * 100 + 0.5) / 100;
    // TODO: a size of a petabyte or more reads past the end of the list, where the TypeScript does the same and writes
    // "undefined" for the unit.
    const unit = if (unitIndex < sizes.len) sizes[unitIndex] else "undefined";
    return std.fmt.allocPrint(allocator, "{d} {s}", .{ rounded, unit });
}

//
// The text padded on the left with the fill character to at least the width, allocated with the allocator. Equivalent
// of `text.padStart(width, fill)`.
//
pub fn padStart(allocator: std.mem.Allocator, text: []const u8, width: usize, fill: u8) ![]u8 {
    const padding = if (text.len >= width) 0 else width - text.len;
    const padded = try allocator.alloc(u8, padding + text.len);
    @memset(padded[0..padding], fill);
    @memcpy(padded[padding..], text);
    return padded;
}

//
// Equivalent of JavaScript `value.toFixed(2)`: a negative value is written with a minus sign (also when it rounds
// to zero, `-0.00`), then the integer n for which n / 100 is closest to the magnitude (the larger n on a tie) is
// picked, using the exact binary value of the double.
//
pub fn toFixed2(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    const sign: []const u8 = if (value < 0) "-" else "";
    const scaled: f128 = @as(f128, @abs(value)) * 100;
    var hundredths: u128 = @intFromFloat(@floor(scaled));
    const fraction = scaled - @floor(scaled);
    if (fraction >= 0.5) {
        hundredths += 1;
    }
    return std.mem.concat(allocator, u8, &.{ sign, try numberToString(allocator, hundredths / 100), ".", try paddedNumberToString(allocator, hundredths % 100, 2) });
}

//
// A number as decimal text, allocated with the allocator. This file has no TypeScript counterpart: the TypeScript
// calls `String(value)`.
//
pub fn numberToString(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buffer: [64]u8 = undefined;
    return allocator.dupe(u8, try std.fmt.bufPrint(&buffer, "{d}", .{value}));
}

//
// A number as decimal text, padded on the left with zeros to at least the width, allocated with the allocator. This
// file has no TypeScript counterpart: the TypeScript calls `String(value).padStart(width, "0")`.
//
pub fn paddedNumberToString(allocator: std.mem.Allocator, value: anytype, width: usize) ![]u8 {
    var buffer: [64]u8 = undefined;
    return allocator.dupe(u8, try std.fmt.bufPrint(&buffer, "{d:0>[1]}", .{ value, width }));
}

const std = @import("std");

//
// Options for formatBytes (TypeScript: `{ binary?: boolean; decimals?: number; locale?: string }`).
// Only the en-US locale is ported (it is the default and the only locale the CLI uses).
//
pub const IFormatBytesOptions = struct {
    // Use 1024-based units (KiB, MiB, ...) instead of 1000-based units (KB, MB, ...).
    binary: bool,

    // Maximum number of fraction digits for values below 10.
    decimals: u32,
};

//
// The default formatBytes options (`binary = true, decimals = 2, locale = 'en-US'`).
//
pub const defaultFormatBytesOptions: IFormatBytesOptions = .{ .binary = true, .decimals = 2 };

//
// Formats a value in bytes into a human-readable string.
//
pub fn formatBytes(allocator: std.mem.Allocator, bytes: f64, options: IFormatBytesOptions) ![]const u8 {
    const binary = options.binary;
    const decimals = options.decimals;

    if (bytes == 0) {
        return allocator.dupe(u8, "0 Bytes");
    }

    const k: f64 = if (binary) 1024 else 1000;
    const sizes = if (binary)
        [_][]const u8{ "Bytes", "KiB", "MiB", "GiB", "TiB", "PiB" }
    else
        [_][]const u8{ "Bytes", "KB", "MB", "GB", "TB", "PB" };

    const exponent = @floor(@log(bytes) / @log(k));
    const value = bytes / std.math.pow(f64, k, exponent);

    // Intelligent decimal handling
    var formatted: []const u8 = undefined;
    if (value >= 100 or @mod(value, 1) == 0) {
        // No decimals for whole numbers or values >= 100
        formatted = try toLocaleString(allocator, jsMathRound(value), 0);
    }
    else if (value >= 10) {
        // 1 decimal for values 10-99
        formatted = try toLocaleString(allocator, value, 1);
    }
    else {
        // Up to specified decimals for small values
        formatted = try toLocaleString(allocator, value, decimals);
    }

    const index: usize = @intFromFloat(exponent);
    const unit = if (index < sizes.len) sizes[index] else "undefined";
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ formatted, unit });
}

// Not ported: formatDuration, formatBitrate (not used by replicate or verify).

//
// JavaScript Math.round: rounds half up (towards +Infinity).
//
fn jsMathRound(value: f64) f64 {
    return @floor(value + 0.5);
}

//
// Equivalent of `value.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits })`
// for a non-negative finite value: the shortest decimal representation of the number is rounded half
// away from zero to maximumFractionDigits, trailing zeros are dropped and the integer part is grouped
// with commas. This function has no TypeScript counterpart (Intl.NumberFormat stand-in).
//
pub fn toLocaleString(allocator: std.mem.Allocator, value: f64, maximumFractionDigits: u32) ![]const u8 {
    var shortest_buffer: [64]u8 = undefined;
    const shortest = try std.fmt.bufPrint(&shortest_buffer, "{d}", .{value});

    // Split the shortest representation into integer and fraction digits.
    var integer_digits: std.ArrayList(u8) = .empty;
    var fraction_digits: std.ArrayList(u8) = .empty;
    const dot_index = std.mem.indexOfScalar(u8, shortest, '.');
    if (dot_index) |dot| {
        try integer_digits.appendSlice(allocator, shortest[0..dot]);
        try fraction_digits.appendSlice(allocator, shortest[dot + 1 ..]);
    }
    else {
        try integer_digits.appendSlice(allocator, shortest);
    }

    // Round half away from zero at maximumFractionDigits.
    if (fraction_digits.items.len > maximumFractionDigits) {
        const round_up = fraction_digits.items[maximumFractionDigits] >= '5';
        fraction_digits.shrinkRetainingCapacity(maximumFractionDigits);
        if (round_up) {
            var carry = true;
            var fraction_index = fraction_digits.items.len;
            while (carry and fraction_index > 0) {
                fraction_index -= 1;
                if (fraction_digits.items[fraction_index] == '9') {
                    fraction_digits.items[fraction_index] = '0';
                }
                else {
                    fraction_digits.items[fraction_index] += 1;
                    carry = false;
                }
            }
            var integer_index = integer_digits.items.len;
            while (carry and integer_index > 0) {
                integer_index -= 1;
                if (integer_digits.items[integer_index] == '9') {
                    integer_digits.items[integer_index] = '0';
                }
                else {
                    integer_digits.items[integer_index] += 1;
                    carry = false;
                }
            }
            if (carry) {
                try integer_digits.insert(allocator, 0, '1');
            }
        }
    }

    // Drop trailing zeros (minimumFractionDigits is 0).
    while (fraction_digits.items.len > 0 and fraction_digits.items[fraction_digits.items.len - 1] == '0') {
        fraction_digits.shrinkRetainingCapacity(fraction_digits.items.len - 1);
    }

    // Group the integer digits with commas.
    var result: std.ArrayList(u8) = .empty;
    const integer_length = integer_digits.items.len;
    for (integer_digits.items, 0..) |digit, digit_index| {
        if (digit_index > 0 and (integer_length - digit_index) % 3 == 0) {
            try result.append(allocator, ',');
        }
        try result.append(allocator, digit);
    }
    if (fraction_digits.items.len > 0) {
        try result.append(allocator, '.');
        try result.appendSlice(allocator, fraction_digits.items);
    }
    return result.items;
}

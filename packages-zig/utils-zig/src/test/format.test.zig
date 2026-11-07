const std = @import("std");
const utils = @import("utils-zig");

test "formatFileSize formats zero bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0 B", try utils.format.formatFileSize(arena.allocator(), 0));
}

test "formatFileSize formats bytes, kilobytes and megabytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 B", try utils.format.formatFileSize(allocator, 1));
    try std.testing.expectEqualStrings("1023 B", try utils.format.formatFileSize(allocator, 1023));
    try std.testing.expectEqualStrings("1 KB", try utils.format.formatFileSize(allocator, 1024));
    try std.testing.expectEqualStrings("1.5 KB", try utils.format.formatFileSize(allocator, 1536));
    try std.testing.expectEqualStrings("1.21 KB", try utils.format.formatFileSize(allocator, 1234));
    try std.testing.expectEqualStrings("1 MB", try utils.format.formatFileSize(allocator, 1024 * 1024));
    try std.testing.expectEqualStrings("2.5 GB", try utils.format.formatFileSize(allocator, 1024 * 1024 * 1024 * 5 / 2));
}

//
// The sizes list stops at TB, so a petabyte or more reads `sizes[5]`, which is undefined.
//
test "formatFileSize names the unit undefined from a petabyte up" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1 undefined", try utils.format.formatFileSize(allocator, 1024 * 1024 * 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("3 undefined", try utils.format.formatFileSize(allocator, 3 * 1024 * 1024 * 1024 * 1024 * 1024));
}

test "formatFileSize keeps the unit of the size it divided, when rounding reaches the next one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A byte short of a terabyte divides to 1023.999..., which rounds to 1024, so the answer reads
    // "1024 GB" rather than the "1 TB" it is one byte short of.
    try std.testing.expectEqualStrings("1024 GB", try utils.format.formatFileSize(allocator, 1024 * 1024 * 1024 * 1024 - 1));
}

test "numberToString writes integers as decimal text" {
    const allocator = std.testing.allocator;
    const zero = try utils.format.numberToString(allocator, @as(u32, 0));
    defer allocator.free(zero);
    try std.testing.expectEqualStrings("0", zero);
    const negative = try utils.format.numberToString(allocator, @as(i64, -1234567890123));
    defer allocator.free(negative);
    try std.testing.expectEqualStrings("-1234567890123", negative);
    const largest = try utils.format.numberToString(allocator, std.math.maxInt(u64));
    defer allocator.free(largest);
    try std.testing.expectEqualStrings("18446744073709551615", largest);
}

test "paddedNumberToString pads with zeros and never truncates" {
    const allocator = std.testing.allocator;
    const padded = try utils.format.paddedNumberToString(allocator, @as(u32, 7), 3);
    defer allocator.free(padded);
    try std.testing.expectEqualStrings("007", padded);
    const wide = try utils.format.paddedNumberToString(allocator, @as(u32, 12345), 3);
    defer allocator.free(wide);
    try std.testing.expectEqualStrings("12345", wide);
}

test "padStart pads on the left and leaves text that is already wide enough" {
    const allocator = std.testing.allocator;
    const padded = try utils.format.padStart(allocator, "42", 4, ' ');
    defer allocator.free(padded);
    try std.testing.expectEqualStrings("  42", padded);
    const wide = try utils.format.padStart(allocator, "12345", 4, ' ');
    defer allocator.free(wide);
    try std.testing.expectEqualStrings("12345", wide);
}

test "toFixed2 writes two decimals like JavaScript's toFixed(2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1.50", try utils.format.toFixed2(allocator, 1.5));
    try std.testing.expectEqualStrings("0.00", try utils.format.toFixed2(allocator, 0));
    try std.testing.expectEqualStrings("-2.35", try utils.format.toFixed2(allocator, -2.345));
    try std.testing.expectEqualStrings("12.00", try utils.format.toFixed2(allocator, 11.999));
}

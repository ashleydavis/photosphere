const std = @import("std");
const utils = @import("utils-zig");

test "formatFileSize formats zero bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0 B", try utils.format.formatFileSize(arena.allocator(), 0));
}

test "formatFileSize formats bytes, kilobytes and megabytes like TypeScript" {
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
// TypeScript's sizes list stops at TB, so a petabyte or more reads `sizes[5]`, which is undefined.
//
test "formatFileSize names the unit undefined from a petabyte up, like TypeScript" {
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

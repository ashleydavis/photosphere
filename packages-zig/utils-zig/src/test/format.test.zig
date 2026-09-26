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

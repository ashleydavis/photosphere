const std = @import("std");
const utils = @import("utils-zig");

test "toHex writes two lowercase characters for each byte" {
    const text = try utils.hex.toHex(std.testing.allocator, &.{ 0x00, 0x0f, 0xa5, 0xff });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("000fa5ff", text);
}

test "toHex of no bytes is empty text" {
    const text = try utils.hex.toHex(std.testing.allocator, &.{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "toHex matches the standard library's hex formatting" {
    const bytes = [_]u8{ 1, 2, 254, 17, 128 };
    const expected = try utils.hex.toHex(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(expected);
    const text = try utils.hex.toHex(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

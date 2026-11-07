//
// Hexadecimal text for bytes.
//

const std = @import("std");

//
// The bytes as lowercase hexadecimal text, two characters for each byte, allocated with the allocator.
//
pub fn toHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const text = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        text[index * 2] = digits[byte >> 4];
        text[index * 2 + 1] = digits[byte & 0x0f];
    }
    return text;
}

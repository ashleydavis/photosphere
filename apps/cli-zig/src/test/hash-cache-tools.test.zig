const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const bufferFromHex = cli.hash_cache_tools.bufferFromHex;
const cachedLength = cli.hash_cache_tools.cachedLength;
const formatModified = cli.hash_cache.formatModified;

test "bufferFromHex decodes pairs of hex digits like Buffer.from(text, 'hex')" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x1f, 0xab, 0xff }, try bufferFromHex(allocator, "001fABff"));
    try std.testing.expectEqualSlices(u8, &.{}, try bufferFromHex(allocator, ""));

    // Node stops at the first pair that is not hex, and ignores a trailing odd digit.
    try std.testing.expectEqualSlices(u8, &.{0x12}, try bufferFromHex(allocator, "12zz34"));
    try std.testing.expectEqualSlices(u8, &.{0x12}, try bufferFromHex(allocator, "123"));
    try std.testing.expectEqualSlices(u8, &.{}, try bufferFromHex(allocator, "zz12"));
}

test "cachedLength stores a length like writeUIntLE(parseInt(length, 10), offset, 6)" {
    try std.testing.expectEqual(@as(u64, 1234), try cachedLength(1234));
    try std.testing.expectEqual(@as(u64, 0), try cachedLength(0));

    // NaN is written as 0.
    try std.testing.expectEqual(@as(u64, 0), try cachedLength(std.math.nan(f64)));

    // A negative length is out of range.
    try std.testing.expectError(error.Thrown, cachedLength(-5));
    try std.testing.expectEqualStrings("RangeError", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received -5", utils.errors.lastErrorMessage());

    // A length of 2 ** 48 or more is out of range, and the number is printed as JavaScript prints it.
    try std.testing.expectError(error.Thrown, cachedLength(281474976710656));
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received 281474976710656", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cachedLength(utils.js_number.parseInt("123456789012345678901234567890", 10)));
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received 1.2345678901234568e+29", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cachedLength(18446744073709549568));
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received 18446744073709550000", utils.errors.lastErrorMessage());
}

test "formatModified formats a time like toISOString().replace('T', ' ').slice(0, 19)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("1970-01-01 00:00:00", try formatModified(allocator, 0));
    try std.testing.expectEqualStrings("2024-03-05 06:07:08", try formatModified(allocator, 1709618828999));
}

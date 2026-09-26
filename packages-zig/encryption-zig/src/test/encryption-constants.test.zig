const std = @import("std");
const encryption = @import("encryption-zig");

const constants = encryption.encryption_constants;

test "ENCRYPTION_TAG is 4 characters and equals PSEN" {
    try std.testing.expectEqualStrings("PSEN", constants.ENCRYPTION_TAG);
    try std.testing.expectEqual(@as(usize, 4), constants.ENCRYPTION_TAG.len);
}

test "ENCRYPTION_FORMAT_VERSION is 1" {
    try std.testing.expectEqual(@as(u32, 1), constants.ENCRYPTION_FORMAT_VERSION);
}

test "ENCRYPTION_TYPE is 4-character string A2CB" {
    try std.testing.expectEqualStrings("A2CB", constants.ENCRYPTION_TYPE);
    try std.testing.expectEqual(@as(usize, 4), constants.ENCRYPTION_TYPE.len);
}

test "PUBLIC_KEY_HASH_LENGTH is 32" {
    try std.testing.expectEqual(@as(usize, 32), constants.PUBLIC_KEY_HASH_LENGTH);
}

test "header lengths match the TypeScript values" {
    try std.testing.expectEqual(@as(usize, 528), constants.LEGACY_HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 44), constants.NEW_FORMAT_HEADER_LENGTH);
    try std.testing.expectEqual(@as(usize, 572), constants.NEW_FORMAT_PAYLOAD_OFFSET);
    try std.testing.expectEqualSlices(u32, &.{1}, &constants.SUPPORTED_VERSIONS);
    try std.testing.expectEqual(@as(usize, 1), constants.SUPPORTED_TYPES.len);
    try std.testing.expectEqualStrings("A2CB", constants.SUPPORTED_TYPES[0]);
}

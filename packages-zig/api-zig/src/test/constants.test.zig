const std = @import("std");
const api_zig = @import("api-zig");

test "LARGE_FILE_TIMEOUT is 90 minutes in milliseconds" {
    try std.testing.expectEqual(@as(u64, 5_400_000), api_zig.constants.LARGE_FILE_TIMEOUT);
}

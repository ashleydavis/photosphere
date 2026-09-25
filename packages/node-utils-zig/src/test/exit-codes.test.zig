const std = @import("std");
const node_utils = @import("node-utils-zig");
const exit_codes = node_utils.exit_codes;

test "exit codes match TypeScript" {
    try std.testing.expectEqual(@as(u8, 0), exit_codes.EXIT_SUCCESS);
    try std.testing.expectEqual(@as(u8, 1), exit_codes.EXIT_FAILURE);
    try std.testing.expectEqual(@as(u8, 64), exit_codes.EXIT_UNCAUGHT_EXCEPTION);
    try std.testing.expectEqual(@as(u8, 65), exit_codes.EXIT_UNHANDLED_REJECTION);
    try std.testing.expectEqual(@as(u8, 66), exit_codes.EXIT_TERMINATION_CALLBACKS_THREW);
    try std.testing.expectEqual(@as(u8, 67), exit_codes.EXIT_SIGTERM_CLEANUP_FAILED);
    try std.testing.expectEqual(@as(u8, 68), exit_codes.EXIT_SIGINT_CLEANUP_FAILED);
    try std.testing.expectEqual(@as(u8, 69), exit_codes.EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED);
    try std.testing.expectEqual(@as(u8, 70), exit_codes.EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED);
}

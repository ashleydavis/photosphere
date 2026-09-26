const std = @import("std");
const node_utils = @import("node-utils-zig");
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;

test "now() starts at 2022-01-01 and advances by one millisecond per call" {
    var provider: TestTimestampProvider = .{};
    const interface = provider.timestampProvider();
    try std.testing.expectEqual(@as(i64, 1640995200000), interface.now(std.testing.io));
    try std.testing.expectEqual(@as(i64, 1640995200001), interface.now(std.testing.io));
    try std.testing.expectEqual(@as(i64, 1640995200002), provider.now());
}

test "dateNow() returns the next timestamp as a Date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var provider: TestTimestampProvider = .{};
    const date = provider.timestampProvider().dateNow(std.testing.io);
    try std.testing.expectEqualStrings("2022-01-01T00:00:00.000Z", try date.toISOString(arena.allocator()));
    try std.testing.expectEqual(@as(i64, 1640995200001), provider.dateNow().epochMilliseconds);
}

test "reset() restarts the sequence" {
    var provider: TestTimestampProvider = .{};
    _ = provider.now();
    _ = provider.now();
    provider.reset();
    try std.testing.expectEqual(@as(i64, 1640995200000), provider.now());
}

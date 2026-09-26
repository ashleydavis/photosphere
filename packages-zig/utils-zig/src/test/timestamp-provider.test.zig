const std = @import("std");
const utils = @import("utils-zig");
const timestamp_provider = utils.timestamp_provider;

test "TimestampProvider.now returns the current wall-clock time" {
    const io = std.testing.io;
    var provider: timestamp_provider.TimestampProvider = .{};
    const interface = provider.timestampProvider();
    const before = std.Io.Clock.real.now(io).toMilliseconds();
    const now = interface.now(io);
    const after = std.Io.Clock.real.now(io).toMilliseconds();
    try std.testing.expect(now >= before);
    try std.testing.expect(now <= after);

    // Later than 2020-01-01.
    try std.testing.expect(now > 1577836800000);
}

test "TimestampProvider.dateNow returns the current time as a Date" {
    const io = std.testing.io;
    var provider: timestamp_provider.TimestampProvider = .{};
    const before = std.Io.Clock.real.now(io).toMilliseconds();
    const date = provider.timestampProvider().dateNow(io);
    try std.testing.expect(date.epochMilliseconds >= before);
}

test "Date.toISOString matches JavaScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Values from `new Date(ms).toISOString()` in JavaScript.
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", try (timestamp_provider.Date{ .epochMilliseconds = 0 }).toISOString(allocator));
    try std.testing.expectEqualStrings("2022-01-01T00:00:00.000Z", try (timestamp_provider.Date{ .epochMilliseconds = 1640995200000 }).toISOString(allocator));
    try std.testing.expectEqualStrings("2024-02-29T23:59:59.999Z", try (timestamp_provider.Date{ .epochMilliseconds = 1709251199999 }).toISOString(allocator));
    try std.testing.expectEqualStrings("2001-09-09T01:46:40.123Z", try (timestamp_provider.Date{ .epochMilliseconds = 1000000000123 }).toISOString(allocator));
    try std.testing.expectEqualStrings("1969-12-31T23:59:59.999Z", try (timestamp_provider.Date{ .epochMilliseconds = -1 }).toISOString(allocator));
}

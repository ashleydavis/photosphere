const std = @import("std");
const utils = @import("utils-zig");

test "sleep waits for at least the requested time" {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    try utils.sleep.sleep(io, 20);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(elapsed.toMilliseconds() >= 20);
}

test "sleep waits a millisecond for a delay setTimeout would not wait" {
    // setTimeout never waits less than a millisecond, so sleep(0) waits one rather than returning at once.
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    try utils.sleep.sleep(io, 0);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(elapsed.nanoseconds >= std.Io.Duration.fromMilliseconds(1).nanoseconds);
}

test "setTimeoutDelay gives the delay setTimeout waits: 1 for a delay under 1, past 2147483647 or NaN" {
    try std.testing.expectEqual(@as(u64, 250), utils.sleep.setTimeoutDelay(250.9));
    try std.testing.expectEqual(@as(u64, 1), utils.sleep.setTimeoutDelay(0.0001));
    try std.testing.expectEqual(@as(u64, 1), utils.sleep.setTimeoutDelay(2147483648));
    try std.testing.expectEqual(@as(u64, 1), utils.sleep.setTimeoutDelay(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u64, 2147483647), utils.sleep.setTimeoutDelay(2147483647));
}

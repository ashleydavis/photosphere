const std = @import("std");

//
// Sleeps for the given number of milliseconds.
// (Zig: the delay goes through setTimeoutDelay, so a delay under a millisecond waits the same millisecond a delay of 1
// does, where Node's setTimeout waits at least a millisecond. A Windows sleep can wake a little before the time it was
// given, by the resolution of the system timer, so it sleeps again for whatever is left.)
//
pub fn sleep(io: std.Io, timeMS: u64) !void {
    const milliseconds = setTimeoutDelay(@floatFromInt(timeMS));
    const duration: std.Io.Duration = .fromMilliseconds(@intCast(milliseconds));
    const start = std.Io.Clock.awake.now(io);
    var remaining = duration;
    while (remaining.nanoseconds > 0) {
        try io.sleep(remaining, .awake);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
        remaining = .{ .nanoseconds = duration.nanoseconds - elapsed.nanoseconds };
    }
}

//
// The delay `setTimeout(callback, delay)` waits, in whole milliseconds: a delay that is not between 1 and
// 2147483647 (NaN included) is 1.
//
pub fn setTimeoutDelay(delay: f64) u64 {
    if (!(delay >= 1 and delay <= 2147483647)) {
        return 1;
    }
    return @intFromFloat(@floor(delay));
}

const std = @import("std");

//
// Sleeps for the specified millseconds.
// (Zig: like setTimeout, it never returns early. A Windows sleep can wake a little before the time it was given,
// by the resolution of the system timer, so it sleeps again for whatever is left.)
//
pub fn sleep(io: std.Io, timeMS: u64) !void {
    const duration: std.Io.Duration = .fromMilliseconds(@intCast(timeMS));
    const start = std.Io.Clock.awake.now(io);
    var remaining = duration;
    while (remaining.nanoseconds > 0) {
        try io.sleep(remaining, .awake);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
        remaining = .{ .nanoseconds = duration.nanoseconds - elapsed.nanoseconds };
    }
}

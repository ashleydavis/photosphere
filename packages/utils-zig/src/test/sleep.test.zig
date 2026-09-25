const std = @import("std");
const utils = @import("utils-zig");

test "sleep waits for at least the requested time" {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    try utils.sleep.sleep(io, 20);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(elapsed.toMilliseconds() >= 20);
}

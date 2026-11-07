const std = @import("std");
const virtual_time_io = @import("virtual-time-io.zig");

test "a sleep on the virtual time Io takes no real time and moves the virtual clock by all of it" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    const realStart = std.Io.Clock.awake.now(std.testing.io);
    const virtualStart = std.Io.Clock.awake.now(io);
    try io.sleep(.fromMilliseconds(2000), .awake);
    const realElapsedMs = realStart.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds();
    const virtualElapsedMs = virtualStart.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    try std.testing.expect(realElapsedMs < 1000);
    try std.testing.expectEqual(@as(i64, 2000), virtualElapsedMs);
}

test "a sleep to a deadline on the virtual time Io moves the virtual clock to the deadline, and a deadline already passed moves nothing" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    const deadline: std.Io.Timestamp = .{
        .nanoseconds = std.Io.Clock.awake.now(io).nanoseconds + 3_000_000_000,
    };
    try io.vtable.sleep(io.userdata, .{ .deadline = .{ .raw = deadline, .clock = .awake } });
    try std.testing.expectEqual(deadline.nanoseconds, std.Io.Clock.awake.now(io).nanoseconds);

    try io.vtable.sleep(io.userdata, .{ .deadline = .{ .raw = .{ .nanoseconds = deadline.nanoseconds - 1_000_000_000 }, .clock = .awake } });
    try std.testing.expectEqual(deadline.nanoseconds, std.Io.Clock.awake.now(io).nanoseconds);
}

test "a futex wait with a timeout on the virtual time Io ends at once, after the virtual clock has moved by the timeout" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    const word: u32 = 0;
    const realStart = std.Io.Clock.awake.now(std.testing.io);
    const virtualStart = std.Io.Clock.awake.now(io);
    try io.futexWaitTimeout(u32, &word, 0, .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } });

    try std.testing.expect(realStart.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 1000);
    try std.testing.expectEqual(@as(i64, 30_000), virtualStart.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds());
}

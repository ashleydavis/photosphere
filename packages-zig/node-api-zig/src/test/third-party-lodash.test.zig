const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const throttle = node_api.lodash_throttle.throttle;
const sleep = utils.sleep.sleep;

//
// (Zig: lodash is an npm package with no tests in this repository; these cover the port of throttle the import
// uses: `throttle(func, 1000, { leading: false, trailing: true })`.)
//

//
// Counts the calls of the throttled function.
//
const Counter = struct {
    // How many times the function ran.
    calls: std.atomic.Value(u32) = .init(0),

    //
    // The throttled function.
    //
    fn call(context: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        _ = self.calls.fetchAdd(1, .seq_cst);
    }
};

test "a trailing throttle runs the function once, after the wait, for calls that came together" {
    const io = std.testing.io;
    var loopLock: std.Io.Mutex = .init;
    var counter: Counter = .{};
    var throttled = throttle(io, .{
        .context = &counter,
        .function = Counter.call,
    }, 50, .{
        .leading = false,
        .trailing = true,
    }, &loopLock);
    try throttled.start();
    defer throttled.deinit();

    {
        loopLock.lockUncancelable(io);
        // Unlocked on the way out, even when a check fails: deinit waits for the timer, which waits for the lock.
        defer loopLock.unlock(io);
        throttled.call();
        throttled.call();
        throttled.call();
        // Nothing runs on the leading edge.
        try std.testing.expectEqual(@as(u32, 0), counter.calls.load(.seq_cst));
    }

    try sleep(io, 500);

    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.seq_cst));
}

test "flush runs a delayed call at once, and cancel drops one" {
    const io = std.testing.io;
    var loopLock: std.Io.Mutex = .init;
    var counter: Counter = .{};
    var throttled = throttle(io, .{
        .context = &counter,
        .function = Counter.call,
    }, 60000, .{
        .leading = false,
        .trailing = true,
    }, &loopLock);
    try throttled.start();
    defer throttled.deinit();

    loopLock.lockUncancelable(io);
    // Unlocked on the way out, even when a check fails: deinit waits for the timer, which waits for the lock.
    defer loopLock.unlock(io);
    throttled.call();
    throttled.flush();
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.seq_cst));

    throttled.call();
    throttled.cancel();
    throttled.flush();
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.seq_cst));
}

test "the timer waits for the loop lock, so the function never runs beside the code that holds it" {
    const io = std.testing.io;
    var loopLock: std.Io.Mutex = .init;
    var counter: Counter = .{};
    var throttled = throttle(io, .{
        .context = &counter,
        .function = Counter.call,
    }, 20, .{
        .leading = false,
        .trailing = true,
    }, &loopLock);
    try throttled.start();
    defer throttled.deinit();

    {
        loopLock.lockUncancelable(io);
        // Unlocked on the way out, even when a check fails: deinit waits for the timer, which waits for the lock.
        defer loopLock.unlock(io);
        throttled.call();
        // Long past the wait, but the lock is held, so the timer has not run the function.
        try sleep(io, 300);
        try std.testing.expectEqual(@as(u32, 0), counter.calls.load(.seq_cst));
    }

    try sleep(io, 300);
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.seq_cst));
}

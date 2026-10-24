const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const ziggy = @import("ziggy");
const TimerList = ziggy.timers.TimerList;
const throttle = node_api.lodash_throttle.throttle;
const sleep = utils.sleep.sleep;

//
// (Zig: lodash is an npm package with no tests in this repository; these cover the port of throttle the import
// uses: `throttle(func, 1000, { leading: false, trailing: true })`. Its timers are a list the test owns, which run when the test
// runs the ones that are due, as a thread runs its timers while it waits for a message.)
//

//
// Counts the calls of the throttled function.
//
const Counter = struct {
    // How many times the function ran.
    calls: u32 = 0,

    //
    // The throttled function.
    //
    fn call(context: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
};

//
// Waits for the next timer and runs the ones that are due, until the counter has the number of calls or no timer is left to call
// it.
//
fn runTimersUntilCalled(io: std.Io, timer_list: *TimerList, counter: *Counter, calls: u32) !void {
    while (counter.calls < calls and timer_list.nextTimeout() != .none) {
        try timer_list.nextTimeout().sleep(io);
        timer_list.runDue(io, std.testing.allocator, null);
    }
}

test "a trailing throttle runs the function once, after the wait, for calls that came together" {
    const io = std.testing.io;
    var timer_list = TimerList.init();
    var counter: Counter = .{};
    var throttled = throttle(.{
        .context = &counter,
        .function = Counter.call,
    }, 50, .{
        .leading = false,
        .trailing = true,
    });
    defer throttled.deinit(timer_list.interface());

    throttled.call(io, timer_list.interface());
    throttled.call(io, timer_list.interface());
    throttled.call(io, timer_list.interface());
    // Nothing runs on the leading edge.
    try std.testing.expectEqual(@as(u32, 0), counter.calls);

    try runTimersUntilCalled(io, &timer_list, &counter, 1);
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
    // The calls that came together ran it once: no timer is left to run it again.
    try std.testing.expect(timer_list.nextTimeout() == .none);
}

test "flush runs a delayed call at once, and cancel drops one" {
    const io = std.testing.io;
    var timer_list = TimerList.init();
    var counter: Counter = .{};
    var throttled = throttle(.{
        .context = &counter,
        .function = Counter.call,
    }, 60000, .{
        .leading = false,
        .trailing = true,
    });
    defer throttled.deinit(timer_list.interface());

    throttled.call(io, timer_list.interface());
    throttled.flush(io, timer_list.interface());
    try std.testing.expectEqual(@as(u32, 1), counter.calls);

    throttled.call(io, timer_list.interface());
    throttled.cancel(timer_list.interface());
    throttled.flush(io, timer_list.interface());
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
}

test "flush leaves no timer set" {
    const io = std.testing.io;
    var timer_list = TimerList.init();
    var counter: Counter = .{};
    var throttled = throttle(.{
        .context = &counter,
        .function = Counter.call,
    }, 60000, .{
        .leading = false,
        .trailing = true,
    });
    defer throttled.deinit(timer_list.interface());

    throttled.call(io, timer_list.interface());
    throttled.flush(io, timer_list.interface());
    try std.testing.expect(timer_list.nextTimeout() == .none);
}

test "the function runs only while the thread runs its timers, never beside the thread's other code" {
    const io = std.testing.io;
    var timer_list = TimerList.init();
    var counter: Counter = .{};
    var throttled = throttle(.{
        .context = &counter,
        .function = Counter.call,
    }, 20, .{
        .leading = false,
        .trailing = true,
    });
    defer throttled.deinit(timer_list.interface());

    throttled.call(io, timer_list.interface());
    // Long past the wait, but the thread has not run its timers, so the timer has not run the function.
    try sleep(io, 300);
    try std.testing.expectEqual(@as(u32, 0), counter.calls);

    try runTimersUntilCalled(io, &timer_list, &counter, 1);
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
}

//
// Port of lodash 4.17.21 throttle.js (MIT license, (c) OpenJS Foundation and other contributors).
//
// Creates a throttled function that only invokes `func` at most once per every `wait` milliseconds. The throttled
// function comes with a `cancel` method to cancel delayed `func` invocations and a `flush` method to immediately
// invoke them. See debounce.zig for how its timer fires in Zig.
//

const std = @import("std");
const debounce = @import("debounce.zig");
const Debounced = debounce.Debounced;
const DebouncedFunction = debounce.DebouncedFunction;

//
// The options of throttle.
//
pub const IThrottleOptions = struct {
    // Specify invoking on the leading edge of the timeout.
    leading: bool,

    // Specify invoking on the trailing edge of the timeout.
    trailing: bool,
};

//
// Creates a throttled function (TypeScript: `throttle(func, wait, options)`): a debounced function whose maximum
// wait is its wait.
//
pub fn throttle(io: std.Io, func: DebouncedFunction, wait: i64, options: IThrottleOptions, loopLock: *std.Io.Mutex) Debounced {
    return Debounced.init(io, func, wait, .{
        .leading = options.leading,
        .maxWait = wait,
        .trailing = options.trailing,
    }, loopLock);
}

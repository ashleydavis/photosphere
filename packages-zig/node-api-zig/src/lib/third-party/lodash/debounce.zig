//
// Port of lodash 4.17.21 debounce.js (MIT license, (c) OpenJS Foundation and other contributors).
//
// Creates a debounced function that delays invoking `func` until after `wait` milliseconds have elapsed since the
// last time the debounced function was invoked. The debounced function comes with a `cancel` method to cancel delayed
// `func` invocations and a `flush` method to immediately invoke them.
//
// The timers lodash starts with setTimeout fire on JavaScript's one thread, between whatever else that thread is
// doing. Here they are the timers of the thread that uses the debounced function, which each method that sets or clears one
// is given (Timers), and which fire while that thread waits for a message. So `func` runs on the same thread as the
// caller's other code, never at the same time as it, and the debounced function is used only on that thread.
//
// The throttled function in Photosphere takes no arguments and returns nothing, and `wait` and `maxWait` are whole
// milliseconds.
//

const std = @import("std");
const ziggy = @import("ziggy");

const TimerId = ziggy.timers.TimerId;
const Timers = ziggy.timers.Timers;

//
// The function a debounced function invokes (TypeScript: `func`, called with the last arguments; here there are none).
//
pub const DebouncedFunction = struct {
    // The state of the function, passed to function.
    context: *anyopaque,

    // The function.
    function: *const fn (context: *anyopaque) void,
};

//
// The options of debounce.
//
pub const IDebounceOptions = struct {
    // Specify invoking on the leading edge of the timeout.
    leading: bool,

    // The maximum time `func` is allowed to be delayed before it's invoked, or null for none.
    maxWait: ?i64,

    // Specify invoking on the trailing edge of the timeout.
    trailing: bool,
};

//
// A debounced function (TypeScript: the `debounced` function debounce returns, with its `cancel` and `flush`).
//
pub const Debounced = struct {
    // The function to debounce.
    func: DebouncedFunction,

    // The number of milliseconds to delay.
    wait: i64,

    // The maximum time func is allowed to be delayed.
    maxWait: i64,

    // Whether a maximum wait was given.
    maxing: bool,

    // Invoke on the leading edge of the timeout.
    leading: bool,

    // Invoke on the trailing edge of the timeout.
    trailing: bool,

    // Whether the debounced function has been called since func was last invoked (TypeScript: lastArgs, which is
    // the arguments object of the last call and undefined once they have been used).
    lastArgs: bool,

    // When the debounced function was last called, or null (TypeScript: undefined) before the first call.
    lastCallTime: ?i64,

    // When func was last invoked.
    lastInvokeTime: i64,

    // The timer that is set, or null (TypeScript: timerId, undefined when none is set).
    timerId: ?TimerId,

    //
    // Creates a debounced function (TypeScript: `debounce(func, wait, options)`). It must not move once it has been called.
    //
    pub fn init(func: DebouncedFunction, wait: i64, options: IDebounceOptions) Debounced {
        return .{
            .func = func,
            .wait = wait,
            .maxWait = if (options.maxWait) |maxWait| @max(maxWait, wait) else 0,
            .maxing = options.maxWait != null,
            .leading = options.leading,
            .trailing = options.trailing,
            .lastArgs = false,
            .lastCallTime = null,
            .lastInvokeTime = 0,
            .timerId = null,
        };
    }

    //
    // Clears the timer that is set, if any. (No TypeScript counterpart: a JavaScript function is garbage collected, and its timer
    // holds it; here the timer holds a pointer to it, so it is cleared before it goes.)
    //
    pub fn deinit(self: *Debounced, timers: Timers) void {
        if (self.timerId) |id| {
            timers.clearTimeout(id);
            self.timerId = null;
        }
    }

    //
    // The current time (TypeScript: `now()`, which is Date.now).
    //
    fn now(io: std.Io) i64 {
        return std.Io.Clock.real.now(io).toMilliseconds();
    }

    //
    // setTimeout(timerExpired, delay): timerExpired runs on this thread once delay has passed.
    //
    fn setTimeout(self: *Debounced, io: std.Io, timers: Timers, delay: i64) void {
        self.timerId = timers.setTimeout(io, .{
            .context = self,
            .function = timerFired,
        }, @intCast(@max(delay, 0))) catch |err| {
            std.debug.panic("A debounced function could not set its timer: {s}", .{@errorName(err)});
        };
    }

    //
    // clearTimeout(timerId).
    //
    fn clearTimeout(self: *Debounced, timers: Timers) void {
        if (self.timerId) |id| {
            timers.clearTimeout(id);
        }
    }

    //
    // The timer's callback, which runs timerExpired.
    //
    fn timerFired(context: ?*anyopaque, io: std.Io, _: std.mem.Allocator, timers: Timers, _: ?*const anyopaque) void {
        const self: *Debounced = @ptrCast(@alignCast(context.?));
        self.timerExpired(io, timers);
    }

    //
    // Invokes func with the last arguments.
    //
    fn invokeFunc(self: *Debounced, time: i64) void {
        self.lastArgs = false;
        self.lastInvokeTime = time;
        self.func.function(self.func.context);
    }

    //
    // The first call of a wait.
    //
    fn leadingEdge(self: *Debounced, io: std.Io, timers: Timers, time: i64) void {
        // Reset any `maxWait` timer.
        self.lastInvokeTime = time;
        // Start the timer for the trailing edge.
        self.setTimeout(io, timers, self.wait);
        // Invoke the leading edge.
        if (self.leading) {
            self.invokeFunc(time);
        }
    }

    //
    // How long is left before the timer should fire.
    //
    fn remainingWait(self: *Debounced, time: i64) i64 {
        const timeSinceLastCall = time - self.lastCallTime.?;
        const timeSinceLastInvoke = time - self.lastInvokeTime;
        const timeWaiting = self.wait - timeSinceLastCall;

        return if (self.maxing)
            @min(timeWaiting, self.maxWait - timeSinceLastInvoke)
        else
            timeWaiting;
    }

    //
    // Whether func should be invoked now.
    //
    fn shouldInvoke(self: *Debounced, time: i64) bool {
        const lastCallTime = self.lastCallTime orelse {
            return true;
        };
        const timeSinceLastCall = time - lastCallTime;
        const timeSinceLastInvoke = time - self.lastInvokeTime;

        // Either this is the first call, activity has stopped and we're at the
        // trailing edge, the system time has gone backwards and we're treating
        // it as the trailing edge, or we've hit the `maxWait` limit.
        return timeSinceLastCall >= self.wait or timeSinceLastCall < 0 or (self.maxing and timeSinceLastInvoke >= self.maxWait);
    }

    //
    // The timer callback.
    //
    fn timerExpired(self: *Debounced, io: std.Io, timers: Timers) void {
        const time = now(io);
        if (self.shouldInvoke(time)) {
            self.trailingEdge(time);
            return;
        }
        // Restart the timer.
        self.setTimeout(io, timers, self.remainingWait(time));
    }

    //
    // The end of a wait.
    //
    fn trailingEdge(self: *Debounced, time: i64) void {
        self.timerId = null;

        // Only invoke if we have `lastArgs` which means `func` has been
        // debounced at least once.
        if (self.trailing and self.lastArgs) {
            self.invokeFunc(time);
            return;
        }
        self.lastArgs = false;
    }

    //
    // Cancels delayed invocations.
    //
    pub fn cancel(self: *Debounced, timers: Timers) void {
        if (self.timerId != null) {
            self.clearTimeout(timers);
        }
        self.lastInvokeTime = 0;
        self.lastArgs = false;
        self.lastCallTime = null;
        self.timerId = null;
    }

    //
    // Immediately invokes a delayed invocation.
    //
    pub fn flush(self: *Debounced, io: std.Io, timers: Timers) void {
        if (self.timerId) |id| {
            self.trailingEdge(now(io));
            // lodash leaves the timer set, to find nothing to invoke when it fires. Here the timer holds a pointer to the debounced
            // function, and trailingEdge has forgotten its id, so deinit could not clear it: it is cleared now.
            timers.clearTimeout(id);
        }
    }

    //
    // The debounced function.
    //
    pub fn call(self: *Debounced, io: std.Io, timers: Timers) void {
        const time = now(io);
        const isInvoking = self.shouldInvoke(time);

        self.lastArgs = true;
        self.lastCallTime = time;

        if (isInvoking) {
            if (self.timerId == null) {
                self.leadingEdge(io, timers, time);
                return;
            }
            if (self.maxing) {
                // Handle invocations in a tight loop.
                self.clearTimeout(timers);
                self.setTimeout(io, timers, self.wait);
                self.invokeFunc(time);
                return;
            }
        }
        if (self.timerId == null) {
            self.setTimeout(io, timers, self.wait);
        }
    }
};

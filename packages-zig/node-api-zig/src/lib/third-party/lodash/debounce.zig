//
// Port of lodash 4.17.21 debounce.js (MIT license, (c) OpenJS Foundation and other contributors).
//
// Creates a debounced function that delays invoking `func` until after `wait` milliseconds have elapsed since the
// last time the debounced function was invoked. The debounced function comes with a `cancel` method to cancel delayed
// `func` invocations and a `flush` method to immediately invoke them.
//
// The timers lodash starts with setTimeout fire on JavaScript's one thread, between whatever else that thread is
// doing. Zig has no such thread, so the caller hands in the lock that stands in for it: the code that calls the
// debounced function holds it while it runs, and a timer fires on a thread of the debounced function's own, holding
// the same lock, so `func` never runs at the same time as the caller's other code. The debounced function's methods
// must be called with the lock held.
//
// Only what throttle uses is ported: `func` takes no arguments and its result is not kept (the throttled function
// in Photosphere returns nothing), and `wait` and `maxWait` are whole milliseconds.
//

const std = @import("std");

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
    // Io for the clock, the lock and the timer.
    io: std.Io,

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

    // Whether a timer is set (TypeScript: timerId !== undefined).
    timerId: bool,

    // The lock that stands in for JavaScript's single thread (see the top of this file).
    loopLock: *std.Io.Mutex,

    // When the timer fires (milliseconds on the real clock, the clock Date.now reads).
    timerDeadline: i64,

    // Whether the timer is waiting to fire (a set timer that has fired is still `timerId` until trailingEdge clears it).
    timerArmed: bool,

    // Bumped whenever the timer is set, cleared or stopped, which is what wakes the timer thread.
    timerGeneration: std.atomic.Value(u32),

    // Set when the timer thread has to exit.
    stopping: bool,

    // The thread the timers fire on (TypeScript: the event loop's timers).
    timerThread: ?std.Thread,

    //
    // Creates a debounced function (TypeScript: `debounce(func, wait, options)`).
    // `start` has to be called once the debounced function is at its final address.
    //
    pub fn init(io: std.Io, func: DebouncedFunction, wait: i64, options: IDebounceOptions, loopLock: *std.Io.Mutex) Debounced {
        return .{
            .io = io,
            .func = func,
            .wait = wait,
            .maxWait = if (options.maxWait) |maxWait| @max(maxWait, wait) else 0,
            .maxing = options.maxWait != null,
            .leading = options.leading,
            .trailing = options.trailing,
            .lastArgs = false,
            .lastCallTime = null,
            .lastInvokeTime = 0,
            .timerId = false,
            .loopLock = loopLock,
            .timerDeadline = 0,
            .timerArmed = false,
            .timerGeneration = std.atomic.Value(u32).init(0),
            .stopping = false,
            .timerThread = null,
        };
    }

    //
    // Starts the thread the timers fire on. (No TypeScript counterpart: JavaScript's timers need no thread.)
    //
    pub fn start(self: *Debounced) !void {
        self.timerThread = try std.Thread.spawn(.{}, timerThreadMain, .{self});
    }

    //
    // Stops the timer thread and waits for it to exit. Must be called without the loop lock held.
    // (No TypeScript counterpart: a JavaScript function is garbage collected.)
    //
    pub fn deinit(self: *Debounced) void {
        self.loopLock.lockUncancelable(self.io);
        self.stopping = true;
        self.bumpTimerGeneration();
        self.loopLock.unlock(self.io);
        if (self.timerThread) |thread| {
            thread.join();
        }
        self.timerThread = null;
    }

    //
    // The current time (TypeScript: `now()`, which is Date.now).
    //
    fn now(self: *Debounced) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    //
    // Wakes the timer thread so it reads the timer again.
    //
    fn bumpTimerGeneration(self: *Debounced) void {
        _ = self.timerGeneration.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.timerGeneration.raw, 1);
    }

    //
    // setTimeout(timerExpired, delay): timerExpired runs on the timer thread once delay has passed.
    //
    fn setTimeout(self: *Debounced, delay: i64) void {
        self.timerId = true;
        self.timerDeadline = self.now() + delay;
        self.timerArmed = true;
        self.bumpTimerGeneration();
    }

    //
    // clearTimeout(timerId).
    //
    fn clearTimeout(self: *Debounced) void {
        self.timerArmed = false;
        self.bumpTimerGeneration();
    }

    //
    // The body of the timer thread: waits for the timer, then runs timerExpired holding the loop lock.
    //
    fn timerThreadMain(self: *Debounced) void {
        while (true) {
            self.loopLock.lockUncancelable(self.io);
            if (self.stopping) {
                self.loopLock.unlock(self.io);
                return;
            }
            const generation = self.timerGeneration.load(.acquire);
            var timeout: std.Io.Timeout = .none;
            if (self.timerArmed) {
                const remaining = self.timerDeadline - self.now();
                if (remaining <= 0) {
                    self.timerArmed = false;
                    self.timerExpired();
                    self.loopLock.unlock(self.io);
                    continue;
                }
                timeout = .{ .duration = .{
                    .raw = .fromMilliseconds(remaining),
                    .clock = .real,
                } };
            }
            self.loopLock.unlock(self.io);
            self.io.futexWaitTimeout(u32, &self.timerGeneration.raw, generation, timeout) catch {};
        }
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
    fn leadingEdge(self: *Debounced, time: i64) void {
        // Reset any `maxWait` timer.
        self.lastInvokeTime = time;
        // Start the timer for the trailing edge.
        self.setTimeout(self.wait);
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
    fn timerExpired(self: *Debounced) void {
        const time = self.now();
        if (self.shouldInvoke(time)) {
            self.trailingEdge(time);
            return;
        }
        // Restart the timer.
        self.setTimeout(self.remainingWait(time));
    }

    //
    // The end of a wait.
    //
    fn trailingEdge(self: *Debounced, time: i64) void {
        self.timerId = false;

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
    pub fn cancel(self: *Debounced) void {
        if (self.timerId) {
            self.clearTimeout();
        }
        self.lastInvokeTime = 0;
        self.lastArgs = false;
        self.lastCallTime = null;
        self.timerId = false;
    }

    //
    // Immediately invokes a delayed invocation.
    //
    pub fn flush(self: *Debounced) void {
        if (self.timerId) {
            self.trailingEdge(self.now());
        }
    }

    //
    // The debounced function.
    //
    pub fn call(self: *Debounced) void {
        const time = self.now();
        const isInvoking = self.shouldInvoke(time);

        self.lastArgs = true;
        self.lastCallTime = time;

        if (isInvoking) {
            if (!self.timerId) {
                self.leadingEdge(time);
                return;
            }
            if (self.maxing) {
                // Handle invocations in a tight loop.
                self.clearTimeout();
                self.setTimeout(self.wait);
                self.invokeFunc(time);
                return;
            }
        }
        if (!self.timerId) {
            self.setTimeout(self.wait);
        }
    }
};

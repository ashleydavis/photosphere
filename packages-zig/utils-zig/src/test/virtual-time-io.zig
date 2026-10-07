const std = @import("std");

//
// An Io whose monotonic clock moves when a test waits instead of when time passes, so that a test of a retry back-off, a lock
// wait or a timeout takes no real time. It is the Zig counterpart of the jest fake timers the TypeScript tests use. Every
// function of the Io that is not about the clock is the real one.
//
// What a wait does depends on its length:
//
// - A wait shorter than `long_wait_nanoseconds` (a back-off, a lock poll) ends at once, after the monotonic clock has been moved
//   forward by it. No real time passes.
// - A longer wait (the timeout of an operation, a file that is slow to read) really waits, for its length divided by `speed`.
//   A timer that races an operation (utils-zig retry runs the two side by side and the first to finish wins) would end at once
//   if it were short too, and so always beat the operation.
//
// `speed` is also how many times faster than the real one the monotonic clock runs. The wall clock moves with the monotonic one,
// for what is measured against it (a lock that goes stale).
//
// The real Io is a std.Io.Threaded, which every one of its functions reaches through the userdata pointer. This holds a Threaded
// and hands out that same pointer, so the functions that are not replaced work as they do, and the ones that are replaced find
// the clock through the field the pointer is in.
//
pub const VirtualTimeIo = struct {
    // How a clock behaves, as the presets below set it.
    pub const Options = struct {
        // How many times faster than the real one the monotonic clock runs, and so how much shorter than its length a long wait
        // really is. Zero for a clock that moves only when a test waits.
        speed: i64,

        // The length from which a wait really waits, in nanoseconds.
        long_wait_nanoseconds: i64,

        // Every wait ends at once, and the clock moves only by them.
        pub const virtual: Options = .{
            .speed = 0,
            .long_wait_nanoseconds = std.math.maxInt(i64),
        };

        // For the tests of code that retries, whose back-offs are shorter than ten seconds and whose timeouts are longer: the
        // clock runs as fast as the real one and waits of ten seconds or more are real, so a timer stays longer than any real
        // operation of a test.
        pub const backoff: Options = .{
            .speed = 1,
            .long_wait_nanoseconds = 10 * std.time.ns_per_s,
        };

        // For the tests of code that retries and waits a long time for a slow operation: the clock runs a hundred times faster
        // than the real one, and a wait of twenty seconds or more really waits for a hundredth of its length.
        pub const retry: Options = .{
            .speed = 100,
            .long_wait_nanoseconds = 20 * std.time.ns_per_s,
        };
    };

    // The real Io. Its address is the userdata of the Io handed out.
    threaded: std.Io.Threaded,

    // The vtable handed out: the real one, with the functions that read or wait on the clock replaced.
    vtable: std.Io.VTable,

    // How the clock behaves.
    options: Options,

    // The real monotonic time when the Io was started, in nanoseconds.
    start_nanoseconds: i64,

    // How far the waits have moved the monotonic clock, in nanoseconds.
    jumped_nanoseconds: std.atomic.Value(i64),

    //
    // Starts a clock at zero that every wait moves and no wait delays.
    //
    pub fn init(self: *VirtualTimeIo, allocator: std.mem.Allocator) void {
        self.initWith(allocator, Options.virtual);
    }

    //
    // Starts a clock at zero that behaves as the options say. The Io is not movable once started.
    //
    pub fn initWith(self: *VirtualTimeIo, allocator: std.mem.Allocator, options: Options) void {
        self.threaded = .init(allocator, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.now = virtualNow;
        self.vtable.sleep = virtualSleep;
        self.vtable.futexWait = virtualFutexWait;
        self.vtable.batchAwaitConcurrent = virtualBatchAwaitConcurrent;
        self.options = options;
        self.start_nanoseconds = @intCast(self.threaded.io().vtable.now(&self.threaded, .awake).nanoseconds);
        self.jumped_nanoseconds = .init(0);
    }

    //
    // Releases the real Io.
    //
    pub fn deinit(self: *VirtualTimeIo) void {
        self.threaded.deinit();
    }

    //
    // The Io with the virtual clock.
    //
    pub fn io(self: *VirtualTimeIo) std.Io {
        return .{
            .userdata = &self.threaded,
            .vtable = &self.vtable,
        };
    }
};

//
// What a timeout asks for.
//
const Wait = union(enum) {
    // The timeout is not a wait on the monotonic clock, or has no end: it is done as the real Io does it.
    real,

    // A short wait: the clock is moved forward by these nanoseconds and the wait ends.
    short: i64,

    // A long wait: it really waits, for this timeout.
    long: std.Io.Timeout,
};

//
// Finds the VirtualTimeIo whose Io a userdata pointer belongs to.
//
fn virtualTimeOf(userdata: ?*anyopaque) *VirtualTimeIo {
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
    return @alignCast(@fieldParentPtr("threaded", threaded));
}

//
// Works out what a timeout asks for.
//
fn waitOf(virtual_time: *VirtualTimeIo, timeout: std.Io.Timeout) Wait {
    var nanoseconds: i64 = undefined;
    switch (timeout) {
        .none => {
            return .real;
        },
        .duration => |duration| {
            if (duration.clock != .awake) {
                return .real;
            }
            nanoseconds = @intCast(duration.raw.nanoseconds);
        },
        .deadline => |deadline| {
            if (deadline.clock != .awake) {
                return .real;
            }
            const now: i64 = @intCast(virtualNow(&virtual_time.threaded, .awake).nanoseconds);
            nanoseconds = @max(0, @as(i64, @intCast(deadline.raw.nanoseconds)) - now);
        },
    }
    if (nanoseconds < virtual_time.options.long_wait_nanoseconds) {
        return .{
            .short = nanoseconds,
        };
    }
    return .{
        .long = .{
            .duration = .{
                .raw = .{
                    .nanoseconds = @divTrunc(nanoseconds, virtual_time.options.speed),
                },
                .clock = .awake,
            },
        },
    };
}

//
// The time on a clock. The monotonic clock is the virtual one, the wall clock is the real one plus the time the waits have
// moved the monotonic clock by, and the others are the real ones.
//
fn virtualNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const virtual_time = virtualTimeOf(userdata);
    const real = virtual_time.threaded.io().vtable.now(userdata, clock);
    const jumped = virtual_time.jumped_nanoseconds.load(.monotonic);
    switch (clock) {
        .awake => {
            const real_elapsed: i64 = @as(i64, @intCast(real.nanoseconds)) - virtual_time.start_nanoseconds;
            return .{
                .nanoseconds = real_elapsed * virtual_time.options.speed + jumped,
            };
        },
        .real => {
            return .{
                .nanoseconds = real.nanoseconds + jumped,
            };
        },
        else => {
            return real;
        },
    }
}

//
// Sleeps: a short sleep moves the clock, a long one really sleeps for its length divided by the speed.
//
fn virtualSleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const virtual_time = virtualTimeOf(userdata);
    switch (waitOf(virtual_time, timeout)) {
        .real => {
            return virtual_time.threaded.io().vtable.sleep(userdata, timeout);
        },
        .short => |nanoseconds| {
            _ = virtual_time.jumped_nanoseconds.fetchAdd(nanoseconds, .monotonic);
        },
        .long => |scaled| {
            return virtual_time.threaded.io().vtable.sleep(userdata, scaled);
        },
    }
}

//
// Waits on a futex like virtualSleep waits. A wait without a timeout is the real one.
//
fn virtualFutexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const virtual_time = virtualTimeOf(userdata);
    switch (waitOf(virtual_time, timeout)) {
        .real => {
            return virtual_time.threaded.io().vtable.futexWait(userdata, ptr, expected, timeout);
        },
        .short => |nanoseconds| {
            _ = virtual_time.jumped_nanoseconds.fetchAdd(nanoseconds, .monotonic);
        },
        .long => |scaled| {
            return virtual_time.threaded.io().vtable.futexWait(userdata, ptr, expected, scaled);
        },
    }
}

//
// Waits for a batch of operations like virtualSleep waits, and times out when the wait is short.
//
fn virtualBatchAwaitConcurrent(userdata: ?*anyopaque, batch: *std.Io.Batch, timeout: std.Io.Timeout) std.Io.Batch.AwaitConcurrentError!void {
    const virtual_time = virtualTimeOf(userdata);
    switch (waitOf(virtual_time, timeout)) {
        .real => {
            return virtual_time.threaded.io().vtable.batchAwaitConcurrent(userdata, batch, timeout);
        },
        .short => |nanoseconds| {
            _ = virtual_time.jumped_nanoseconds.fetchAdd(nanoseconds, .monotonic);
            return error.Timeout;
        },
        .long => |scaled| {
            return virtual_time.threaded.io().vtable.batchAwaitConcurrent(userdata, batch, scaled);
        },
    }
}

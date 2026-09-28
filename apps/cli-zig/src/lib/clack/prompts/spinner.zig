const std = @import("std");
const core = @import("../core/index.zig");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const sisteransi = @import("../third-party/sisteransi.zig");
const process_signals = @import("../../process-signals.zig");
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;
const S_STEP_CANCEL = common.S_STEP_CANCEL;
const S_STEP_ERROR = common.S_STEP_ERROR;
const S_STEP_SUBMIT = common.S_STEP_SUBMIT;
const settings = core.settings;
const block = core.block;
const IBlock = core.IBlock;

//
// How the spinner shows that it is still going.
//
pub const SpinnerIndicator = enum {
    // Dots after the message.
    dots,

    // The time elapsed after the message.
    timer,
};

//
// A function called when the spinner is cancelled, and the value it is called with.
//
pub const ICancelCallback = struct {
    // The value the function is called with.
    context: ?*anyopaque,

    // The function.
    function: *const fn (context: ?*anyopaque) void,
};

//
// Options of the spinner.
//
pub const SpinnerOptions = struct {
    // The streams of the spinner.
    common: CommonOptions = .{},

    // How the spinner shows that it is still going.
    indicator: SpinnerIndicator = .dots,

    // Called when the spinner is cancelled by a signal.
    onCancel: ?ICancelCallback = null,

    // The message shown when the spinner is cancelled (settings.messages.cancel when null).
    cancelMessage: ?[]const u8 = null,

    // The message shown when the spinner fails (settings.messages.error when null).
    errorMessage: ?[]const u8 = null,

    // The frames of the animation (◒ ◐ ◓ ◑, or • o O 0 without unicode, when null).
    frames: ?[]const []const u8 = null,

    // The time between frames in milliseconds (80, or 120 without unicode, when null).
    delay: ?u64 = null,
};

//
// A spinner (TypeScript: the SpinnerResult object `spinner()` returns, with its closure state as fields).
//
pub const Spinner = struct {
    // Allocates the spinner's strings.
    allocator: std.mem.Allocator,

    // The Io the animation sleeps and writes with.
    io: std.Io,

    // The options.
    opts: SpinnerOptions,

    // Where the spinner is drawn.
    output: *std.Io.Writer,

    // The frames of the animation.
    frames: []const []const u8,

    // The time between frames in milliseconds.
    delay: u64,

    // True when running in CI.
    isCI: bool,

    // Ends the block on the input taken by start (`unblock`), null when not blocked.
    unblocker: ?*IBlock,

    // The animation thread (the `setInterval` loop), null when not running.
    loop: ?std.Thread,

    // Set to stop the animation thread.
    loopStopped: std.atomic.Value(bool),

    // Makes stop run on one thread at a time (a signal stops the spinner on the signal thread).
    stopMutex: std.Io.Mutex,

    // Guards the drawing and the message, which the animation thread and the caller share.
    mutex: std.Io.Mutex,

    // True between start and stop.
    isSpinnerActive: bool,

    // True when a signal cancelled the spinner.
    isCancelledValue: bool,

    // The message shown.
    currentMessage: []const u8,

    // The message drawn last, or null when nothing has been drawn.
    prevMessage: ?[]const u8,

    // When the spinner started, in milliseconds.
    origin: i64,

    // The index of the next frame.
    frameIndex: usize,

    // Counts frames for the dots (increases by 1 every 8 frames).
    indicatorTimer: f64,

    //
    // Handles the end of the spinner by a signal (code 1) or an error (code 2).
    //
    fn handleExit(self: *Spinner, code: u8) void {
        const msg = if (code > 1) (self.opts.errorMessage orelse settings.messages.@"error") else (self.opts.cancelMessage orelse settings.messages.cancel);
        self.isCancelledValue = code == 1;
        if (self.isSpinnerActive) {
            self.stop(msg, code) catch |err| {
                std.debug.panic("Stopping the spinner failed: {s}", .{@errorName(err)});
            };
            if (self.isCancelledValue) {
                if (self.opts.onCancel) |onCancel| {
                    onCancel.function(onCancel.context);
                }
            }
        }
    }

    //
    // The signal listener (`signalEventHandler`).
    //
    fn signalEventHandler(context: *anyopaque) void {
        const self: *Spinner = @ptrCast(@alignCast(context));
        self.handleExit(1);
    }

    //
    // The listener registered for SIGINT and SIGTERM.
    //
    fn signalListener(self: *Spinner) process_signals.ISignalListener {
        return .{ .context = self, .function = signalEventHandler };
    }

    //
    // Registers the signal listeners. Not ported: the 'uncaughtExceptionMonitor', 'unhandledRejection' and 'exit'
    // listeners (Zig has no uncaught exceptions, rejections or exit event).
    //
    fn registerHooks(self: *Spinner) !void {
        try process_signals.on(.SIGINT, self.signalListener());
        try process_signals.on(.SIGTERM, self.signalListener());
    }

    //
    // Removes the signal listeners.
    //
    fn clearHooks(self: *Spinner) !void {
        try process_signals.removeListener(.SIGINT, self.signalListener());
        try process_signals.removeListener(.SIGTERM, self.signalListener());
    }

    //
    // Erases the message drawn last.
    //
    fn clearPrevMessage(self: *Spinner) !void {
        const prev = self.prevMessage orelse return;
        if (self.isCI) {
            try self.output.writeAll("\n");
        }
        const prevLines = std.mem.count(u8, prev, "\n") + 1;
        try sisteransi.cursor.move(self.output, -999, @intCast(prevLines - 1));
        try sisteransi.erase.down(self.output, prevLines);
    }

    //
    // The elapsed time since origin, as "[5s]" or "[1m 5s]".
    //
    fn formatTimer(self: *Spinner, origin: i64) ![]const u8 {
        const duration = @as(f64, @floatFromInt(std.Io.Clock.awake.now(self.io).toMilliseconds() - origin)) / 1000;
        const min: u64 = @intFromFloat(@floor(duration / 60));
        const secs: u64 = @intFromFloat(@floor(@mod(duration, 60)));
        if (min > 0) {
            return std.fmt.allocPrint(self.allocator, "[{d}m {d}s]", .{ min, secs });
        }
        return std.fmt.allocPrint(self.allocator, "[{d}s]", .{secs});
    }

    //
    // Draws the next frame (the body of the setInterval loop).
    //
    fn drawFrame(self: *Spinner) !void {
        if (self.isCI and self.prevMessage != null and std.mem.eql(u8, self.currentMessage, self.prevMessage.?)) {
            return;
        }
        try self.clearPrevMessage();
        self.prevMessage = self.currentMessage;
        const frame = try color.magenta(self.allocator, self.frames[self.frameIndex]);

        if (self.isCI) {
            try self.output.print("{s}  {s}...", .{ frame, self.currentMessage });
        }
        else if (self.opts.indicator == .timer) {
            try self.output.print("{s}  {s} {s}", .{ frame, self.currentMessage, try self.formatTimer(self.origin) });
        }
        else {
            const dotCount: usize = @min(@as(usize, @intFromFloat(@floor(self.indicatorTimer))), 3);
            try self.output.print("{s}  {s}{s}", .{ frame, self.currentMessage, "..."[0..dotCount] });
        }
        try self.output.flush();

        self.frameIndex = if (self.frameIndex + 1 < self.frames.len) self.frameIndex + 1 else 0;
        // indicator increase by 1 every 8 frames
        self.indicatorTimer = if (self.indicatorTimer < 4) self.indicatorTimer + 0.125 else 0;
    }

    //
    // The animation thread: draws a frame every `delay` milliseconds until stopped.
    //
    fn animate(self: *Spinner) void {
        while (true) {
            self.io.sleep(.fromMilliseconds(@intCast(self.delay)), .awake) catch {
                return;
            };
            if (self.loopStopped.load(.acquire)) {
                return;
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.loopStopped.load(.acquire)) {
                return;
            }
            self.drawFrame() catch |err| {
                std.debug.panic("Drawing the spinner failed: {s}", .{@errorName(err)});
            };
        }
    }

    //
    // Starts the spinner with a message.
    //
    pub fn start(self: *Spinner, msg: []const u8) !void {
        self.isSpinnerActive = true;
        self.unblocker = try block(self.io, .{ .output = self.output });
        self.currentMessage = removeTrailingDots(msg);
        self.origin = std.Io.Clock.awake.now(self.io).toMilliseconds();
        try self.output.print("{s}\n", .{try color.gray(self.allocator, S_BAR())});
        try self.output.flush();
        self.frameIndex = 0;
        self.indicatorTimer = 0;
        try self.registerHooks();
        self.loopStopped.store(false, .release);
        self.loop = try std.Thread.spawn(.{}, animate, .{self});
    }

    //
    // Stops the spinner, replacing it with a final message: a submit symbol for code 0, a cancel symbol for 1 and
    // an error symbol otherwise.
    //
    pub fn stop(self: *Spinner, msg: []const u8, code: u8) !void {
        // A signal can stop the spinner on the signal thread while the caller stops it too.
        self.stopMutex.lockUncancelable(self.io);
        defer self.stopMutex.unlock(self.io);
        self.isSpinnerActive = false;
        self.loopStopped.store(true, .release);
        if (self.loop) |thread| {
            thread.join();
            self.loop = null;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.clearPrevMessage();
        const step = switch (code) {
            0 => try color.green(self.allocator, S_STEP_SUBMIT()),
            1 => try color.red(self.allocator, S_STEP_CANCEL()),
            else => try color.red(self.allocator, S_STEP_ERROR()),
        };
        self.currentMessage = msg;
        if (self.opts.indicator == .timer) {
            try self.output.print("{s}  {s} {s}\n", .{ step, self.currentMessage, try self.formatTimer(self.origin) });
        }
        else {
            try self.output.print("{s}  {s}\n", .{ step, self.currentMessage });
        }
        try self.output.flush();
        try self.clearHooks();
        if (self.unblocker) |unblocker| {
            self.unblocker = null;
            try unblocker.unblock();
        }
    }

    //
    // Changes the message.
    //
    pub fn message(self: *Spinner, msg: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.currentMessage = removeTrailingDots(msg);
    }

    //
    // True when a signal cancelled the spinner.
    //
    pub fn isCancelled(self: *const Spinner) bool {
        return self.isCancelledValue;
    }
};

//
// Removes the dots at the end of a message (`msg.replace(/\.+$/, '')`).
//
fn removeTrailingDots(msg: []const u8) []const u8 {
    return std.mem.trimEnd(u8, msg, ".");
}

//
// Creates a spinner. The allocator must outlive it.
//
pub fn spinner(allocator: std.mem.Allocator, io: std.Io, opts: SpinnerOptions) !*Spinner {
    const unicode = common.isUnicodeSupported();
    const created = try allocator.create(Spinner);
    created.* = .{
        .allocator = allocator,
        .io = io,
        .opts = opts,
        .output = common.resolveOutput(io, opts.common),
        .frames = opts.frames orelse if (unicode) &.{ "\u{25D2}", "\u{25D0}", "\u{25D3}", "\u{25D1}" } else &.{ "\u{2022}", "o", "O", "0" },
        .delay = opts.delay orelse if (unicode) 80 else 120,
        .isCI = common.isCI(),
        .unblocker = null,
        .loop = null,
        .loopStopped = .init(true),
        .mutex = .init,
        .stopMutex = .init,
        .isSpinnerActive = false,
        .isCancelledValue = false,
        .currentMessage = "",
        .prevMessage = null,
        .origin = std.Io.Clock.awake.now(io).toMilliseconds(),
        .frameIndex = 0,
        .indicatorTimer = 0,
    };
    return created;
}

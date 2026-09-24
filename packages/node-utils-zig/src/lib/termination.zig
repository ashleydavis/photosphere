const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const exit_codes = @import("exit-codes.zig");
const EXIT_FAILURE = exit_codes.EXIT_FAILURE;
const EXIT_SUCCESS = exit_codes.EXIT_SUCCESS;
const EXIT_TERMINATION_CALLBACKS_THREW = exit_codes.EXIT_TERMINATION_CALLBACKS_THREW;
const EXIT_SIGTERM_CLEANUP_FAILED = exit_codes.EXIT_SIGTERM_CLEANUP_FAILED;
const EXIT_SIGINT_CLEANUP_FAILED = exit_codes.EXIT_SIGINT_CLEANUP_FAILED;

//
// Set to true after the termination handlers have been initialized.
//
var terminationCallbacksInitialized = false;

//
// The type of a callback to handle graceful termination of the process.
// The exit code is passed to indicate whether the process is exiting successfully (0) or with an error (non-zero).
// In Zig a callback is a function plus the context it closes over.
//
pub const TerminationCallback = struct {
    // The value the callback closes over (passed back to `function`).
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void,
};

//
// List of registered termination callbacks (a growable list like the JavaScript array, allocated
// from the process-wide allocator because registerTerminationCallback takes no allocator).
//
var terminationCallbacks: std.ArrayListUnmanaged(TerminationCallback) = .empty;

//
// Invokes all registered termination callbacks with the given exit code.
//
pub fn invokeTerminationCallbacks(io: std.Io, exitCode: u8) !void {
    for (terminationCallbacks.items) |callback| {
        try callback.function(callback.context, io, exitCode);
    }
}

//
// Trigger program termination with a specific exit code.
// Invokes the termination callbacks registered with `registerTerminationCallback`.
//
pub fn exit(io: std.Io, code: u8) noreturn {
    invokeTerminationCallbacks(io, code) catch |err| {
        utils.log.log.exception("Error during exit termination callbacks.", err);
        std.process.exit(EXIT_TERMINATION_CALLBACKS_THREW);
    };

    std.process.exit(code);
}

//
// Register a callback function to be called when the process is about to exit.
// `io` is used to run the callbacks when the process receives SIGTERM or SIGINT.
//
pub fn registerTerminationCallback(io: std.Io, callback: TerminationCallback) !void {
    try initializeTerminationHandlers(io);
    try terminationCallbacks.append(std.heap.smp_allocator, callback);
}

//
// Removes all registered termination callbacks (used by tests).
//
pub fn clearTerminationCallbacks() void {
    terminationCallbacks.clearRetainingCapacity();
}

//
// The signal received (SIGTERM or SIGINT) that has not been handled yet, or 0 for none.
// Set by the signal handler and read by the signal watcher thread.
//
var pendingSignal: std.atomic.Value(u32) = .init(0);

//
// The Io instance used to run termination callbacks on a signal.
//
var signalIo: std.Io = undefined;

//
// The signal handler: only records the signal, because termination callbacks cannot run safely
// inside a signal handler. The signal watcher thread runs them.
//
fn handleSignal(signal: std.posix.SIG) callconv(.c) void {
    pendingSignal.store(@intCast(@intFromEnum(signal)), .release);
}

//
// Handles a termination signal like the TypeScript `process.on('SIGTERM' | 'SIGINT')` handlers.
//
fn shutdownOnSignal(io: std.Io, signalName: []const u8, cleanupFailedCode: u8) noreturn {
    utils.log.log.verbose(if (std.mem.eql(u8, signalName, "SIGTERM")) "SIGTERM received. Shutting down gracefully..." else "SIGINT received. Shutting down...");

    invokeTerminationCallbacks(io, EXIT_SUCCESS) catch |err| {
        utils.log.log.exception(if (std.mem.eql(u8, signalName, "SIGTERM")) "Error during SIGTERM shutdown." else "Error during SIGINT shutdown.", err);
        invokeTerminationCallbacks(io, EXIT_FAILURE) catch {};
        std.process.exit(cleanupFailedCode);
    };
    std.process.exit(EXIT_SUCCESS);
}

//
// Waits for a termination signal recorded by handleSignal and shuts the process down.
//
fn watchSignals() void {
    while (true) {
        const signal = pendingSignal.load(.acquire);
        if (signal == @intFromEnum(std.posix.SIG.TERM)) {
            shutdownOnSignal(signalIo, "SIGTERM", EXIT_SIGTERM_CLEANUP_FAILED);
        }
        if (signal == @intFromEnum(std.posix.SIG.INT)) {
            shutdownOnSignal(signalIo, "SIGINT", EXIT_SIGINT_CLEANUP_FAILED);
        }
        std.Options.debug_io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
}

//
// Initializes the termination handlers for the process.
// Not ported: the 'uncaughtException', 'unhandledRejection', 'beforeExit' and 'exit' handlers
// (Zig has no uncaught exceptions or rejections; errors are returned to `main`, which handles them).
//
fn initializeTerminationHandlers(io: std.Io) !void {
    if (terminationCallbacksInitialized) {
        // Already initialized, no need to do it again.
        return;
    }

    if (builtin.os.tag != .windows) {
        signalIo = io;

        //
        // Listen for the SIGTERM signal (graceful shutdown request) and the SIGINT signal (Ctrl+C)
        //
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &action, null);
        std.posix.sigaction(.INT, &action, null);

        const watcher = try std.Thread.spawn(.{}, watchSignals, .{});
        watcher.detach();
    }

    terminationCallbacksInitialized = true;
}

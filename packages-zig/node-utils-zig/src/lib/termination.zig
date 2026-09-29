const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const exit_codes = @import("exit-codes.zig");
const EXIT_FAILURE = exit_codes.EXIT_FAILURE;
const EXIT_SUCCESS = exit_codes.EXIT_SUCCESS;
const EXIT_TERMINATION_CALLBACKS_THREW = exit_codes.EXIT_TERMINATION_CALLBACKS_THREW;
const EXIT_SIGTERM_CLEANUP_FAILED = exit_codes.EXIT_SIGTERM_CLEANUP_FAILED;
const EXIT_SIGINT_CLEANUP_FAILED = exit_codes.EXIT_SIGINT_CLEANUP_FAILED;
const EXIT_UNCAUGHT_EXCEPTION = exit_codes.EXIT_UNCAUGHT_EXCEPTION;
const EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED = exit_codes.EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED;
const EXIT_UNHANDLED_REJECTION = exit_codes.EXIT_UNHANDLED_REJECTION;
const EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED = exit_codes.EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED;

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
// Ends the process with the exit code like `process.exit(code)`, which emits the 'exit' event: once the termination
// handlers are initialized, the 'exit' handler logs the exit code.
// (No TypeScript counterpart: process.exit and the 'exit' handler of initializeTerminationHandlers.)
//
fn exitProcess(code: u8) noreturn {
    if (terminationCallbacksInitialized) {
        var buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Process exiting with code: {d}", .{code}) catch |err| {
            std.debug.panic("Formatting the exit message failed: {s}", .{@errorName(err)});
        };
        utils.log.log.verbose(message);
    }
    std.process.exit(code);
}

//
// Trigger program termination with a specific exit code.
// Invokes the termination callbacks registered with `registerTerminationCallback`.
//
pub fn exit(io: std.Io, code: u8) noreturn {
    invokeTerminationCallbacks(io, code) catch |err| {
        utils.log.log.exception("Error during exit termination callbacks.", err);
        exitProcess(EXIT_TERMINATION_CALLBACKS_THREW);
    };

    exitProcess(code);
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
// POSIX: the pipe that wakes the signal watcher thread (the "self-pipe": write() is async-signal-safe, so the
// signal handler writes a byte to it and the watcher blocks in poll() until it can read it). Index 0 is the read
// end, 1 the write end.
//
var signalPipe: [2]std.posix.fd_t = undefined;

//
// Windows: set by the console control handler to wake the signal watcher thread (the handler runs on a thread
// of its own, created by the system, where ordinary synchronization can be used).
//
var signalEvent: std.Io.Event = .unset;

//
// The signal handler: only records the signal and wakes the watcher, because termination callbacks cannot
// run safely inside a signal handler. The signal watcher thread runs them.
//
fn handleSignal(signal: std.posix.SIG) callconv(.c) void {
    pendingSignal.store(@intCast(@intFromEnum(signal)), .release);

    // The write end is non-blocking: when the pipe is full the watcher already has a wake-up waiting,
    // and nothing else can go wrong writing to a pipe whose read end this process keeps open.
    const wakeByte = [1]u8{0};
    _ = std.posix.system.write(signalPipe[1], &wakeByte, wakeByte.len);
}

//
// The Windows console control event sent by Ctrl+C (CTRL_C_EVENT).
//
const ctrl_c_event: std.os.windows.DWORD = 0;

//
// Registers a Windows console control handler (kernel32).
//
extern "kernel32" fn SetConsoleCtrlHandler(handlerRoutine: ?*const fn (ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

//
// The Windows console control handler: like Node on Windows, Ctrl+C is delivered as SIGINT (recorded for the
// signal watcher thread). Other events are not handled, so they terminate the process as usual.
//
fn handleConsoleCtrl(ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    if (ctrlType == ctrl_c_event) {
        pendingSignal.store(@intFromEnum(std.posix.SIG.INT), .release);
        signalEvent.set(signalIo);
        return .TRUE;
    }
    return .FALSE;
}

//
// Handles a termination signal like the TypeScript `process.on('SIGTERM' | 'SIGINT')` handlers.
//
fn shutdownOnSignal(io: std.Io, signalName: []const u8, cleanupFailedCode: u8) noreturn {
    utils.log.log.verbose(if (std.mem.eql(u8, signalName, "SIGTERM")) "SIGTERM received. Shutting down gracefully..." else "SIGINT received. Shutting down...");

    invokeTerminationCallbacks(io, EXIT_SUCCESS) catch |err| {
        utils.log.log.exception(if (std.mem.eql(u8, signalName, "SIGTERM")) "Error during SIGTERM shutdown." else "Error during SIGINT shutdown.", err);
        invokeTerminationCallbacks(io, EXIT_FAILURE) catch |cleanupErr| {
            shutdownOnUnhandledRejection(io, cleanupErr);
        };
        exitProcess(cleanupFailedCode);
    };
    exitProcess(EXIT_SUCCESS);
}

//
// Ends the process for an error that nothing catches (TypeScript: an uncaught exception, which Zig does not have, so
// the code that throws one calls this). Once the termination handlers are initialized it is the
// `process.on('uncaughtException')` handler: the error is logged, the termination callbacks run and the process exits
// with EXIT_UNCAUGHT_EXCEPTION (EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED when they throw). Before that it is Bun's own
// handling, which prints the error to stderr and exits with 1.
//
pub fn shutdownOnUncaughtException(io: std.Io, err: anyerror) noreturn {
    if (!terminationCallbacksInitialized) {
        var buffer: [16 * 1024]u8 = undefined;
        var fixedWriter = std.Io.Writer.fixed(&buffer);
        utils.wrapped_error.writeErrorChain(&fixedWriter, err) catch {};
        utils.console.@"error"(fixedWriter.buffered());
        std.process.exit(1);
    }

    utils.log.log.exception("Uncaught exception.", err);

    var exitCode = EXIT_UNCAUGHT_EXCEPTION;
    invokeTerminationCallbacks(io, EXIT_UNCAUGHT_EXCEPTION) catch |cleanupErr| {
        utils.log.log.exception("Error during uncaught exception shutdown.", cleanupErr);
        exitCode = EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED;
    };
    exitProcess(exitCode);
}

//
// Handles an error thrown out of a signal handler. In TypeScript the async signal handler's promise
// rejects, which the `process.on('unhandledRejection')` handler turns into this shutdown.
//
fn shutdownOnUnhandledRejection(io: std.Io, err: anyerror) noreturn {
    // `new Error(reason)`: the reason is the error the signal handler threw, and String() of it is
    // "<name>: <message>". The message is copied out first since recording the new error overwrites it.
    var reasonBuffer: [4096]u8 = undefined;
    const reasonName = if (err == error.Thrown or err == error.FatalError) utils.errors.lastErrorName() else "Error";
    const reason = std.fmt.bufPrint(&reasonBuffer, "{s}: {s}", .{ reasonName, utils.errors.errorMessage(err) }) catch reasonBuffer[0..];
    utils.errors.recordError("Error", "{s}", .{reason});
    utils.log.log.exception("Unhandled promise rejection.", error.Thrown);

    var exitCode = EXIT_UNHANDLED_REJECTION;
    invokeTerminationCallbacks(io, EXIT_UNHANDLED_REJECTION) catch |cleanupErr| {
        utils.log.log.exception("Error during unhandled rejection shutdown.", cleanupErr);
        exitCode = EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED;
    };
    exitProcess(exitCode);
}

//
// Blocks until the signal handler (or the Windows console control handler) wakes the watcher.
//
fn waitForSignal() !void {
    if (builtin.os.tag == .windows) {
        signalEvent.waitUncancelable(signalIo);
        signalEvent.reset();
        return;
    }
    var pollFds = [1]std.posix.pollfd{.{ .fd = signalPipe[0], .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&pollFds, -1);
    var wakeBytes: [16]u8 = undefined;
    const bytesRead = std.posix.read(signalPipe[0], &wakeBytes) catch |err| switch (err) {
        // Another wake-up was already consumed: poll again.
        error.WouldBlock => return,
        else => return err,
    };
    if (bytesRead == 0) {
        return error.EndOfStream;
    }
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
        waitForSignal() catch |err| {
            std.debug.panic("Waiting for a termination signal failed: {s}", .{@errorName(err)});
        };
    }
}

//
// Initializes the termination handlers for the process.
// The 'uncaughtException' handler is shutdownOnUncaughtException, which the code that throws an error nothing catches
// calls, and the 'unhandledRejection' handler is shutdownOnUnhandledRejection, which a signal handler that throws
// reaches. Not ported: the 'beforeExit' handler, which only logs (the commands always end in exit). The 'exit'
// handler's log line is written by exitProcess.
//
fn initializeTerminationHandlers(io: std.Io) !void {
    if (terminationCallbacksInitialized) {
        // Already initialized, no need to do it again.
        return;
    }

    signalIo = io;

    if (builtin.os.tag == .windows) {
        //
        // Listen for Ctrl+C (Node emits it as SIGINT on Windows; SIGTERM is never received on Windows)
        //
        if (SetConsoleCtrlHandler(handleConsoleCtrl, .TRUE) == .FALSE) {
            return std.os.windows.unexpectedError(std.os.windows.GetLastError());
        }
    }
    else {
        // Both ends are non-blocking (the signal handler must never block); the watcher blocks in poll().
        signalPipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });

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
    }

    const watcher = try std.Thread.spawn(.{}, watchSignals, .{});
    watcher.detach();

    terminationCallbacksInitialized = true;
}

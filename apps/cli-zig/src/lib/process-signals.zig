const std = @import("std");
const builtin = @import("builtin");

//
// This file has no TypeScript counterpart: it stands in for Node's `process.on('SIGINT' | 'SIGTERM', listener)` and
// `process.removeListener(...)`, which secrets.ts and the clack spinner use to be told of Ctrl+C. As in Node, while a
// listener is registered for a signal the signal no longer ends the process: the listeners are called instead, and
// once the last one is removed the signal's default action (ending the process) is back.
//
// The listeners are called on a thread of this module's own, never inside the signal handler, so they may do
// anything a normal function may. On Windows Ctrl+C arrives as SIGINT (like Node); SIGTERM is never received there.
//

//
// The signals a listener can be registered for.
//
pub const Signal = enum {
    // Ctrl+C.
    SIGINT,

    // A request to terminate.
    SIGTERM,
};

//
// A listener: a function and the value it is called with.
//
pub const ISignalListener = struct {
    // The value the function is called with.
    context: *anyopaque,

    // The function called when the signal arrives.
    function: *const fn (context: *anyopaque) void,
};

//
// A registered listener and the signal it is for.
//
const IRegistration = struct {
    // The signal.
    signal: Signal,

    // The listener.
    listener: ISignalListener,
};

//
// The most listeners that can be registered at once.
//
const max_listeners = 16;

//
// The registered listeners, in the order they were added (guarded by listenersLock).
//
var registrations: [max_listeners]IRegistration = undefined;

//
// The number of registered listeners.
//
var registrationCount: usize = 0;

//
// Guards the registered listeners (a spin lock: the signal watcher and the caller's thread share them).
//
var listenersLock = std.atomic.Value(bool).init(false);

//
// The signals received and not yet handed to the listeners, as bits (1 << @intFromEnum(Signal)).
//
var pendingSignals = std.atomic.Value(u8).init(0);

//
// Set once the signal watcher thread has been started.
//
var watcherStarted = false;

//
// POSIX: the pipe the signal handler writes a byte to, to wake the watcher (write() is async-signal-safe). Index 0
// is the read end, 1 the write end.
//
var wakePipe: [2]std.posix.fd_t = undefined;

//
// Windows: registers a console control handler (kernel32).
//
extern "kernel32" fn SetConsoleCtrlHandler(handlerRoutine: ?*const fn (ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

//
// Takes the lock on the registered listeners.
//
fn lock() void {
    while (listenersLock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
}

//
// Releases the lock on the registered listeners.
//
fn unlock() void {
    listenersLock.store(false, .release);
}

//
// The POSIX signal number of a signal.
//
fn posixSignal(signal: Signal) std.posix.SIG {
    return switch (signal) {
        .SIGINT => .INT,
        .SIGTERM => .TERM,
    };
}

//
// Counts the listeners registered for a signal (the caller holds the lock).
//
fn countListeners(signal: Signal) usize {
    var count: usize = 0;
    for (registrations[0..registrationCount]) |registration| {
        if (registration.signal == signal) {
            count += 1;
        }
    }
    return count;
}

//
// The POSIX signal handler: records the signal and wakes the watcher.
//
fn handlePosixSignal(signalNumber: std.posix.SIG) callconv(.c) void {
    const signal: Signal = if (signalNumber == .INT) .SIGINT else .SIGTERM;
    _ = pendingSignals.fetchOr(@as(u8, 1) << @intFromEnum(signal), .acq_rel);
    const wakeByte = [1]u8{0};
    _ = std.posix.system.write(wakePipe[1], &wakeByte, wakeByte.len);
}

//
// The Windows console control handler: Ctrl+C is SIGINT. It runs on a thread the system creates, so it calls the
// listeners itself. Other events, and Ctrl+C with no listener, are left to the default handler.
//
fn handleConsoleControl(controlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    const ctrl_c_event: std.os.windows.DWORD = 0;
    if (controlType != ctrl_c_event) {
        return .FALSE;
    }
    lock();
    const hasListener = countListeners(.SIGINT) > 0;
    unlock();
    if (!hasListener) {
        return .FALSE;
    }
    callListeners(.SIGINT);
    return .TRUE;
}

//
// Calls the listeners of a signal (on a copy of the list, so a listener may remove itself).
//
fn callListeners(signal: Signal) void {
    var listeners: [max_listeners]ISignalListener = undefined;
    var count: usize = 0;
    lock();
    for (registrations[0..registrationCount]) |registration| {
        if (registration.signal == signal) {
            listeners[count] = registration.listener;
            count += 1;
        }
    }
    unlock();
    for (listeners[0..count]) |listener| {
        listener.function(listener.context);
    }
}

//
// The POSIX signal watcher thread: waits for the signal handler to wake it, then calls the listeners.
//
fn watchSignals() void {
    while (true) {
        var pollFds = [1]std.posix.pollfd{.{ .fd = wakePipe[0], .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pollFds, -1) catch |err| {
            std.debug.panic("Waiting for a signal failed: {s}", .{@errorName(err)});
        };
        var wakeBytes: [16]u8 = undefined;
        _ = std.posix.read(wakePipe[0], &wakeBytes) catch |err| switch (err) {
            error.WouldBlock => {},
            else => std.debug.panic("Reading the signal pipe failed: {s}", .{@errorName(err)}),
        };
        const pending = pendingSignals.swap(0, .acq_rel);
        if (pending & (@as(u8, 1) << @intFromEnum(Signal.SIGINT)) != 0) {
            callListeners(.SIGINT);
        }
        if (pending & (@as(u8, 1) << @intFromEnum(Signal.SIGTERM)) != 0) {
            callListeners(.SIGTERM);
        }
    }
}

//
// Starts the POSIX signal watcher once.
//
fn startWatcher() !void {
    if (watcherStarted) {
        return;
    }
    wakePipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    const watcher = try std.Thread.spawn(.{}, watchSignals, .{});
    watcher.detach();
    watcherStarted = true;
}

//
// Installs this module's handler for a signal (the first listener) or puts back the default action (the last
// listener removed).
//
fn setHandler(signal: Signal, handled: bool) !void {
    if (builtin.os.tag == .windows) {
        if (signal != .SIGINT) {
            return;
        }
        if (SetConsoleCtrlHandler(handleConsoleControl, if (handled) .TRUE else .FALSE) == .FALSE) {
            return std.os.windows.unexpectedError(std.os.windows.GetLastError());
        }
        return;
    }
    try startWatcher();
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = if (handled) handlePosixSignal else std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(posixSignal(signal), &action, null);
}

//
// Adds a listener for a signal (`process.on(signal, listener)`).
//
pub fn on(signal: Signal, listener: ISignalListener) !void {
    lock();
    if (registrationCount == max_listeners) {
        unlock();
        return error.TooManySignalListeners;
    }
    const isFirst = countListeners(signal) == 0;
    registrations[registrationCount] = .{ .signal = signal, .listener = listener };
    registrationCount += 1;
    unlock();
    if (isFirst) {
        try setHandler(signal, true);
    }
}

//
// Removes a listener added with `on` (`process.removeListener(signal, listener)`); does nothing when it is not
// registered.
//
pub fn removeListener(signal: Signal, listener: ISignalListener) !void {
    lock();
    var index: usize = 0;
    var removed = false;
    while (index < registrationCount) {
        const registration = registrations[index];
        if (registration.signal == signal and registration.listener.context == listener.context and registration.listener.function == listener.function) {
            std.mem.copyForwards(IRegistration, registrations[index .. registrationCount - 1], registrations[index + 1 .. registrationCount]);
            registrationCount -= 1;
            removed = true;
            break;
        }
        index += 1;
    }
    const isLast = removed and countListeners(signal) == 0;
    unlock();
    if (isLast) {
        try setHandler(signal, false);
    }
}

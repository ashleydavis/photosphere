const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");

const process_signals = cli.process_signals;

//
// Counts the calls of a listener.
//
fn countCall(context: *anyopaque) void {
    const calls: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));
    _ = calls.fetchAdd(1, .acq_rel);
}

test "a SIGINT raised while a listener is registered calls the listener instead of ending the process" {
    // On Windows Ctrl+C can only be generated for the whole console, which would also stop the build runner that
    // started this test, so only the registration is exercised there.
    var calls = std.atomic.Value(u32).init(0);
    const listener: process_signals.ISignalListener = .{ .context = &calls, .function = countCall };
    try process_signals.on(.SIGINT, listener);
    if (builtin.os.tag != .windows) {
        try std.posix.raise(.INT);
        var waited: u32 = 0;
        while (calls.load(.acquire) == 0 and waited < 5000) {
            try std.testing.io.sleep(.fromMilliseconds(5), .awake);
            waited += 5;
        }
        try std.testing.expectEqual(@as(u32, 1), calls.load(.acquire));
    }
    try process_signals.removeListener(.SIGINT, listener);
}

test "every listener of a signal is called, and a removed one is not" {
    var first = std.atomic.Value(u32).init(0);
    var second = std.atomic.Value(u32).init(0);
    const firstListener: process_signals.ISignalListener = .{ .context = &first, .function = countCall };
    const secondListener: process_signals.ISignalListener = .{ .context = &second, .function = countCall };
    try process_signals.on(.SIGTERM, firstListener);
    try process_signals.on(.SIGTERM, secondListener);
    try process_signals.removeListener(.SIGTERM, firstListener);
    if (builtin.os.tag != .windows) {
        try std.posix.raise(.TERM);
        var waited: u32 = 0;
        while (second.load(.acquire) == 0 and waited < 5000) {
            try std.testing.io.sleep(.fromMilliseconds(5), .awake);
            waited += 5;
        }
        try std.testing.expectEqual(@as(u32, 1), second.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), first.load(.acquire));
    }
    try process_signals.removeListener(.SIGTERM, secondListener);
}

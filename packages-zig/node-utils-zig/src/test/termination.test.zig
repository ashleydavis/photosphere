const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const termination = node_utils.termination;

//
// Records the calls made to a termination callback.
//
const CallbackRecorder = struct {
    // Exit codes passed to the callback, in call order.
    exitCodes: [8]u8 = undefined,

    // Number of calls.
    calls: usize = 0,

    // When true the callback throws.
    fails: bool = false,

    //
    // The termination callback.
    //
    fn callback(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
        _ = io;
        const self: *CallbackRecorder = @ptrCast(@alignCast(context.?));
        self.exitCodes[self.calls] = exitCode;
        self.calls += 1;
        if (self.fails) {
            return utils.errors.throwError("Callback failed", .{});
        }
    }

    //
    // Gets the TerminationCallback for this recorder.
    //
    fn terminationCallback(self: *CallbackRecorder) termination.TerminationCallback {
        return .{ .context = self, .function = callback };
    }
};

test "invokeTerminationCallbacks calls every registered callback in order with the exit code" {
    const io = std.testing.io;
    termination.clearTerminationCallbacks();
    defer termination.clearTerminationCallbacks();
    var first: CallbackRecorder = .{};
    var second: CallbackRecorder = .{};
    try termination.registerTerminationCallback(io, first.terminationCallback());
    try termination.registerTerminationCallback(io, second.terminationCallback());

    try termination.invokeTerminationCallbacks(io, 3);

    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(u8, 3), first.exitCodes[0]);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqual(@as(u8, 3), second.exitCodes[0]);
}

test "invokeTerminationCallbacks stops at a callback that throws" {
    const io = std.testing.io;
    termination.clearTerminationCallbacks();
    defer termination.clearTerminationCallbacks();
    var failing: CallbackRecorder = .{ .fails = true };
    var after: CallbackRecorder = .{};
    try termination.registerTerminationCallback(io, failing.terminationCallback());
    try termination.registerTerminationCallback(io, after.terminationCallback());

    try std.testing.expectError(error.Thrown, termination.invokeTerminationCallbacks(io, 0));
    try std.testing.expectEqual(@as(usize, 0), after.calls);
}

test "exit terminates the process (compiled, not run: it would end the test process)" {
    const exit_pointer: *const fn (std.Io, u8) noreturn = &termination.exit;
    try std.testing.expect(@intFromPtr(exit_pointer) != 0);
}

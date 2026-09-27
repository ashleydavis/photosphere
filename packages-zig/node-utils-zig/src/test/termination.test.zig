const std = @import("std");
const builtin = @import("builtin");
const test_options = @import("test-options");
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

//
// What a terminated child process wrote and how it exited.
//
const ChildOutcome = struct {
    // The exit code of the child.
    exitCode: u8,

    // Everything the child wrote to stdout after "ready".
    output: []const u8,
};

//
// Starts the termination child with the callback mode, waits for it to be ready, sends it the signal and
// waits for it to exit.
//
fn terminateChild(allocator: std.mem.Allocator, callbackMode: []const u8, signal: std.posix.SIG) !ChildOutcome {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ test_options.termination_child_path, callbackMode },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const ready = try reader.interface.takeDelimiterExclusive('\n');
    try std.testing.expectEqualStrings("ready", ready);
    reader.interface.toss(1);
    try std.posix.kill(child.id.?, signal);
    const output = try reader.interface.allocRemaining(allocator, .unlimited);
    const term = try child.wait(io);
    const exitCode: u8 = switch (term) {
        .exited => |code| code,
        else => return error.ChildDidNotExit,
    };
    return .{ .exitCode = exitCode, .output = output };
}

test "SIGTERM runs the termination callbacks and exits with EXIT_SUCCESS" {
    if (builtin.os.tag == .windows) {
        // Windows has no signals: Ctrl+C reaches a console process through its console control handler.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try terminateChild(arena.allocator(), "succeed", .TERM);

    try std.testing.expectEqualStrings("callback 0\n", outcome.output);
    try std.testing.expectEqual(node_utils.exit_codes.EXIT_SUCCESS, outcome.exitCode);
}

test "SIGINT whose callbacks throw runs them again with EXIT_FAILURE and exits with EXIT_SIGINT_CLEANUP_FAILED" {
    if (builtin.os.tag == .windows) {
        // Windows has no signals: Ctrl+C reaches a console process through its console control handler.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try terminateChild(arena.allocator(), "fail-once", .INT);

    try std.testing.expectEqualStrings("callback 0\ncallback 1\n", outcome.output);
    try std.testing.expectEqual(node_utils.exit_codes.EXIT_SIGINT_CLEANUP_FAILED, outcome.exitCode);
}

test "callbacks that throw again during a signal shutdown end it like an unhandled rejection" {
    if (builtin.os.tag == .windows) {
        // Windows has no signals: Ctrl+C reaches a console process through its console control handler.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try terminateChild(arena.allocator(), "fail-always", .TERM);

    try std.testing.expectEqualStrings("callback 0\ncallback 1\ncallback 65\n", outcome.output);
    try std.testing.expectEqual(node_utils.exit_codes.EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED, outcome.exitCode);
}

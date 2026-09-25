//
// Delegation of the commands that are not ported to the TypeScript CLI (this file has no TypeScript
// counterpart). The Zig `psi` binary implements `replicate` and `verify`; for every other command line it
// runs `bun <apps/cli/index.ts> <args...>` with the same working directory, environment and stdio, and
// exits with the child's exit code (128 + the signal number when the child is killed by a signal).
//

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

//
// The absolute path of the TypeScript CLI entry point (apps/cli/index.ts), baked in at build time.
//
pub const ts_cli_path: []const u8 = build_options.ts_cli_path;

//
// The program that runs the TypeScript CLI.
//
pub const runtime = "bun";

//
// Builds the command line of the TypeScript CLI: `bun <index.ts> <user arguments...>`.
//
pub fn buildDelegateArgv(allocator: std.mem.Allocator, tsCliPath: []const u8, userArgs: []const []const u8) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, userArgs.len + 2);
    argv[0] = runtime;
    argv[1] = tsCliPath;
    for (userArgs, 0..) |argument, index| {
        argv[index + 2] = argument;
    }
    return argv;
}

//
// Converts how a child process ended to the exit code of this process.
//
pub fn exitCodeForTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @as(u32, @intFromEnum(signal))),
        .stopped => |signal| @truncate(128 + @as(u32, @intFromEnum(signal))),
        .unknown => 1,
    };
}

//
// The process ID of the running child, for forwarding SIGTERM (0 when there is none).
//
var child_pid: std.atomic.Value(i32) = .init(0);

//
// Forwards SIGTERM to the child. Ctrl+C already reaches the child through the terminal's process group.
//
fn forwardSignal(signal: std.posix.SIG) callconv(.c) void {
    const pid = child_pid.load(.acquire);
    if (pid > 0) {
        std.posix.kill(pid, signal) catch {};
    }
}

//
// The Windows console control event sent by Ctrl+C (CTRL_C_EVENT).
//
const ctrl_c_event: std.os.windows.DWORD = 0;

//
// The Windows console control event sent by Ctrl+Break (CTRL_BREAK_EVENT).
//
const ctrl_break_event: std.os.windows.DWORD = 1;

//
// Registers or removes a Windows console control handler (kernel32).
//
extern "kernel32" fn SetConsoleCtrlHandler(handlerRoutine: ?*const fn (ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

//
// Windows console control handler: Ctrl+C and Ctrl+Break reach the child too (it shares the console), so this
// process ignores them and waits for the child. Other events (closing the console, logoff, shutdown) are not
// handled, so they terminate this process as usual.
//
fn ignoreConsoleInterrupt(ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    if (ctrlType == ctrl_c_event or ctrlType == ctrl_break_event) {
        return .TRUE;
    }
    return .FALSE;
}

//
// Makes this process wait for the child when the user presses Ctrl+C (the child handles it) and forwards
// SIGTERM to the child, so the exit code is always the child's.
// On Windows there is no SIGTERM; Ctrl+C and Ctrl+Break are ignored with a console control handler (a handler,
// unlike ignoring them outright, is not inherited by the child).
//
fn installSignalForwarding() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(ignoreConsoleInterrupt, .TRUE);
        return;
    }
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &ignore, null);
    const forward: std.posix.Sigaction = .{
        .handler = .{ .handler = forwardSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &forward, null);
}

//
// Runs the TypeScript CLI with the user arguments and returns the exit code this process must exit with.
//
pub fn delegateToTypeScript(allocator: std.mem.Allocator, io: std.Io, userArgs: []const []const u8) !u8 {
    const argv = try buildDelegateArgv(allocator, ts_cli_path, userArgs);
    installSignalForwarding();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    if (builtin.os.tag != .windows) {
        if (child.id) |pid| {
            child_pid.store(pid, .release);
        }
    }
    const term = try child.wait(io);
    child_pid.store(0, .release);
    return exitCodeForTerm(term);
}

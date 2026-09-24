const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const errors = utils.errors;
const process_env = @import("process-env.zig");

//
// The output of a command run with exec (TypeScript: `{ stdout: string; stderr: string }`).
//
pub const ExecResult = struct {
    // Everything the command wrote to stdout.
    stdout: []const u8,

    // Everything the command wrote to stderr.
    stderr: []const u8,
};

//
// Executes a command using the specified tool.
// Like Node's `child_process.exec`, the command runs in the shell (/bin/sh -c, or cmd.exe on Windows)
// with the environment of `process.env` (see process-env.zig), and fails when the command cannot be
// started or exits with a non-zero code. The error message is Node's: "Command failed: <command>\n<stderr>".
//
pub fn exec(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !ExecResult {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/s", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = process_env.getEnvironMap(),
    }) catch |err| {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, @errorName(err) });
    };
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, result.stderr });
    }
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

// Not ported: execLogged (not used by replicate or verify).

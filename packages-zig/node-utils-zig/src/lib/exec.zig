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

//
// Checks the result of a command run with execLogged: returns the reason it failed, or null when it did not
// (TypeScript: the optional `validate` callback, `() => Promise<string | undefined>`).
//
pub const IValidate = struct {
    // The state the check reads.
    context: *anyopaque,

    // The check.
    function: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8,
};

//
// Runs the command and adds logging for the tool used.
//
pub fn execLogged(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const log = &utils.log.log;
    log.verbose(try std.fmt.allocPrint(allocator, "Executing {s} with command: \"{s}\"", .{ tool, command }));
    return execLoggedInner(allocator, io, tool, command, validate) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{command});
        log.exception(msg, err);
        return errors.throwError("{s}", .{msg});
    };
}

//
// The body of the try block of execLogged.
//
fn execLoggedInner(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const log = &utils.log.log;
    const result = try exec(allocator, io, command);
    log.tool(tool, .{ .stdout = result.stdout, .stderr = result.stderr });
    if (validate) |check| {
        const validationFailedReason = try check.function(check.context, allocator, io);
        if (validationFailedReason) |reason| {
            const msg = try std.fmt.allocPrint(allocator, "Validation failed for command: {s}\nReason: {s}", .{ command, reason });
            log.@"error"(msg);
            log.info(try std.fmt.allocPrint(allocator, "===\nCommand: {s}\nCommand stdout:\n{s}\nCommand stderr:\n{s}\n===", .{
                command,
                if (result.stdout.len > 0) result.stdout else "No output",
                if (result.stderr.len > 0) result.stderr else "No error",
            }));
            return errors.throwError("{s}", .{msg});
        }
    }
    return result;
}

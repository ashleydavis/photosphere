const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;
const ziggy_exec = @import("ziggy").task_queue.utils.exec;
const in_process_tools = @import("in-process-tools.zig");

//
// Runs commands as Ziggy's exec does, except that a command that starts ImageMagick, ffmpeg or ffprobe goes to the runner of the tools
// built into the program when there is one (see in-process-tools.zig). Ziggy's exec only starts programs.
//

//
// The output of a command run with exec.
//
pub const ExecResult = ziggy_exec.ExecResult;

//
// Checks the result of a command run with execLogged: returns the reason it failed, or null when it did not. The check is optional.
//
pub const IValidate = ziggy_exec.IValidate;

//
// Executes a command as Ziggy's exec does: in the shell, failing when it cannot be started or exits with a non-zero code. A command that
// starts ImageMagick, ffmpeg or ffprobe goes to the runner in tools when there is one, and null means every command is started as a
// program.
//
pub fn exec(allocator: std.mem.Allocator, io: std.Io, tools: ?in_process_tools.InProcessRunner, command: []const u8) !ExecResult {
    if (try in_process_tools.tryRun(allocator, io, tools, command)) |result| {
        return result;
    }
    return try ziggy_exec.exec(allocator, io, command);
}

//
// Runs the command and adds logging for the tool used.
//
pub fn execLogged(allocator: std.mem.Allocator, io: std.Io, tools: ?in_process_tools.InProcessRunner, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const log = &utils.log.log;
    log.verbose(try std.fmt.allocPrint(allocator, "Executing {s} with command: \"{s}\"", .{ tool, command }));
    return execLoggedInner(allocator, io, tools, tool, command, validate) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{command});
        log.exception(msg, err);
        return errors.throwError("{s}", .{msg});
    };
}

//
// The body of the try block of execLogged.
//
fn execLoggedInner(allocator: std.mem.Allocator, io: std.Io, tools: ?in_process_tools.InProcessRunner, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const log = &utils.log.log;
    const result = try exec(allocator, io, tools, command);
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

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const errors = utils.errors;

//
// Running ImageMagick, ffmpeg and ffprobe inside the app's own process, for an app that has them built in instead of starting them as programs of
// their own. Callers pass the tool and its arguments as a list to runTool or runToolLogged, which hand them to the runner exactly as given,
// so an argument may hold any character.
//

//
// What a tool printed and the exit code it ended with.
//
pub const ToolOutput = struct {
    // The exit code; 0 is success.
    exit_code: i32,

    // What the tool printed.
    output: []const u8,
};

//
// What a tool run with runTool or runToolLogged printed.
//
pub const ToolResult = struct {
    // Everything the tool printed, which is all the runner reports.
    stdout: []const u8,

    // Always empty: the runner reports what the tool printed as one text, which is in stdout.
    stderr: []const u8,
};

//
// Checks the result of a tool run with runToolLogged: returns the reason it failed, or null when it did not. The check is optional.
//
pub const IValidate = struct {
    // The state the check reads.
    context: *anyopaque,

    // The check.
    function: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8,
};

//
// Runs one tool built into the program with its arguments, which do not include the tool's own name. runTool and runToolLogged call it.
//
pub const InProcessRunner = struct {
    // The runner's own pointer, passed back on every call.
    context: ?*anyopaque,

    // Runs the tool (one of `magick`, `ffmpeg` or `ffprobe`) in the app's process with the arguments, with the calling thread's Io, log
    // and allocator.
    run: *const fn (context: ?*anyopaque, io: std.Io, log: ILog, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!ToolOutput,
};

//
// The tool followed by each of its arguments, separated by single spaces. The text is for messages only.
//
fn describeCommand(allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) ![]const u8 {
    var description: std.ArrayList(u8) = .empty;
    try description.appendSlice(allocator, tool);
    for (arguments) |argument| {
        try description.append(allocator, ' ');
        try description.appendSlice(allocator, argument);
    }
    return description.toOwnedSlice(allocator);
}

//
// Runs the tool (one of `magick`, `ffmpeg` or `ffprobe`) with the arguments, which do not include the tool's own name, and returns its
// stdout (everything the tool printed, which is all the runner reports). Fails with the tool, its arguments and its output when the tool
// ends with a non-zero code.
//
pub fn runTool(allocator: std.mem.Allocator, io: std.Io, log: ILog, runner: InProcessRunner, tool: []const u8, arguments: []const []const u8) !ToolResult {
    const result = try runner.run(runner.context, io, log, allocator, tool, arguments);
    if (result.exit_code != 0) {
        return errors.throwError("Command failed: {s}\n{s}", .{ try describeCommand(allocator, tool, arguments), result.output });
    }
    return .{
        .stdout = result.output,
        .stderr = "",
    };
}

//
// Runs the tool with the arguments as runTool does, and logs the command, its failure and what the tool wrote to the log given.
//
pub fn runToolLogged(allocator: std.mem.Allocator, io: std.Io, log: ILog, runner: InProcessRunner, tool: []const u8, arguments: []const []const u8, validate: ?IValidate) !ToolResult {
    const description = try describeCommand(allocator, tool, arguments);
    log.verbose(try std.fmt.allocPrint(allocator, "Executing {s} with command: \"{s}\"", .{ tool, description }));
    return runToolLoggedInner(allocator, io, log, runner, tool, arguments, description, validate) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{description});
        log.exception(msg, err);
        return errors.throwError("{s}", .{msg});
    };
}

//
// The body of the try block of runToolLogged.
//
fn runToolLoggedInner(allocator: std.mem.Allocator, io: std.Io, log: ILog, runner: InProcessRunner, tool: []const u8, arguments: []const []const u8, description: []const u8, validate: ?IValidate) !ToolResult {
    const result = try runTool(allocator, io, log, runner, tool, arguments);
    log.tool(tool, .{ .stdout = result.stdout, .stderr = result.stderr });
    if (validate) |check| {
        const validationFailedReason = try check.function(check.context, allocator, io);
        if (validationFailedReason) |reason| {
            const msg = try std.fmt.allocPrint(allocator, "Validation failed for command: {s}\nReason: {s}", .{ description, reason });
            log.@"error"(msg);
            log.info(try std.fmt.allocPrint(allocator, "===\nCommand: {s}\nCommand stdout:\n{s}\nCommand stderr:\n{s}\n===", .{
                description,
                if (result.stdout.len > 0) result.stdout else "No output",
                if (result.stderr.len > 0) result.stderr else "No error",
            }));
            return errors.throwError("{s}", .{msg});
        }
    }
    return result;
}

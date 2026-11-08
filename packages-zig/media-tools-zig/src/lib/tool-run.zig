const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const image_magick = @import("image-magick.zig");
const ffmpeg = @import("ffmpeg.zig");
const errors = utils.errors;

//
// Running ImageMagick, ffmpeg and ffprobe, which are built into the program, from the code that uses them: the tool and its
// arguments are handed to the tool's own function (ImageMagick.runMagick, Ffmpeg.runFfmpeg or Ffmpeg.runFfprobe) exactly as given, so
// an argument may hold any character. A tool that ends with a non-zero code fails loudly with the command and what the tool printed.
// The tools must have been started for the program (see MediaTools) before any of them runs.
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
// A tool built into the program.
//
pub const Tool = enum {
    // ImageMagick's `magick`.
    magick,

    // FFmpeg's `ffmpeg`.
    ffmpeg,

    // FFmpeg's `ffprobe`.
    ffprobe,
};

//
// Checks the result of a tool run with runLogged: returns the reason it failed, or null when it did not.
//
pub const IValidate = struct {
    // The state the check reads.
    context: *anyopaque,

    // The check.
    function: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8,
};

//
// The tool followed by each of its arguments, separated by single spaces. The text is for messages only.
//
pub fn describeCommand(allocator: std.mem.Allocator, tool: Tool, arguments: []const []const u8) ![]const u8 {
    var description: std.ArrayList(u8) = .empty;
    try description.appendSlice(allocator, @tagName(tool));
    for (arguments) |argument| {
        try description.append(allocator, ' ');
        try description.appendSlice(allocator, argument);
    }
    return description.toOwnedSlice(allocator);
}

//
// Runs the tool with the arguments, which do not include the tool's own name, and returns everything it printed. Fails with the tool,
// its arguments and what it printed when the tool ends with a non-zero code.
//
pub fn runChecked(allocator: std.mem.Allocator, io: std.Io, log: ILog, tool: Tool, arguments: []const []const u8) ![]const u8 {
    const result = switch (tool) {
        .magick => try image_magick.ImageMagick.runMagick(io, log, allocator, arguments),
        .ffmpeg => try ffmpeg.Ffmpeg.runFfmpeg(io, log, allocator, arguments),
        .ffprobe => try ffmpeg.Ffmpeg.runFfprobe(io, log, allocator, arguments),
    };
    if (result.exit_code != 0) {
        return errors.throwError("Command failed: {s}\n{s}", .{ try describeCommand(allocator, tool, arguments), result.output });
    }
    return result.output;
}

//
// Runs the tool with the arguments as runChecked does, and logs the command at verbose, what the tool printed as the tool's output,
// and its failure, or the failure of the validation given, to the log given.
//
pub fn runLogged(allocator: std.mem.Allocator, io: std.Io, log: ILog, tool: Tool, arguments: []const []const u8, validate: ?IValidate) ![]const u8 {
    const description = try describeCommand(allocator, tool, arguments);
    log.verbose(try std.fmt.allocPrint(allocator, "Executing {s} with command: \"{s}\"", .{ @tagName(tool), description }));
    return runLoggedInner(allocator, io, log, tool, arguments, description, validate) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{description});
        log.exception(msg, err);
        return errors.throwError("{s}", .{msg});
    };
}

//
// The body of the try block of runLogged.
//
fn runLoggedInner(allocator: std.mem.Allocator, io: std.Io, log: ILog, tool: Tool, arguments: []const []const u8, description: []const u8, validate: ?IValidate) ![]const u8 {
    const output = try runChecked(allocator, io, log, tool, arguments);
    log.tool(@tagName(tool), .{
        .stdout = output,
        .stderr = "",
    });
    if (validate) |check| {
        const validationFailedReason = try check.function(check.context, allocator, io);
        if (validationFailedReason) |reason| {
            const msg = try std.fmt.allocPrint(allocator, "Validation failed for command: {s}\nReason: {s}", .{ description, reason });
            log.@"error"(msg);
            log.info(try std.fmt.allocPrint(allocator, "===\nCommand: {s}\nCommand stdout:\n{s}\nCommand stderr:\n{s}\n===", .{
                description,
                if (output.len > 0) output else "No output",
                "No error",
            }));
            return errors.throwError("{s}", .{msg});
        }
    }
    return output;
}

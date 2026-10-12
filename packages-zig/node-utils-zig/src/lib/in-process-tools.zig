const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;
const exec = @import("exec.zig");

//
// Running ImageMagick, ffmpeg and ffprobe inside the app's own process, for an app that has them built in instead of starting them as programs of
// their own. A caller that has a runner passes it to exec, which hands it any command that starts one of the tools the runner handles
// instead of starting a shell. With no runner (null) nothing here has any effect.
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
// Runs one tool with its arguments, which do not include the tool's own name.
//
pub const InProcessRunner = struct {
    // The runner's own pointer, passed back on every call.
    context: ?*anyopaque,

    // Whether the runner runs the tool (one of `magick`, `ffmpeg` or `ffprobe`). A command for a tool it does not run is started as a
    // program, as it is when there is no runner.
    handles: *const fn (context: ?*anyopaque, tool: []const u8) bool,

    // Runs the tool (one of `magick`, `ffmpeg` or `ffprobe`) with the arguments.
    run: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!ToolOutput,
};

//
// The tools the runner takes. A command that starts any other program is left to the shell.
//
const in_process_tools = [_][]const u8{ "magick", "ffmpeg", "ffprobe" };

//
// Splits a command into its words the way the shell does for a simple command: words are separated by white space, a quoted
// part is part of its word (so `jpeg:"a b.jpg"` is one word), single quotes keep everything, and inside double quotes a backslash
// escapes only a double quote, a backslash, a dollar sign or a backtick. Fails when a quote is not closed, or when the command
// uses shell syntax a runner in the process cannot do (a pipe, a redirect, a second command, a substitution, a variable).
//
pub fn splitCommand(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var index: usize = 0;
    while (index < command.len) : (index += 1) {
        const character = command[index];
        if (character == '"') {
            in_word = true;
            index += 1;
            while (true) : (index += 1) {
                if (index >= command.len) {
                    return errors.throwError("The command has a double quote that is not closed: {s}", .{command});
                }
                const quoted = command[index];
                if (quoted == '"') {
                    break;
                }
                if (quoted == '$' or quoted == '`') {
                    return errors.throwError("The command uses shell syntax that cannot run in the app's process: {s}", .{command});
                }
                if (quoted == '\\' and index + 1 < command.len and std.mem.indexOfScalar(u8, "\"\\$`", command[index + 1]) != null) {
                    index += 1;
                    try word.append(allocator, command[index]);
                    continue;
                }
                try word.append(allocator, quoted);
            }
        }
        else if (character == '\'') {
            in_word = true;
            index += 1;
            while (true) : (index += 1) {
                if (index >= command.len) {
                    return errors.throwError("The command has a single quote that is not closed: {s}", .{command});
                }
                if (command[index] == '\'') {
                    break;
                }
                try word.append(allocator, command[index]);
            }
        }
        else if (character == ' ' or character == '\t' or character == '\n') {
            if (in_word) {
                try words.append(allocator, try word.toOwnedSlice(allocator));
                in_word = false;
            }
        }
        else if (std.mem.indexOfScalar(u8, "|&;<>$`()", character) != null) {
            return errors.throwError("The command uses shell syntax that cannot run in the app's process: {s}", .{command});
        }
        else if (character == '\\') {
            in_word = true;
            index += 1;
            if (index >= command.len) {
                return errors.throwError("The command ends with a backslash: {s}", .{command});
            }
            try word.append(allocator, command[index]);
        }
        else {
            in_word = true;
            try word.append(allocator, character);
        }
    }
    if (in_word) {
        try words.append(allocator, try word.toOwnedSlice(allocator));
    }
    return try words.toOwnedSlice(allocator);
}

//
// Runs the command in the app's process when there is a runner that runs the tool the command starts, and returns its
// stdout (everything the tool printed, which is all the runner reports). Returns null when there is no runner or the command is not
// for the runner, so the caller starts it as usual. Fails with the message exec fails with when the tool ends with a non-zero code.
//
pub fn tryRun(allocator: std.mem.Allocator, tools: ?InProcessRunner, command: []const u8) !?exec.ExecResult {
    const runner = tools orelse {
        return null;
    };

    // Only the first word is read before knowing the command is for the runner, because a command for the shell may use syntax
    // that splitCommand refuses.
    const first_word_end = std.mem.indexOfAny(u8, command, " \t\n") orelse command.len;
    var is_tool = false;
    for (in_process_tools) |tool| {
        if (std.mem.eql(u8, command[0..first_word_end], tool)) {
            is_tool = true;
        }
    }
    if (!is_tool or !runner.handles(runner.context, command[0..first_word_end])) {
        return null;
    }
    const words = try splitCommand(allocator, command);
    const result = try runner.run(runner.context, allocator, words[0], words[1..]);
    if (result.exit_code != 0) {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, result.output });
    }
    return .{
        .stdout = result.output,
        .stderr = "",
    };
}

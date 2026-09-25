//
// Utilities for handling terminal operations safely in both TTY and non-TTY environments
//

const std = @import("std");
const utils = @import("utils-zig");
const tty = @import("tty.zig");
const log = &utils.log.log;

//
// When set, output is written here instead of stdout (used by tests).
//
var captured_output: ?*std.Io.Writer = null;

//
// When set, overrides whether stdout is a TTY (used by tests).
//
var tty_override: ?bool = null;

//
// Redirects the output of this module and overrides the TTY check (pass nulls to restore). Used by tests.
// This function has no TypeScript counterpart.
//
pub fn setOutputForTesting(writer: ?*std.Io.Writer, isTTY: ?bool) void {
    captured_output = writer;
    tty_override = isTTY;
}

//
// True when stdout is a TTY (`process.stdout.isTTY`).
//
fn stdoutIsTTY() bool {
    if (tty_override) |value| {
        return value;
    }
    return tty.isatty(tty.stdout_fd);
}

//
// Writes text to stdout (`process.stdout.write`), ignoring write errors.
//
fn writeStdout(text: []const u8) void {
    if (captured_output) |writer| {
        writer.writeAll(text) catch {};
        return;
    }
    var buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(std.Options.debug_io, &buffer);
    const stdout = &file_writer.interface;
    stdout.writeAll(text) catch {};
    stdout.flush() catch {};
}

//
// Clears the whole current line (`process.stdout.clearLine(0)`).
//
fn clearLine() void {
    if (stdoutIsTTY()) {
        writeStdout("\x1b[2K");
    }
}

//
// Moves the cursor to the given column (`process.stdout.cursorTo(x)`).
//
fn cursorTo(column: usize) void {
    if (stdoutIsTTY()) {
        var buffer: [32]u8 = undefined;
        const sequence = std.fmt.bufPrint(&buffer, "\x1b[{d}G", .{column + 1}) catch return;
        writeStdout(sequence);
    }
}

//
// Clears the current progress message.
//
pub fn clearProgressMessage() void {
    // Clear the current line and reset cursor position
    // Only when verbose logging is disabled (same condition as writeProgress)
    if (!log.verboseEnabled() and stdoutIsTTY()) {
        clearLine();
        cursorTo(0);
    }
}

//
// Writes a progress message over the current line (only on a TTY and when verbose logging is off).
//
pub fn writeProgress(message: []const u8) void {
    if (stdoutIsTTY()) {
        if (!log.verboseEnabled()) {
            clearProgressMessage();
            writeStdout(message);
        }
    }
}

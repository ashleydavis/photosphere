//
// Utilities for handling terminal operations safely in both TTY and non-TTY environments
//

const std = @import("std");
const utils = @import("utils-zig");
const tty = @import("tty.zig");
const log = &utils.log.log;

//
// True when stdout is a TTY (`process.stdout.isTTY`).
//
fn stdoutIsTTY() bool {
    return tty.isatty(tty.stdout_fd);
}

//
// Writes text to stdout (`process.stdout.write`), ignoring write errors.
//
fn writeStdout(text: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &buffer);
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

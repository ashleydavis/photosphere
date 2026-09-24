const std = @import("std");

//
// This file has no TypeScript counterpart: it stands in for the JavaScript global `console`.
// `console.log` and `console.debug` write a line to stdout, `console.error` and `console.warn`
// write a line to stderr. Output can be captured by tests with setCapture.
//
// The global `console` in JavaScript needs no Io instance, so this uses the Io instance that
// std.debug uses (std.Options.debug_io), which is independent of the application's Io.
//

//
// Serializes writes to stdout from multiple threads.
//
var stdout_mutex: std.Io.Mutex = .init;

//
// When set, lines written to stdout are written here instead (used by tests).
//
var captured_stdout: ?*std.Io.Writer = null;

//
// When set, lines written to stderr are written here instead (used by tests).
//
var captured_stderr: ?*std.Io.Writer = null;

//
// Redirects console output to the given writers (pass null to restore the real stdout/stderr).
//
pub fn setCapture(stdout_writer: ?*std.Io.Writer, stderr_writer: ?*std.Io.Writer) void {
    captured_stdout = stdout_writer;
    captured_stderr = stderr_writer;
}

//
// Writes a line to stdout, ignoring write errors (like console.log).
//
fn writeStdoutLine(message: []const u8) void {
    const io = std.Options.debug_io;
    stdout_mutex.lockUncancelable(io);
    defer stdout_mutex.unlock(io);
    if (captured_stdout) |capture_writer| {
        capture_writer.writeAll(message) catch {};
        capture_writer.writeByte('\n') catch {};
        return;
    }
    var buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &file_writer.interface;
    stdout.writeAll(message) catch {};
    stdout.writeByte('\n') catch {};
    stdout.flush() catch {};
}

//
// Writes a line to stderr, ignoring write errors (like console.error).
//
fn writeStderrLine(message: []const u8) void {
    var buffer: [1024]u8 = undefined;
    const locked_stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    if (captured_stderr) |capture_writer| {
        capture_writer.writeAll(message) catch {};
        capture_writer.writeByte('\n') catch {};
        return;
    }
    const stderr = &locked_stderr.file_writer.interface;
    stderr.writeAll(message) catch {};
    stderr.writeByte('\n') catch {};
}

//
// Equivalent of `console.log(message)`: writes a line to stdout.
//
pub fn log(message: []const u8) void {
    writeStdoutLine(message);
}

//
// Equivalent of `console.error(message)`: writes a line to stderr.
//
pub fn @"error"(message: []const u8) void {
    writeStderrLine(message);
}

//
// Equivalent of `console.warn(message)`: writes a line to stderr.
//
pub fn warn(message: []const u8) void {
    writeStderrLine(message);
}

//
// Equivalent of `console.debug(message)`: writes a line to stdout.
//
pub fn debug(message: []const u8) void {
    writeStdoutLine(message);
}

//
// Equivalent of `console.error(<formatted message>)` for a message built from a format string.
// Messages longer than the internal buffer are truncated.
//
pub fn errorFormat(comptime format: []const u8, args: anytype) void {
    var buffer: [16 * 1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    writeStderrLine(message);
}

//
// Equivalent of `console.log(<formatted message>)` for a message built from a format string.
// Messages longer than the internal buffer are truncated.
//
pub fn logFormat(comptime format: []const u8, args: anytype) void {
    var buffer: [16 * 1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    writeStdoutLine(message);
}

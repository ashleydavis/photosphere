const std = @import("std");
const errors = @import("errors.zig");

//
// Writes an error and its full cause chain to `writer` (used by formatErrorChain and by the default
// log, which must not allocate). Zig errors carry no stack trace, so the first line of the JavaScript
// `error.stack` ("Error: <message>") stands in for the stack.
//
pub fn writeErrorChain(writer: *std.Io.Writer, err: anyerror) std.Io.Writer.Error!void {
    try writer.print("Error: {s}", .{errors.errorMessage(err)});
    if (err != error.Thrown and err != error.FatalError) {
        return;
    }
    var cause_chain = errors.lastErrorCauseChain();
    while (cause_chain.next()) |cause_message| {
        try writer.writeAll("\nCaused by:\n");
        try writer.print("Error: {s}", .{cause_message});
    }
}

//
// Formats an error and its full cause chain into a single string.
//
pub fn formatErrorChain(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    try writeErrorChain(&allocating_writer.writer, err);
    return allocating_writer.written();
}

//
// An error that wraps another error to include the original cause.
// In Zig the cause is the most recent error thrown on the current thread:
// `throw new WrappedError(message, { cause })` is written `return WrappedError.throw("{s}", .{message})`.
//
pub const WrappedError = struct {
    //
    // Equivalent of `throw new WrappedError(message, { cause: <the most recent error> })`.
    //
    pub fn throw(comptime format: []const u8, args: anytype) errors.ThrownError {
        return errors.throwWrappedError(format, args);
    }

    //
    // Equivalent of `error instanceof WrappedError` for the most recent error.
    //
    pub fn isInstance(err: anyerror) bool {
        return err == error.Thrown and std.mem.eql(u8, errors.lastErrorName(), "WrappedError");
    }
};

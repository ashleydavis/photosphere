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
    const cause_names = errors.lastErrorCauseNames();
    var cause_index: usize = 0;
    while (cause_chain.next()) |cause_message| {
        try writer.writeAll("\nCaused by:\n");
        try writer.print("{s}: {s}", .{ stackName(if (cause_index < cause_names.len) cause_names[cause_index] else "Error"), cause_message });
        cause_index += 1;
    }
}

//
// The name the first line of an error's JavaScript `error.stack` shows: the error's `name`. WrappedError does not set
// one, so it shows the "Error" of the Error class it extends (Zig records it as "WrappedError" for isInstance).
//
fn stackName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "WrappedError")) {
        return "Error";
    }
    return name;
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

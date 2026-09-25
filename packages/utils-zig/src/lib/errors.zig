const std = @import("std");

//
// Zig errors cannot carry a message, but TypeScript errors do (and the CLI prints them).
// This file has no TypeScript counterpart: it records the message of the most recent error
// thrown on the current thread so that code written like `throw new Error(message)` in
// TypeScript can be written as `return errors.throwError(...)` in Zig.
//

//
// The Zig error returned when a plain TypeScript `Error` is thrown.
//
pub const ThrownError = error{Thrown};

//
// The Zig error returned when a TypeScript `FatalError` is thrown.
//
pub const FatalErrorSet = error{FatalError};

//
// The maximum number of bytes kept for an error message (longer messages are truncated).
//
const max_message_length = 16 * 1024;

//
// Separates the messages of the cause chain stored in ErrorRecord.cause_buffer.
//
const cause_separator: u8 = 0;

//
// The recorded details of the most recent error thrown on a thread.
// Public so that an error can be captured on one thread and restored on another (see captureError).
//
pub const ErrorRecord = struct {
    // Storage for the error message.
    message_buffer: [max_message_length]u8 = undefined,

    // Number of valid bytes in message_buffer.
    message_length: usize = 0,

    // Storage for the messages of the chain of errors that caused this one (WrappedError),
    // nearest cause first, each separated by cause_separator.
    cause_buffer: [max_message_length]u8 = undefined,

    // Number of valid bytes in cause_buffer.
    cause_length: usize = 0,

    // The TypeScript error class name ("Error", "FatalError" or "WrappedError").
    name: []const u8 = "Error",
};

//
// The most recent error thrown on this thread.
//
threadlocal var last_error: ErrorRecord = .{};

//
// Copies a message into a fixed size buffer, truncating it if necessary.
//
fn copyMessage(buffer: []u8, message: []const u8) usize {
    const length = @min(buffer.len, message.len);
    @memcpy(buffer[0..length], message[0..length]);
    return length;
}

//
// Records a formatted error message as the most recent error on this thread.
//
pub fn recordError(name: []const u8, comptime format: []const u8, args: anytype) void {
    const formatted = std.fmt.bufPrint(&last_error.message_buffer, format, args) catch blk: {
        break :blk last_error.message_buffer[0..];
    };
    last_error.message_length = formatted.len;
    last_error.cause_length = 0;
    last_error.name = name;
}

//
// Equivalent of `throw new Error(message)`.
//
pub fn throwError(comptime format: []const u8, args: anytype) ThrownError {
    recordError("Error", format, args);
    return error.Thrown;
}

//
// Equivalent of `throw new FatalError(message)`.
//
pub fn throwFatalError(comptime format: []const u8, args: anytype) FatalErrorSet {
    recordError("FatalError", format, args);
    return error.FatalError;
}

//
// Equivalent of `throw new WrappedError(message, { cause: <the most recent error> })`.
// The cause chain of the most recent error is kept behind the new cause.
// As in TypeScript the cause's message (when not empty) is folded into the message: "<message>: <cause message>".
//
pub fn throwWrappedError(comptime format: []const u8, args: anytype) ThrownError {
    recordErrorWithCause("WrappedError", true, format, args);
    return error.Thrown;
}

//
// Equivalent of `throw new Error(message, { cause: <the most recent error> })`.
// The cause chain of the most recent error is kept behind the new cause. Unlike WrappedError the
// cause's message is not folded into the message.
//
pub fn throwErrorWithCause(comptime format: []const u8, args: anytype) ThrownError {
    recordErrorWithCause("Error", false, format, args);
    return error.Thrown;
}

//
// Records a formatted error message whose cause is the most recent error (keeping that error's own
// cause chain behind it). When `fold_cause_message` is set the cause's message (when not empty) is
// appended to the message as "<message>: <cause message>", as WrappedError does.
//
fn recordErrorWithCause(name: []const u8, fold_cause_message: bool, comptime format: []const u8, args: anytype) void {
    var cause_buffer: [max_message_length]u8 = undefined;
    const cause_message_length = copyMessage(&cause_buffer, lastErrorMessage());
    var cause_length = cause_message_length;
    if (last_error.cause_length > 0 and cause_length < cause_buffer.len) {
        cause_buffer[cause_length] = cause_separator;
        cause_length += 1;
        cause_length += copyMessage(cause_buffer[cause_length..], last_error.cause_buffer[0..last_error.cause_length]);
    }
    recordError(name, format, args);
    if (fold_cause_message and cause_message_length > 0) {
        var message_length = last_error.message_length;
        message_length += copyMessage(last_error.message_buffer[message_length..], ": ");
        message_length += copyMessage(last_error.message_buffer[message_length..], cause_buffer[0..cause_message_length]);
        last_error.message_length = message_length;
    }
    last_error.cause_length = copyMessage(&last_error.cause_buffer, cause_buffer[0..cause_length]);
}

//
// Gets the message of the most recent error thrown on this thread.
//
pub fn lastErrorMessage() []const u8 {
    return last_error.message_buffer[0..last_error.message_length];
}

//
// Gets the message of the cause of the most recent error (empty when there is no cause).
//
pub fn lastErrorCauseMessage() []const u8 {
    const chain = last_error.cause_buffer[0..last_error.cause_length];
    const separator_index = std.mem.indexOfScalar(u8, chain, cause_separator) orelse chain.len;
    return chain[0..separator_index];
}

//
// Iterates the messages of the cause chain of the most recent error, nearest cause first.
//
pub fn lastErrorCauseChain() std.mem.SplitIterator(u8, .scalar) {
    const chain = last_error.cause_buffer[0..last_error.cause_length];
    if (chain.len == 0) {
        return .{ .buffer = chain, .index = null, .delimiter = cause_separator };
    }
    return std.mem.splitScalar(u8, chain, cause_separator);
}

//
// Copies the most recent error of this thread into `record`, so that it can be restored on another
// thread with restoreError (for example when an operation runs on a worker thread).
//
pub fn captureError(record: *ErrorRecord) void {
    record.* = last_error;
}

//
// Makes a previously captured error the most recent error of this thread.
//
pub fn restoreError(record: *const ErrorRecord) void {
    last_error = record.*;
}

//
// Gets the TypeScript class name of the most recent error thrown on this thread.
//
pub fn lastErrorName() []const u8 {
    return last_error.name;
}

//
// Gets the message for an error: the recorded message for thrown errors, otherwise the Zig error name
// (the equivalent of `error.message` for errors raised by the runtime).
//
pub fn errorMessage(err: anyerror) []const u8 {
    if (err == error.Thrown or err == error.FatalError) {
        return lastErrorMessage();
    }
    return @errorName(err);
}

//
// Clears the most recent error (used by tests).
//
pub fn clearError() void {
    last_error.message_length = 0;
    last_error.cause_length = 0;
    last_error.name = "Error";
}

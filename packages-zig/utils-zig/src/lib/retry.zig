const std = @import("std");
const errors = @import("ziggy").utils.errors;
const logging = @import("ziggy").log;
const sleep = @import("ziggy").utils.sleep;
const wrapped_error = @import("ziggy").utils.wrapped_error;

//
// An operation is a value (usually a pointer to a struct)
// with a method `run(self, io: std.Io, log: ILog) !ReturnT`. This gets ReturnT for an operation type.
//
pub fn OperationResult(comptime OperationT: type) type {
    const ContextT = switch (@typeInfo(OperationT)) {
        .pointer => |pointer_info| pointer_info.child,
        else => OperationT,
    };
    const RunReturnT = @typeInfo(@TypeOf(ContextT.run)).@"fn".return_type.?;
    return @typeInfo(RunReturnT).error_union.payload;
}

//
// Waits the given number of milliseconds, then fails with a timeout error.
//
pub fn rejectAfter(comptime ReturnT: type, io: std.Io, ms: u64) anyerror!ReturnT {
    try sleep.sleep(io, ms);
    return errors.throwError("Operation timed out after {d}ms", .{ms});
}

//
// Attempts an operation once. In TypeScript the operation is raced against a timer, which rejects after timeoutMS while the operation
// goes on in the background. A thread cannot go on with something else while an operation it started is still running without a
// second thread to run one of them, and a task runs only on its own thread, so here the operation runs to its end and gives its own
// result. timeoutMS is kept so the callers read as the TypeScript does.
//
pub fn retryOnce(io: std.Io, log: logging.ILog, operation: anytype, timeoutMS: u64) anyerror!OperationResult(@TypeOf(operation)) {
    _ = timeoutMS;
    return operation.run(io, log);
}

//
// Logs, to the log given, the error of a failed attempt as an indented JSON object holding its name and message (a Zig error has no stack to include).
//
fn logVerboseError(log: logging.ILog, err: anyerror) void {
    var buffer: [16 * 1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    fixed_writer.print("Error: {{\n  \"name\": {f},\n  \"message\": {f}\n}}", .{ std.json.fmt(errors.errorName(err), .{}), std.json.fmt(errors.errorMessage(err), .{}) }) catch {};
    log.verbose(fixed_writer.buffered());
}

//
// Logs the context of the operation (or "An operation failed" when it has none), then ". Retrying after: " and the message of the error,
// as a warning.
//
fn logRetryWarning(log: logging.ILog, errorContext: ?[]const u8, err: anyerror) void {
    var buffer: [32 * 1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    fixed_writer.print("{s}. Retrying after: {s}", .{ errorContext orelse "An operation failed", errors.errorMessage(err) }) catch {};
    log.warn(fixed_writer.buffered());
}

//
// Retrys a failing operation a number of times, logging each failure that is retried to the log given.
// Each attempt is raced against a timeout and rejected if it doesn't complete in time.
//
pub fn retry(io: std.Io, log: logging.ILog, operation: anytype, maxAttempts: u32, waitTimeMS: u64, waitTimeScale: u64, timeoutMS: u64, errorContext: ?[]const u8) anyerror!OperationResult(@TypeOf(operation)) {
    var attempts_left = maxAttempts;
    var wait_time_ms = waitTimeMS;

    while (attempts_left > 0) {
        attempts_left -= 1;
        if (retryOnce(io, log, operation, timeoutMS)) |result| {
            return result;
        }
        else |err| {
            if (attempts_left >= 1) {
                // What went wrong on an attempt that is about to be tried again, said once, in one
                // line. It used to be verbose-only, and the last attempt's error was the only one
                // anyone ever saw: on a phone that made a failure that takes three attempts and a
                // minute and a half look like a single event with a single cause, and hid that the
                // first attempt failed differently from the ones that followed it.
                logRetryWarning(log, errorContext, err);

                if (log.verboseEnabled()) {
                    logVerboseError(log, err);
                }

                try sleep.sleep(io, wait_time_ms);
                wait_time_ms *= waitTimeScale;
            }
            else {
                logging.console.errorFormat("Operation failed, no more retries allowed. Last error: {s}: {s}", .{ errors.errorName(err), errors.errorMessage(err) });

                if (errorContext) |context| {
                    if (err != error.Thrown and err != error.FatalError) {
                        errors.recordError("Error", "{s}", .{@errorName(err)});
                    }
                    return wrapped_error.WrappedError.throw("{s}", .{context});
                }

                return err;
            }
        }
    }

    return errors.throwError("Expected there to be an error!", .{});
}

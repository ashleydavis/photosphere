const std = @import("std");
const errors = @import("ziggy").task_queue.utils.errors;
const console = @import("ziggy").task_queue.utils.console;
const log_module = @import("ziggy").task_queue.utils.log;
const sleep_module = @import("ziggy").task_queue.utils.sleep;
const wrapped_error = @import("ziggy").task_queue.utils.wrapped_error;

//
// An operation is a value (usually a pointer to a struct)
// with a method `run(self, io: std.Io) !ReturnT`. This gets ReturnT for an operation type.
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
// Gets the text that names an operation type in the timeout message: its source with runs of whitespace
// collapsed to one space, cut to 200 characters.
// An operation has no source text of its own, so its type declares `pub const source` holding
// the text that names the call it makes.
//
fn operationSourceOf(comptime OperationT: type) []const u8 {
    const ContextT = switch (@typeInfo(OperationT)) {
        .pointer => |pointer_info| pointer_info.child,
        else => OperationT,
    };
    if (!@hasDecl(ContextT, "source")) {
        @compileError("retry operation " ++ @typeName(ContextT) ++ " must declare `pub const source` (the text that names the operation in the timeout message)");
    }
    comptime {
        const raw: []const u8 = ContextT.source;
        @setEvalBranchQuota(1000 + raw.len * 20);
        var collapsed: []const u8 = "";
        var in_whitespace = false;
        for (raw) |character| {
            if (std.ascii.isWhitespace(character)) {
                if (!in_whitespace) {
                    collapsed = collapsed ++ " ";
                }
                in_whitespace = true;
            }
            else {
                collapsed = collapsed ++ &[_]u8{character};
                in_whitespace = false;
            }
        }
        const sliced = collapsed[0..@min(collapsed.len, 200)];
        const final = sliced[0..sliced.len].*;
        return &final;
    }
}

//
// Runs an operation on a concurrent task, capturing the thread-local error message of a failure
// so the caller's thread can restore it.
//
fn OperationTask(comptime OperationT: type) type {
    return struct {
        //
        // Runs the operation and captures its error message on failure.
        //
        fn run(operation: OperationT, io: std.Io, error_record: *errors.ErrorRecord) anyerror!OperationResult(OperationT) {
            return operation.run(io) catch |err| {
                errors.captureError(error_record);
                return err;
            };
        }
    };
}

//
// Waits for the timeout of retryOnce.
//
fn waitForTimeout(io: std.Io, timeoutMS: u64) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(@intCast(timeoutMS)), .awake);
}

//
// Waits the given number of milliseconds, then fails with a timeout error.
//
pub fn rejectAfter(comptime ReturnT: type, io: std.Io, ms: u64) anyerror!ReturnT {
    try sleep_module.sleep(io, ms);
    return errors.throwError("Operation timed out after {d}ms", .{ms});
}

//
// Attempts an operation once, rejecting if it doesn't complete within timeoutMS.
// The operation runs concurrently with a timer.
// When the timer wins, the operation cannot be left running in the background: it borrows memory owned by the
// caller (the operation value, the caller's allocator and buffers) that is gone once retry returns, and a
// concurrent task must be awaited or canceled before its storage is released. So the operation is canceled
// instead: it stops at its next cancelation point and the timeout error is then returned.
// An operation that still succeeds after the cancelation (it reached no cancelation
// point, e.g. its thread had not even been scheduled yet when the timer fired) wins over the timer.
// The operation and the timer must both run concurrently: when the Io
// implementation cannot run either of them concurrently, error.ConcurrencyUnavailable is returned.
//
pub fn retryOnce(io: std.Io, operation: anytype, timeoutMS: u64) anyerror!OperationResult(@TypeOf(operation)) {
    const OperationT = @TypeOf(operation);
    const ReturnT = OperationResult(OperationT);

    // What the operation is, read from its own source.
    //
    // A timeout is raised by a timer rather than by the work, so the error it throws carries the
    // timer's stack and says nothing about what was being waited for. "Operation timed out after
    // 30000ms" was the whole of what a failing background sync reported on a phone, pass after pass,
    // and there are dozens of retries it could have come from. A stack does not help either: the
    // callers are async, so it shows only the frames inside this file. The operation's own text does,
    // because it names the call the operation makes.
    const operationSource = comptime operationSourceOf(OperationT);

    //
    // Whichever of the operation and the timer finishes first.
    //
    const Outcome = union(enum) {
        // The operation finished.
        completed: anyerror!ReturnT,

        // The timeout elapsed.
        timedOut: std.Io.Cancelable!void,
    };

    var outcome_buffer: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &outcome_buffer);
    var error_record: errors.ErrorRecord = undefined;
    try select.concurrent(.completed, OperationTask(OperationT).run, .{ operation, io, &error_record });
    select.concurrent(.timedOut, waitForTimeout, .{ io, timeoutMS }) catch |err| {
        select.cancelDiscard();
        return err;
    };
    const outcome = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    switch (outcome) {
        .completed => |result| {
            select.cancelDiscard();
            return result catch |err| {
                errors.restoreError(&error_record);
                return err;
            };
        },
        .timedOut => |sleep_result| {
            const late_outcome = select.cancel();
            select.cancelDiscard();
            try sleep_result;
            if (late_outcome) |late| {
                switch (late) {
                    .completed => |late_result| {
                        if (late_result) |value| {
                            return value;
                        }
                        else |_| {}
                    },
                    .timedOut => unreachable,
                }
            }
            return errors.throwError("Operation timed out after {d}ms: {s}", .{ timeoutMS, operationSource });
        },
    }
}

//
// Logs the error of a failed attempt as an indented JSON object holding its name and message (a Zig error has no stack to include).
//
fn logVerboseError(err: anyerror) void {
    var buffer: [16 * 1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    fixed_writer.print("Error: {{\n  \"name\": {f},\n  \"message\": {f}\n}}", .{ std.json.fmt(errors.errorName(err), .{}), std.json.fmt(errors.errorMessage(err), .{}) }) catch {};
    log_module.log.verbose(fixed_writer.buffered());
}

//
// Logs the context of the operation (or "An operation failed" when it has none), then ". Retrying after: " and the message of the error,
// as a warning.
//
fn logRetryWarning(errorContext: ?[]const u8, err: anyerror) void {
    var buffer: [32 * 1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    fixed_writer.print("{s}. Retrying after: {s}", .{ errorContext orelse "An operation failed", errors.errorMessage(err) }) catch {};
    log_module.log.warn(fixed_writer.buffered());
}

//
// Retrys a failing operation a number of times.
// Each attempt is raced against a timeout and rejected if it doesn't complete in time.
//
pub fn retry(io: std.Io, operation: anytype, maxAttempts: u32, waitTimeMS: u64, waitTimeScale: u64, timeoutMS: u64, errorContext: ?[]const u8) anyerror!OperationResult(@TypeOf(operation)) {
    var attempts_left = maxAttempts;
    var wait_time_ms = waitTimeMS;

    while (attempts_left > 0) {
        attempts_left -= 1;
        if (retryOnce(io, operation, timeoutMS)) |result| {
            return result;
        }
        else |err| {
            if (attempts_left >= 1) {
                // What went wrong on an attempt that is about to be tried again, said once, in one
                // line. It used to be verbose-only, and the last attempt's error was the only one
                // anyone ever saw: on a phone that made a failure that takes three attempts and a
                // minute and a half look like a single event with a single cause, and hid that the
                // first attempt failed differently from the ones that followed it.
                logRetryWarning(errorContext, err);

                if (log_module.log.verboseEnabled()) {
                    logVerboseError(err);
                }

                try sleep_module.sleep(io, wait_time_ms);
                wait_time_ms *= waitTimeScale;
            }
            else {
                console.errorFormat("Operation failed, no more retries allowed. Last error: {s}: {s}", .{ errors.errorName(err), errors.errorMessage(err) });

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

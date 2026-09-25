const std = @import("std");
const errors = @import("errors.zig");
const console = @import("console.zig");
const log_module = @import("log.zig");
const sleep_module = @import("sleep.zig");
const wrapped_error = @import("wrapped-error.zig");

//
// In Zig an operation (TypeScript: `() => Promise<ReturnT>`) is a value (usually a pointer to a struct)
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
// Gets `operation.toString().replace(/\s+/g, " ").slice(0, 200)` for an operation type.
// A Zig operation has no source text of its own, so its type declares `pub const source` holding the
// text Bun gives for the TypeScript arrow function it stands in for (`operation.toString()`).
//
fn operationSourceOf(comptime OperationT: type) []const u8 {
    const ContextT = switch (@typeInfo(OperationT)) {
        .pointer => |pointer_info| pointer_info.child,
        else => OperationT,
    };
    if (!@hasDecl(ContextT, "source")) {
        @compileError("retry operation " ++ @typeName(ContextT) ++ " must declare `pub const source` (the Bun toString() of the TypeScript arrow function)");
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

// Not ported: rejectAfter (not used by replicate or verify).

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
// Waits for the timeout of retryOnce (the `setTimeout` in TypeScript).
//
fn waitForTimeout(io: std.Io, timeoutMS: u64) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(@intCast(timeoutMS)), .awake);
}

//
// Attempts an operation once, rejecting if it doesn't complete within timeoutMS.
// The operation runs concurrently with a timer (the `setTimeout` in TypeScript).
// When the timer wins, TypeScript leaves the operation running in the background, kept alive by the
// garbage collector. Zig cannot do that: the operation borrows memory owned by the caller (the operation
// value, the caller's allocator and buffers) that is gone once retry returns, and a concurrent task
// must be awaited or canceled before its storage is released. So the operation is canceled instead:
// it stops at its next cancelation point and the timeout error is then returned (an operation with no
// cancelation points delays the timeout error until it finishes).
// When the Io implementation cannot run tasks concurrently the operation runs without a timeout.
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
    // callers are async, and the embedded engine shows only the two synchronous frames inside this
    // file. The operation's own text does, because these are all one-line arrow functions naming the
    // call they make.
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
    select.concurrent(.completed, OperationTask(OperationT).run, .{ operation, io, &error_record }) catch {
        return operation.run(io);
    };
    select.concurrent(.timedOut, waitForTimeout, .{ io, timeoutMS }) catch {};
    const outcome = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.cancelDiscard();
    switch (outcome) {
        .completed => |result| {
            return result catch |err| {
                errors.restoreError(&error_record);
                return err;
            };
        },
        .timedOut => |sleep_result| {
            try sleep_result;
            return errors.throwError("Operation timed out after {d}ms: {s}", .{ timeoutMS, operationSource });
        },
    }
}

//
// Logs the error of a failed attempt the way `JSON.stringify(serializeError(error), null, 2)` does
// (Zig errors have no stack, so only the name and message are included).
//
fn logVerboseError(err: anyerror) void {
    var buffer: [16 * 1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    fixed_writer.print("Error: {{\n  \"name\": \"Error\",\n  \"message\": {f}\n}}", .{std.json.fmt(errors.errorMessage(err), .{})}) catch {};
    log_module.log.verbose(fixed_writer.buffered());
}

//
// Logs `${errorContext ?? "An operation failed"}. Retrying after: ${error?.message ?? String(error)}`
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
                console.errorFormat("Operation failed, no more retries allowed. Last error: Error: {s}", .{errors.errorMessage(err)});

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

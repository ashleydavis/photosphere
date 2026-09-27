const std = @import("std");
const retry_module = @import("retry.zig");
const log_module = @import("log.zig");
const sleep_module = @import("sleep.zig");
const OperationResult = retry_module.OperationResult;

//
// Retries a failing operation a number of times. If all retries fail,
// logs the error and returns undefined instead of throwing.
// (Zig: the operation is a value with a method `run(self, io: std.Io) !ReturnT`, as for retry, and
// undefined is null. The TypeScript defaults are maxAttempts 3, waitTimeMS 1000 and waitTimeScale 2.)
//
pub fn retryOrLog(io: std.Io, operation: anytype, errorMessage: []const u8, maxAttempts: u32, waitTimeMS: u64, waitTimeScale: u64) !?OperationResult(@TypeOf(operation)) {
    var attemptsLeft = maxAttempts;
    var waitTime = waitTimeMS;

    while (attemptsLeft > 0) {
        attemptsLeft -= 1;
        if (operation.run(io)) |result| {
            return result;
        }
        else |err| {
            if (attemptsLeft >= 1) {
                log_module.log.exception("Operation failed, will retry.", err);

                try sleep_module.sleep(io, waitTime);
                waitTime *= waitTimeScale;
            }
            else {
                const message = if (errorMessage.len > 0) errorMessage else "Operation failed after all retries";
                log_module.log.exception(message, err);
                return null;
            }
        }
    }

    // This should never be reached, but TypeScript needs it for type safety
    return null;
}

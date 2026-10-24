const std = @import("std");
const retry = @import("retry.zig");
const log = @import("ziggy").task_queue.utils.log;
const sleep = @import("ziggy").task_queue.utils.sleep;
const OperationResult = retry.OperationResult;

//
// Retries a failing operation a number of times. If all retries fail,
// logs the error and returns undefined instead of throwing.
// (The operation is a value with a method `run(self, io: std.Io) !ReturnT`, as for retry, and
// undefined is null. Callers conventionally pass maxAttempts 3, waitTimeMS 1000 and waitTimeScale 2.)
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
                log.log.exception("Operation failed, will retry.", err);

                try sleep.sleep(io, waitTime);
                waitTime *= waitTimeScale;
            }
            else {
                const message = if (errorMessage.len > 0) errorMessage else "Operation failed after all retries";
                log.log.exception(message, err);
                return null;
            }
        }
    }

    // This should never be reached.
    return null;
}

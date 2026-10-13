const std = @import("std");
const retry_module = @import("retry.zig");
const log_module = @import("ziggy-core").task_queue.utils.log;
const OperationResult = retry_module.OperationResult;

//
// Attempts to execute an operation. If it succeeds, returns the result.
// If it fails, logs the error and returns null.
// (The operation is a value with a method `run(self, io: std.Io) !ReturnT`, as for retry. An empty error message means "Operation failed".)
//
pub fn tryOrLog(io: std.Io, operation: anytype, errorMessage: []const u8) ?OperationResult(@TypeOf(operation)) {
    if (operation.run(io)) |result| {
        return result;
    }
    else |err| {
        const message = if (errorMessage.len > 0) errorMessage else "Operation failed";
        log_module.log.exception(message, err);
        return null;
    }
}

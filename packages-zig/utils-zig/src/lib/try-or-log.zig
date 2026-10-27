const std = @import("std");
const retry = @import("retry.zig");
const ILog = @import("ziggy").task_queue.utils.log.ILog;
const OperationResult = retry.OperationResult;

//
// Attempts to execute an operation. If it succeeds, returns the result.
// If it fails, logs the error to the log given and returns null.
// (The operation is a value with a method `run(self, io: std.Io, log: ILog) !ReturnT`, as for retry. An empty error message means "Operation failed".)
//
pub fn tryOrLog(io: std.Io, log: ILog, operation: anytype, errorMessage: []const u8) ?OperationResult(@TypeOf(operation)) {
    if (operation.run(io, log)) |result| {
        return result;
    }
    else |err| {
        const message = if (errorMessage.len > 0) errorMessage else "Operation failed";
        log.exception(message, err);
        return null;
    }
}

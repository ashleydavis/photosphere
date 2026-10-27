const std = @import("std");
const retry = @import("retry.zig");
const OperationResult = retry.OperationResult;
const ILog = @import("ziggy").task_queue.utils.log.ILog;

//
// Attempts to execute an operation. If it succeeds, returns the result.
// If it fails, silently swallows the error and returns undefined without logging.
// (Zig: the operation is a value with a method `run(self, io: std.Io, log: ILog) !ReturnT`, as for retry, and
// undefined is null. The log is passed to the operation, and nothing is written to it here.)
//
pub fn swallowError(io: std.Io, log: ILog, operation: anytype) ?OperationResult(@TypeOf(operation)) {
    const result = operation.run(io, log) catch {
        // Silently swallow the error - don't log it
        return null;
    };
    return result;
}

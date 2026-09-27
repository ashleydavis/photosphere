const std = @import("std");
const retry_module = @import("retry.zig");
const OperationResult = retry_module.OperationResult;

//
// Attempts to execute an operation. If it succeeds, returns the result.
// If it fails, silently swallows the error and returns undefined without logging.
// (Zig: the operation is a value with a method `run(self, io: std.Io) !ReturnT`, as for retry, and
// undefined is null.)
//
pub fn swallowError(io: std.Io, operation: anytype) ?OperationResult(@TypeOf(operation)) {
    const result = operation.run(io) catch {
        // Silently swallow the error - don't log it
        return null;
    };
    return result;
}

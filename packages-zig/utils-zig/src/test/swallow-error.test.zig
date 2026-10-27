const std = @import("std");
const utils = @import("utils-zig");
const ExceptionLog = @import("exception-log.zig").ExceptionLog;
const swallowError = utils.swallow_error.swallowError;
const errors = utils.errors;

const io = std.testing.io;

//
// An operation that resolves with a value or rejects.
//
fn MockOperation(comptime ValueT: type) type {
    return struct {
        // The value resolved with.
        value: ValueT,

        // When true the operation rejects instead.
        fails: bool = false,

        // The message of the error rejected with.
        failureMessage: []const u8 = "Operation failed",

        // Number of times run has been called.
        calls: u32 = 0,

        //
        // Runs the operation.
        //
        pub fn run(self: *@This(), operationIo: std.Io, _: utils.log.ILog) !ValueT {
            _ = operationIo;
            self.calls += 1;
            if (self.fails) {
                return errors.throwError("{s}", .{self.failureMessage});
            }
            return self.value;
        }
    };
}

//
// A record returned by an operation.
//
const KeyValue = struct {
    // The value of the key.
    key: []const u8,
};

test "should return result on success" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: MockOperation([]const u8) = .{ .value = "success" };

    const result = swallowError(io, log, &operation);

    try std.testing.expectEqualStrings("success", result.?);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should return undefined and not log error on failure" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true };

    const result = swallowError(io, log, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should work with different return types" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var stringOperation: MockOperation([]const u8) = .{ .value = "string result" };
    var numberOperation: MockOperation(u32) = .{ .value = 42 };
    var objectOperation: MockOperation(KeyValue) = .{ .value = .{ .key = "value" } };

    try std.testing.expectEqualStrings("string result", swallowError(io, log, &stringOperation).?);
    try std.testing.expectEqual(@as(u32, 42), swallowError(io, log, &numberOperation).?);
    try std.testing.expectEqualStrings("value", swallowError(io, log, &objectOperation).?.key);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should handle operations that return undefined" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();

    // (An operation that resolves with undefined returns void, and a succeeded void operation is not null.)
    var operation: MockOperation(void) = .{ .value = {} };

    const result = swallowError(io, log, &operation);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should handle operations that return null" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: MockOperation(?[]const u8) = .{ .value = null };

    const result = swallowError(io, log, &operation);

    try std.testing.expect(result != null);
    try std.testing.expect(result.? == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should handle different error types without logging" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true, .failureMessage = "Custom error message" };

    const result = swallowError(io, log, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

//
// An operation that fails with a Zig error that carries no message (a rejection with a
// value that is not an Error, such as a string).
//
const NonErrorOperation = struct {
    //
    // Runs the operation.
    //
    pub fn run(self: *NonErrorOperation, operationIo: std.Io, _: utils.log.ILog) ![]const u8 {
        _ = self;
        _ = operationIo;
        return error.StringError;
    }
};

test "should handle non-Error objects thrown without logging" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: NonErrorOperation = .{};

    const result = swallowError(io, log, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should not throw errors" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true, .failureMessage = "This should not be thrown" };

    // swallowError returns an optional, not an error union: it cannot throw.
    const result: ?[]const u8 = swallowError(io, log, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

test "should silently handle multiple consecutive failures" {
    var mockLog: ExceptionLog = .{};
    const log = mockLog.ilog();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true };

    const results = [_]?[]const u8{
        swallowError(io, log, &operation),
        swallowError(io, log, &operation),
        swallowError(io, log, &operation),
    };

    for (results) |result| {
        try std.testing.expect(result == null);
    }
    try std.testing.expectEqual(@as(u32, 3), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), mockLog.exceptionCalls);
}

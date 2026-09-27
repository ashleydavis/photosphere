const std = @import("std");
const utils = @import("utils-zig");
const ExceptionLog = @import("exception-log.zig").ExceptionLog;
const swallowError = utils.swallow_error.swallowError;
const errors = utils.errors;

const io = std.testing.io;

//
// An operation that resolves with a value or rejects (the jest.fn() of the TypeScript tests).
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
        pub fn run(self: *@This(), operationIo: std.Io) !ValueT {
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
// A record returned by an operation (TypeScript: `{ key: "value" }`).
//
const KeyValue = struct {
    // The value of the key.
    key: []const u8,
};

test "should return result on success" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success" };

    const result = swallowError(io, &operation);

    try std.testing.expectEqualStrings("success", result.?);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should return undefined and not log error on failure" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true };

    const result = swallowError(io, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should work with different return types" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var stringOperation: MockOperation([]const u8) = .{ .value = "string result" };
    var numberOperation: MockOperation(u32) = .{ .value = 42 };
    var objectOperation: MockOperation(KeyValue) = .{ .value = .{ .key = "value" } };

    try std.testing.expectEqualStrings("string result", swallowError(io, &stringOperation).?);
    try std.testing.expectEqual(@as(u32, 42), swallowError(io, &numberOperation).?);
    try std.testing.expectEqualStrings("value", swallowError(io, &objectOperation).?.key);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should handle operations that return undefined" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();

    // (Zig: an operation that resolves with undefined returns void, and a succeeded void operation is not null.)
    var operation: MockOperation(void) = .{ .value = {} };

    const result = swallowError(io, &operation);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should handle operations that return null" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation(?[]const u8) = .{ .value = null };

    const result = swallowError(io, &operation);

    try std.testing.expect(result != null);
    try std.testing.expect(result.? == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should handle different error types without logging" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true, .failureMessage = "Custom error message" };

    const result = swallowError(io, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

//
// An operation that fails with a Zig error that carries no message (TypeScript: a rejection with a
// value that is not an Error, `mockRejectedValue("String error")`).
//
const NonErrorOperation = struct {
    //
    // Runs the operation.
    //
    pub fn run(self: *NonErrorOperation, operationIo: std.Io) ![]const u8 {
        _ = self;
        _ = operationIo;
        return error.StringError;
    }
};

test "should handle non-Error objects thrown without logging" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: NonErrorOperation = .{};

    const result = swallowError(io, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should not throw errors" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true, .failureMessage = "This should not be thrown" };

    // swallowError returns an optional, not an error union: it cannot throw.
    const result: ?[]const u8 = swallowError(io, &operation);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should silently handle multiple consecutive failures" {
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .fails = true };

    const results = [_]?[]const u8{
        swallowError(io, &operation),
        swallowError(io, &operation),
        swallowError(io, &operation),
    };

    for (results) |result| {
        try std.testing.expect(result == null);
    }
    try std.testing.expectEqual(@as(u32, 3), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

const std = @import("std");
const utils = @import("utils-zig");
const ExceptionLog = @import("exception-log.zig").ExceptionLog;
const tryOrLog = utils.try_or_log.tryOrLog;
const errors = utils.errors;

//
// An operation that returns a value, or fails with an error of the given message.
//
fn MockOperation(comptime ValueT: type) type {
    return struct {
        // The value returned on success.
        value: ValueT,

        // When true every call fails.
        fails: bool = false,

        // The message of the error thrown on failure.
        failureMessage: []const u8 = "Operation failed",

        // Number of times run has been called.
        calls: u32 = 0,

        //
        // Runs the operation.
        //
        pub fn run(self: *@This(), io: std.Io) !ValueT {
            _ = io;
            self.calls += 1;
            if (self.fails) {
                return errors.throwError("{s}", .{self.failureMessage});
            }
            return self.value;
        }
    };
}

//
// An operation that fails with an error that is not a thrown message.
//
const RuntimeErrorOperation = struct {
    // Number of times run has been called.
    calls: u32 = 0,

    //
    // Runs the operation.
    //
    pub fn run(self: *RuntimeErrorOperation, io: std.Io) ![]const u8 {
        _ = io;
        self.calls += 1;
        return error.FileNotFound;
    }
};

test "should return result on success" {
    const io = std.testing.io;
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success" };

    const result = tryOrLog(io, &operation, "");

    try std.testing.expectEqualStrings("success", result.?);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should return null and log error on failure" {
    const io = std.testing.io;
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "unused", .fails = true };

    const result = tryOrLog(io, &operation, "");

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 1), log.exceptionCalls);
    try std.testing.expectEqualStrings("Operation failed", log.lastMessage);
    try std.testing.expectEqual(error.Thrown, log.lastError.?);
}

test "should use custom error message" {
    const io = std.testing.io;
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "unused", .fails = true, .failureMessage = "Something went wrong" };

    const result = tryOrLog(io, &operation, "Custom error message");

    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("Custom error message", log.lastMessage);
}

test "should work with different return types" {
    const io = std.testing.io;
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var string_operation: MockOperation([]const u8) = .{ .value = "string result" };
    var number_operation: MockOperation(u32) = .{ .value = 42 };
    var object_operation: MockOperation(struct { key: []const u8 }) = .{ .value = .{ .key = "value" } };

    try std.testing.expectEqualStrings("string result", tryOrLog(io, &string_operation, "").?);
    try std.testing.expectEqual(@as(u32, 42), tryOrLog(io, &number_operation, "").?);
    try std.testing.expectEqualStrings("value", tryOrLog(io, &object_operation, "").?.key);
}

test "should handle operations that return nothing" {
    const io = std.testing.io;
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation(?u32) = .{ .value = null };

    const result = tryOrLog(io, &operation, "");

    try std.testing.expect(result != null);
    try std.testing.expect(result.? == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should handle different error types" {
    const io = std.testing.io;
    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: RuntimeErrorOperation = .{};

    const result = tryOrLog(io, &operation, "");

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), log.exceptionCalls);
    try std.testing.expectEqualStrings("Operation failed", log.lastMessage);
    try std.testing.expectEqual(error.FileNotFound, log.lastError.?);
}

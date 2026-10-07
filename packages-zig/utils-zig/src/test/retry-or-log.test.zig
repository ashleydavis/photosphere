const std = @import("std");
const utils = @import("utils-zig");
const ExceptionLog = @import("exception-log.zig").ExceptionLog;
const retryOrLog = utils.retry_or_log.retryOrLog;
const errors = utils.errors;
const virtual_time_io = @import("virtual-time-io.zig");

//
// An operation that fails a number of times and then resolves (the jest.fn() of the TypeScript tests).
//
fn MockOperation(comptime ValueT: type) type {
    return struct {
        // The value resolved with.
        value: ValueT,

        // Number of calls that fail before the operation succeeds.
        failuresBeforeSuccess: u32 = 0,

        // When true every call fails.
        alwaysFails: bool = false,

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
            if (self.alwaysFails or self.calls <= self.failuresBeforeSuccess) {
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

//
// Gets the elapsed milliseconds since `start` (TypeScript mocks sleep and checks what it was called
// with; Zig measures how long the sleeps took on the virtual clock).
//
fn elapsedMilliseconds(io: std.Io, start: std.Io.Timestamp) i64 {
    return start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

test "should return result on first attempt" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success" };
    const start = std.Io.Clock.awake.now(io);

    const result = try retryOrLog(io, &operation, "Test error", 3, 10_000, 2);

    try std.testing.expectEqualStrings("success", result.?);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) < 10_000);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should return result after retries" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success", .failuresBeforeSuccess = 2 };
    const start = std.Io.Clock.awake.now(io);

    const result = try retryOrLog(io, &operation, "Test error", 3, 100, 2);

    try std.testing.expectEqualStrings("success", result.?);
    try std.testing.expectEqual(@as(u32, 3), operation.calls);

    // Two sleeps, of 100ms and 200ms.
    try std.testing.expect(elapsedMilliseconds(io, start) >= 300);
    try std.testing.expectEqual(@as(u32, 2), log.exceptionCalls);
}

test "should return undefined and log error after all retries exhausted" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    const result = try retryOrLog(io, &operation, "Test error", 3, 100, 2);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 3), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) >= 300);
    try std.testing.expectEqual(@as(u32, 3), log.exceptionCalls); // 2 retries + 1 final failure
    try std.testing.expectEqualStrings("Test error", log.lastMessage);
    try std.testing.expectEqualStrings("Operation failed", errors.errorMessage(log.lastError.?));
}

test "should use custom error message" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true };

    const result = try retryOrLog(io, &operation, "Custom error message", 2, 100, 2);

    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("Custom error message", log.lastMessage);
}

test "an empty error message is the same as none, which is how TypeScript reads it" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true };

    const result = try retryOrLog(io, &operation, "", 1, 100, 2);

    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("Operation failed after all retries", log.lastMessage);
}

test "should use default maxAttempts of 3" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    // (Zig has no default parameters: the TypeScript defaults are passed.)
    _ = try retryOrLog(io, &operation, "Test error", 3, 1, 2);

    try std.testing.expectEqual(@as(u32, 3), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) >= 3);
}

test "should use default waitTimeMS of 1000" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success", .failuresBeforeSuccess = 1 };
    const start = std.Io.Clock.awake.now(io);

    _ = try retryOrLog(io, &operation, "Test error", 2, 1000, 2);

    try std.testing.expectEqual(@as(u32, 2), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) >= 1000);
}

test "should use default waitTimeScale of 2" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success", .failuresBeforeSuccess = 2 };
    const start = std.Io.Clock.awake.now(io);

    _ = try retryOrLog(io, &operation, "Test error", 3, 100, 2);

    try std.testing.expectEqual(@as(u32, 3), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) >= 300);
}

test "should work with custom waitTimeScale" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success", .failuresBeforeSuccess = 2 };
    const start = std.Io.Clock.awake.now(io);

    _ = try retryOrLog(io, &operation, "Test error", 3, 100, 3);

    try std.testing.expectEqual(@as(u32, 3), operation.calls);

    // Two sleeps, of 100ms and 300ms.
    try std.testing.expect(elapsedMilliseconds(io, start) >= 400);
}

test "should not sleep on last attempt" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    // A scale large enough that a sleep after the last attempt could not go unnoticed.
    _ = try retryOrLog(io, &operation, "Test error", 2, 100, 100);

    try std.testing.expectEqual(@as(u32, 2), operation.calls);

    // One sleep of 100ms (a sleep after the last attempt would add 10000ms).
    const elapsed = elapsedMilliseconds(io, start);
    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 10_000);
    try std.testing.expectEqual(@as(u32, 2), log.exceptionCalls); // 1 retry + 1 final failure
}

test "should return undefined immediately when maxAttempts is 1" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    const result = try retryOrLog(io, &operation, "Test error", 1, 10_000, 2);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) < 10_000);
    try std.testing.expectEqual(@as(u32, 1), log.exceptionCalls);
    try std.testing.expectEqualStrings("Test error", log.lastMessage);
}

test "should return undefined when maxAttempts is 0" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "success" };

    const result = try retryOrLog(io, &operation, "Test error", 0, 1000, 2);

    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 0), operation.calls);
    try std.testing.expectEqual(@as(u32, 0), log.exceptionCalls);
}

test "should preserve error type in log" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true, .failureMessage = "Custom error message" };

    _ = try retryOrLog(io, &operation, "Test error", 1, 1000, 2);

    try std.testing.expectEqualStrings("Test error", log.lastMessage);
    try std.testing.expectEqual(error.Thrown, log.lastError.?);
    try std.testing.expectEqualStrings("Custom error message", errors.errorMessage(log.lastError.?));
}

test "should work with different return types" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var stringOperation: MockOperation([]const u8) = .{ .value = "string result" };
    var numberOperation: MockOperation(u32) = .{ .value = 42 };
    var objectOperation: MockOperation(KeyValue) = .{ .value = .{ .key = "value" } };

    try std.testing.expectEqualStrings("string result", (try retryOrLog(io, &stringOperation, "Test error", 3, 1000, 2)).?);
    try std.testing.expectEqual(@as(u32, 42), (try retryOrLog(io, &numberOperation, "Test error", 3, 1000, 2)).?);
    try std.testing.expectEqualStrings("value", (try retryOrLog(io, &objectOperation, "Test error", 3, 1000, 2)).?.key);
}

test "should handle operations that return undefined" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();

    // (Zig: an operation that resolves with undefined returns void, and a succeeded void operation is not null.)
    var operation: MockOperation(void) = .{ .value = {} };

    const result = try retryOrLog(io, &operation, "Test error", 3, 1000, 2);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
}

test "should not throw errors" {
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.init(std.testing.allocator);
    defer virtual_time.deinit();
    const io = virtual_time.io();

    var log: ExceptionLog = .{};
    log.install();
    defer log.uninstall();
    var operation: MockOperation([]const u8) = .{ .value = "", .alwaysFails = true, .failureMessage = "This should not be thrown" };

    const result = try retryOrLog(io, &operation, "Test error", 1, 1000, 2);

    try std.testing.expect(result == null);
    try std.testing.expect(log.exceptionCalls > 0);
}

const std = @import("std");
const utils = @import("utils-zig");
const retry_module = utils.retry;
const errors = utils.errors;
const console = utils.console;

//
// A fake operation (the jest.fn() of the TypeScript tests): fails a number of times, then succeeds.
//
const MockOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "async () => {\n  await operation();\n}";

    // Number of times run has been called.
    calls: u32 = 0,

    // Number of calls that fail before the operation succeeds.
    failuresBeforeSuccess: u32 = 0,

    // When true every call fails.
    alwaysFails: bool = false,

    // When true the failure is a FatalError instead of a plain Error.
    failsWithFatalError: bool = false,

    // When true the operation never completes (until canceled).
    neverResolves: bool = false,

    // The message of the error thrown on failure.
    failureMessage: []const u8 = "Operation failed",

    // The value returned on success.
    result: []const u8 = "success",

    //
    // Runs the operation.
    //
    pub fn run(self: *MockOperation, io: std.Io) ![]const u8 {
        self.calls += 1;
        if (self.neverResolves) {
            try io.sleep(.fromSeconds(3600), .awake);
        }
        if (self.alwaysFails or self.calls <= self.failuresBeforeSuccess) {
            if (self.failsWithFatalError) {
                return errors.throwFatalError("{s}", .{self.failureMessage});
            }
            return errors.throwError("{s}", .{self.failureMessage});
        }
        return self.result;
    }
};

//
// An operation that returns a number.
//
const NumberOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "() => operation()";

    // The value returned.
    value: u32,

    //
    // Runs the operation.
    //
    pub fn run(self: *NumberOperation, io: std.Io) !u32 {
        _ = io;
        return self.value;
    }
};

//
// An operation that returns nothing (TypeScript: resolves with undefined).
//
const VoidOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "() => operation()";

    // Number of times run has been called.
    calls: u32 = 0,

    //
    // Runs the operation.
    //
    pub fn run(self: *VoidOperation, io: std.Io) !void {
        _ = io;
        self.calls += 1;
    }
};

//
// An operation that fails with a Zig runtime error rather than a thrown message.
//
const RuntimeErrorOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "() => operation()";

    // Unused.
    unused: u8 = 0,

    //
    // Runs the operation.
    //
    pub fn run(self: *RuntimeErrorOperation, io: std.Io) ![]const u8 {
        _ = self;
        _ = io;
        return error.FileNotFound;
    }
};

//
// An operation that fails with each of a sequence of messages in turn, then succeeds.
//
const SequenceOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "() => operation()";

    // Number of times run has been called.
    calls: usize = 0,

    // The message of the error thrown by each failing call, in order.
    failureMessages: []const []const u8,

    //
    // Runs the operation.
    //
    pub fn run(self: *SequenceOperation, io: std.Io) ![]const u8 {
        _ = io;
        self.calls += 1;
        if (self.calls <= self.failureMessages.len) {
            return errors.throwError("{s}", .{self.failureMessages[self.calls - 1]});
        }
        return "success";
    }
};

//
// An operation that never completes and whose source is longer than 200 characters once its
// whitespace is collapsed.
//
const LongSourceOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "() =>" ++ ("\n   x" ** 120);

    // Unused.
    unused: u8 = 0,

    //
    // Runs the operation.
    //
    pub fn run(self: *LongSourceOperation, io: std.Io) ![]const u8 {
        _ = self;
        try io.sleep(.fromSeconds(3600), .awake);
        return "never";
    }
};

//
// An operation that keeps its thread busy for a while without reaching a cancelation point
// (TypeScript: synchronous work, which no timer can interrupt).
//
const BusyOperation = struct {
    // The Bun toString() of the TypeScript operation this stands in for (read by retryOnce).
    pub const source = "() => operation()";

    // How long the operation keeps busy, in milliseconds.
    busyMilliseconds: i64,

    //
    // Runs the operation.
    //
    pub fn run(self: *BusyOperation, io: std.Io) ![]const u8 {
        const start = std.Io.Clock.awake.now(io);
        while (elapsedMilliseconds(io, start) < self.busyMilliseconds) {
            std.atomic.spinLoopHint();
        }
        return "finished";
    }
};

//
// Gets the elapsed milliseconds since `start`.
//
fn elapsedMilliseconds(io: std.Io, start: std.Io.Timestamp) i64 {
    return start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

//
// Captures console.error output for the duration of a test.
//
const StderrCapture = struct {
    // Receives the captured output.
    allocating: std.Io.Writer.Allocating,

    //
    // Starts capturing.
    //
    fn begin(self: *StderrCapture) void {
        self.allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        console.setCapture(null, &self.allocating.writer);
    }

    //
    // Stops capturing and frees the output.
    //
    fn end(self: *StderrCapture) void {
        console.setCapture(null, null);
        self.allocating.deinit();
    }
};

test "should succeed on first attempt" {
    const io = std.testing.io;
    var operation: MockOperation = .{};
    const start = std.Io.Clock.awake.now(io);

    // A wait long enough that a sleep could not go unnoticed on a slow machine
    // (TypeScript mocks sleep and counts the calls instead).
    const result = try retry_module.retry(io, &operation, 3, 10_000, 2, 30_000, null);

    try std.testing.expectEqualStrings("success", result);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) < 10_000);
}

test "should succeed after retries" {
    const io = std.testing.io;
    var operation: MockOperation = .{ .failuresBeforeSuccess = 2 };
    const start = std.Io.Clock.awake.now(io);

    const result = try retry_module.retry(io, &operation, 3, 20, 2, 30_000, null);

    try std.testing.expectEqualStrings("success", result);
    try std.testing.expectEqual(@as(u32, 3), operation.calls);

    // Slept for 20ms then 40ms.
    try std.testing.expect(elapsedMilliseconds(io, start) >= 60);
}

test "should throw error after all retries exhausted" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 3, 20, 2, 30_000, null));

    try std.testing.expectEqualStrings("Operation failed", errors.lastErrorMessage());
    try std.testing.expectEqual(@as(u32, 3), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) >= 60);
    try std.testing.expect(std.mem.indexOf(u8, capture.allocating.written(), "Operation failed, no more retries allowed. Last error:") != null);
}

test "should use default maxAttempts of 3" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .alwaysFails = true };

    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 3, 1, 2, 30_000, null));

    try std.testing.expectEqualStrings("Operation failed", errors.lastErrorMessage());
    try std.testing.expectEqual(@as(u32, 3), operation.calls);
}

test "should use default waitTimeMS of 1000" {
    const io = std.testing.io;
    var operation: MockOperation = .{ .failuresBeforeSuccess = 1 };
    const start = std.Io.Clock.awake.now(io);

    _ = try retry_module.retry(io, &operation, 2, 1_000, 2, 30_000, null);

    try std.testing.expectEqual(@as(u32, 2), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) >= 1_000);
}

test "should use default waitTimeScale of 2" {
    const io = std.testing.io;
    var operation: MockOperation = .{ .failuresBeforeSuccess = 2 };
    const start = std.Io.Clock.awake.now(io);

    _ = try retry_module.retry(io, &operation, 3, 100, 2, 30_000, null);

    // Slept for 100ms then 200ms.
    try std.testing.expect(elapsedMilliseconds(io, start) >= 300);
}

test "should work with custom waitTimeScale" {
    const io = std.testing.io;
    var operation: MockOperation = .{ .failuresBeforeSuccess = 2 };
    const start = std.Io.Clock.awake.now(io);

    _ = try retry_module.retry(io, &operation, 3, 100, 3, 30_000, null);

    // Slept for 100ms then 300ms.
    try std.testing.expect(elapsedMilliseconds(io, start) >= 400);
}

test "should not sleep on last attempt" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    // A scale large enough that a sleep after the last attempt could not go unnoticed on a slow machine
    // (TypeScript mocks sleep and counts the calls instead).
    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 2, 100, 100, 30_000, null));

    try std.testing.expectEqual(@as(u32, 2), operation.calls);

    // Only one sleep of 100ms (a sleep after the last attempt would add 10000ms).
    const elapsed = elapsedMilliseconds(io, start);
    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 10_100);
}

test "should throw error immediately when maxAttempts is 1" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .alwaysFails = true };
    const start = std.Io.Clock.awake.now(io);

    // A wait long enough that a sleep could not go unnoticed on a slow machine
    // (TypeScript mocks sleep and counts the calls instead).
    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 1, 10_000, 2, 30_000, null));

    try std.testing.expectEqualStrings("Operation failed", errors.lastErrorMessage());
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
    try std.testing.expect(elapsedMilliseconds(io, start) < 10_000);
    try std.testing.expectEqualStrings("Operation failed, no more retries allowed. Last error: Error: Operation failed\n", capture.allocating.written());
}

test "should throw expected error when maxAttempts is 0" {
    const io = std.testing.io;
    var operation: MockOperation = .{};

    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 0, 1_000, 2, 30_000, null));

    try std.testing.expectEqualStrings("Expected there to be an error!", errors.lastErrorMessage());
    try std.testing.expectEqual(@as(u32, 0), operation.calls);
}

test "should preserve error type and message" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .alwaysFails = true, .failsWithFatalError = true, .failureMessage = "Custom error message" };

    try std.testing.expectError(error.FatalError, retry_module.retry(io, &operation, 1, 1_000, 2, 30_000, null));
    try std.testing.expectEqualStrings("Custom error message", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("FatalError", errors.lastErrorName());
}

test "should work with different return types" {
    const io = std.testing.io;
    var string_operation: MockOperation = .{ .result = "string result" };
    var number_operation: NumberOperation = .{ .value = 42 };

    try std.testing.expectEqualStrings("string result", try retry_module.retry(io, &string_operation, 3, 1_000, 2, 30_000, null));
    try std.testing.expectEqual(@as(u32, 42), try retry_module.retry(io, &number_operation, 3, 1_000, 2, 30_000, null));
}

test "should handle operations that return undefined" {
    const io = std.testing.io;
    var operation: VoidOperation = .{};

    try retry_module.retry(io, &operation, 3, 1_000, 2, 30_000, null);

    try std.testing.expectEqual(@as(u32, 1), operation.calls);
}

test "should retry when operation times out" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .neverResolves = true };

    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 3, 100, 2, 50, null));

    try std.testing.expectEqualStrings("Operation timed out after 50ms: async () => { await operation(); }", errors.lastErrorMessage());
    try std.testing.expectEqual(@as(u32, 3), operation.calls);
}

test "should succeed if operation completes before timeout" {
    const io = std.testing.io;
    var operation: MockOperation = .{};

    const result = try retry_module.retry(io, &operation, 3, 100, 2, 50, null);

    try std.testing.expectEqualStrings("success", result);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
}

test "should wrap error with errorContext when provided" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: MockOperation = .{ .alwaysFails = true, .failureMessage = "original error" };

    const result = retry_module.retry(io, &operation, 1, 100, 2, 30_000, "context message");

    try std.testing.expectError(error.Thrown, result);
    try std.testing.expect(utils.wrapped_error.WrappedError.isInstance(error.Thrown));
    try std.testing.expectEqualStrings("context message: original error", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("original error", errors.lastErrorCauseMessage());
}

test "should wrap a runtime error with errorContext" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: RuntimeErrorOperation = .{};

    try std.testing.expectError(error.Thrown, retry_module.retry(io, &operation, 1, 100, 2, 30_000, "context message"));

    try std.testing.expectEqualStrings("context message: FileNotFound", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("FileNotFound", errors.lastErrorCauseMessage());
}

test "should throw original error when errorContext is not provided" {
    const io = std.testing.io;
    var capture: StderrCapture = undefined;
    capture.begin();
    defer capture.end();
    var operation: RuntimeErrorOperation = .{};

    try std.testing.expectError(error.FileNotFound, retry_module.retry(io, &operation, 1, 1_000, 2, 30_000, null));
}

test "retryOnce should resolve with the operation result" {
    const io = std.testing.io;
    var operation: MockOperation = .{};

    const result = try retry_module.retryOnce(io, &operation, 1_000);

    try std.testing.expectEqualStrings("success", result);
    try std.testing.expectEqual(@as(u32, 1), operation.calls);
}

test "retryOnce should reject with the operation error" {
    const io = std.testing.io;
    var operation: MockOperation = .{ .alwaysFails = true, .failureMessage = "operation failed" };

    try std.testing.expectError(error.Thrown, retry_module.retryOnce(io, &operation, 1_000));

    try std.testing.expectEqualStrings("operation failed", errors.lastErrorMessage());
}

test "retryOnce should reject with timeout error when operation exceeds timeoutMS" {
    const io = std.testing.io;
    var operation: MockOperation = .{ .neverResolves = true };

    try std.testing.expectError(error.Thrown, retry_module.retryOnce(io, &operation, 50));

    try std.testing.expectEqualStrings("Operation timed out after 50ms: async () => { await operation(); }", errors.lastErrorMessage());
}

test "retryOnce should resolve with correct value when operation completes before timeout" {
    const io = std.testing.io;
    var operation: NumberOperation = .{ .value = 42 };

    const result = try retry_module.retryOnce(io, &operation, 50);

    try std.testing.expectEqual(@as(u32, 42), result);
}

test "retryOnce resolves with the result of an operation that finishes without awaiting after the timeout" {
    const io = std.testing.io;
    var operation: BusyOperation = .{ .busyMilliseconds = 200 };

    const result = try retry_module.retryOnce(io, &operation, 20);

    try std.testing.expectEqualStrings("finished", result);
}

//
// A log that keeps the verbose messages and warnings it receives.
//
const VerboseLog = struct {
    // The verbose messages received, one per line.
    messages: std.Io.Writer.Allocating,

    // The warnings received, one per line.
    warnings: std.Io.Writer.Allocating,

    // Whether verbose logging is enabled (log.verboseEnabled).
    verbose_enabled: bool,

    //
    // Gets the ILog interface for this log.
    //
    fn ilog(self: *VerboseLog) utils.log.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log: only verbose, warn and verboseEnabled do anything.
    //
    const vtable: utils.log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = verbose,
        .@"error" = ignoreMessage,
        .exception = ignoreException,
        .warn = warn,
        .debug = ignoreMessage,
        .tool = ignoreTool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
    };

    //
    // Keeps a verbose message.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        const self: *VerboseLog = @ptrCast(@alignCast(ptr));
        self.messages.writer.writeAll(message) catch {};
        self.messages.writer.writeByte('\n') catch {};
    }

    //
    // Ignores a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Ignores an exception.
    //
    fn ignoreException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        _ = message;
        _ = @errorName(err);
    }

    //
    // Ignores tool output.
    //
    fn ignoreTool(ptr: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
        _ = ptr;
        _ = toolName;
        _ = data;
    }

    //
    // Returns whether verbose logging is enabled.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *VerboseLog = @ptrCast(@alignCast(ptr));
        return self.verbose_enabled;
    }

    //
    // Keeps a warning.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        const self: *VerboseLog = @ptrCast(@alignCast(ptr));
        self.warnings.writer.writeAll(message) catch {};
        self.warnings.writer.writeByte('\n') catch {};
    }

    //
    // Returns no log details.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return utils.log.noLogDetails;
    }
};
test "should log the error of a failed attempt when verbose logging is enabled" {
    const io = std.testing.io;
    var verbose_log: VerboseLog = .{
        .messages = std.Io.Writer.Allocating.init(std.testing.allocator),
        .warnings = std.Io.Writer.Allocating.init(std.testing.allocator),
        .verbose_enabled = true,
    };
    defer verbose_log.messages.deinit();
    defer verbose_log.warnings.deinit();
    const original_log = utils.log.log;
    utils.log.setLog(verbose_log.ilog());
    defer utils.log.setLog(original_log);
    var operation: MockOperation = .{ .failuresBeforeSuccess = 1, .failureMessage = "First \"failure\"" };

    _ = try retry_module.retry(io, &operation, 2, 1, 2, 30_000, null);

    try std.testing.expectEqualStrings(
        "Error: {\n  \"name\": \"Error\",\n  \"message\": \"First \\\"failure\\\"\"\n}\n",
        verbose_log.messages.written(),
    );
}

//
// Every attempt that is going to be tried again says why it failed, once, in one line.
//
// Only the last attempt's error used to be reported, and at verbose level nothing else was said
// at all. A failure that takes three attempts and a minute and a half then looks like a single
// event with a single cause, which is how an upload whose first attempt failed one way and whose
// retries failed another went undiagnosed on a phone.
//
test "each attempt that will be tried again says what went wrong" {
    const io = std.testing.io;
    var warn_log: VerboseLog = .{
        .messages = std.Io.Writer.Allocating.init(std.testing.allocator),
        .warnings = std.Io.Writer.Allocating.init(std.testing.allocator),
        .verbose_enabled = false,
    };
    defer warn_log.messages.deinit();
    defer warn_log.warnings.deinit();
    const original_log = utils.log.log;
    utils.log.setLog(warn_log.ilog());
    defer utils.log.setLog(original_log);
    var operation: SequenceOperation = .{ .failureMessages = &.{ "First failure", "Second failure" } };

    const result = try retry_module.retry(io, &operation, 3, 1, 2, 30_000, "Failed to copy a file");

    try std.testing.expectEqualStrings("success", result);
    try std.testing.expectEqualStrings(
        "Failed to copy a file. Retrying after: First failure\nFailed to copy a file. Retrying after: Second failure\n",
        warn_log.warnings.written(),
    );
    try std.testing.expectEqualStrings("", warn_log.messages.written());
}

test "a retried attempt without errorContext says an operation failed" {
    const io = std.testing.io;
    var warn_log: VerboseLog = .{
        .messages = std.Io.Writer.Allocating.init(std.testing.allocator),
        .warnings = std.Io.Writer.Allocating.init(std.testing.allocator),
        .verbose_enabled = false,
    };
    defer warn_log.messages.deinit();
    defer warn_log.warnings.deinit();
    const original_log = utils.log.log;
    utils.log.setLog(warn_log.ilog());
    defer utils.log.setLog(original_log);
    var operation: MockOperation = .{ .failuresBeforeSuccess = 1, .failureMessage = "First failure" };

    _ = try retry_module.retry(io, &operation, 2, 1, 2, 30_000, null);

    try std.testing.expectEqualStrings("An operation failed. Retrying after: First failure\n", warn_log.warnings.written());
}

test "retryOnce collapses whitespace in the operation source and keeps its first 200 characters" {
    const io = std.testing.io;
    var operation: LongSourceOperation = .{};

    try std.testing.expectError(error.Thrown, retry_module.retryOnce(io, &operation, 10));

    const expected_source = "() =>" ++ (" x" ** 97) ++ " ";
    try std.testing.expectEqual(@as(usize, 200), expected_source.len);
    try std.testing.expectEqualStrings("Operation timed out after 10ms: " ++ expected_source, errors.lastErrorMessage());
}

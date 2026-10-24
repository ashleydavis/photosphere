const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;
const thread_messages = @import("thread-messages.zig");
const MessageQueue = thread_messages.MessageQueue;
const ThreadAllocator = thread_messages.ThreadAllocator;

//
// Helper that throws a plain error.
//
fn failWithValue(value: u32) !void {
    return errors.throwError("Failed with value {d}", .{value});
}

test "throwError records the formatted message" {
    errors.clearError();
    try std.testing.expectError(error.Thrown, failWithValue(42));
    try std.testing.expectEqualStrings("Failed with value 42", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Error", errors.lastErrorName());
}

test "throwStacklessError records the message under no name" {
    errors.clearError();
    const result: errors.ThrownError!void = errors.throwStacklessError("Missing {s}", .{"file"});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Missing file", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("", errors.lastErrorName());
}

test "throwFatalError records a FatalError" {
    errors.clearError();
    const result: errors.FatalErrorSet!void = errors.throwFatalError("Fatal {s}", .{"problem"});
    try std.testing.expectError(error.FatalError, result);
    try std.testing.expectEqualStrings("Fatal problem", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("FatalError", errors.lastErrorName());
}

test "throwWrappedError keeps the previous message as the cause" {
    errors.clearError();
    failWithValue(1) catch {};
    const result: errors.ThrownError!void = errors.throwWrappedError("Context", .{});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Context: Failed with value 1", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Failed with value 1", errors.lastErrorCauseMessage());
    try std.testing.expectEqualStrings("WrappedError", errors.lastErrorName());
}

test "throwWrappedError does not fold in an empty cause message" {
    errors.clearError();
    errors.throwWrappedError("Context", .{}) catch {};
    try std.testing.expectEqualStrings("Context", errors.lastErrorMessage());
}

test "throwErrorWithCause keeps the previous error as the cause without folding in its message" {
    errors.clearError();
    failWithValue(3) catch {};
    const result: errors.ThrownError!void = errors.throwErrorWithCause("Context", .{});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Context", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Failed with value 3", errors.lastErrorCauseMessage());
    try std.testing.expectEqualStrings("Error", errors.lastErrorName());
}

test "errorMessage returns the error name for runtime errors" {
    try std.testing.expectEqualStrings("FileNotFound", errors.errorMessage(error.FileNotFound));
}

test "errorMessage returns the recorded message for thrown errors" {
    failWithValue(7) catch |err| {
        try std.testing.expectEqualStrings("Failed with value 7", errors.errorMessage(err));
    };
}

test "throwWrappedError keeps the whole cause chain" {
    errors.clearError();
    failWithValue(1) catch {};
    errors.throwWrappedError("Middle", .{}) catch {};
    errors.throwWrappedError("Outer", .{}) catch {};
    try std.testing.expectEqualStrings("Outer: Middle: Failed with value 1", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Middle: Failed with value 1", errors.lastErrorCauseMessage());
    var cause_chain = errors.lastErrorCauseChain();
    try std.testing.expectEqualStrings("Middle: Failed with value 1", cause_chain.next().?);
    try std.testing.expectEqualStrings("Failed with value 1", cause_chain.next().?);
    try std.testing.expect(cause_chain.next() == null);
}

test "lastErrorCauseChain is empty when there is no cause" {
    failWithValue(2) catch {};
    var cause_chain = errors.lastErrorCauseChain();
    try std.testing.expect(cause_chain.next() == null);
}

//
// A captured error as it crosses from one thread to another: the parts of an ErrorRecord, as JSON.
//
const CapturedError = struct {
    message: []const u8,
    causes: []const u8,
    name: []const u8,
    cause_names: []const []const u8,
};

//
// Throws an error on a thread of its own, captures it with its own allocator and Io and posts it to the test as a CapturedError.
//
fn throwOnThread(captured: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    failWithValue(99) catch {};
    var record: errors.ErrorRecord = .{};
    errors.captureError(&record);
    thread_messages.post(captured, threaded.io(), thread_allocator.allocator(), CapturedError{
        .message = record.message_buffer[0..record.message_length],
        .causes = record.cause_buffer[0..record.cause_length],
        .name = record.name,
        .cause_names = record.cause_names[0..record.cause_name_count],
    }) catch @panic("out of memory posting the captured error");
}

test "captureError and restoreError move an error between threads" {
    errors.clearError();
    // The restored error's names are in this arena, so the error is cleared before it is freed.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    defer errors.clearError();
    var captured = MessageQueue.init();
    defer captured.deinit();
    const thread = try std.Thread.spawn(.{}, throwOnThread, .{&captured});
    thread.join();
    const parts = try thread_messages.take(CapturedError, &captured, std.testing.io, arena.allocator());
    var record: errors.ErrorRecord = .{
        .message_length = parts.message.len,
        .cause_length = parts.causes.len,
        .name = parts.name,
        .cause_name_count = parts.cause_names.len,
    };
    @memcpy(record.message_buffer[0..parts.message.len], parts.message);
    @memcpy(record.cause_buffer[0..parts.causes.len], parts.causes);
    @memcpy(record.cause_names[0..parts.cause_names.len], parts.cause_names);
    try std.testing.expectEqualStrings("", errors.lastErrorMessage());
    errors.restoreError(&record);
    try std.testing.expectEqualStrings("Failed with value 99", errors.lastErrorMessage());
}

test "lastErrorCauseNames names each cause of the chain, nearest first" {
    errors.clearError();
    errors.throwFatalError("root", .{}) catch {};
    errors.throwWrappedError("Middle", .{}) catch {};
    errors.throwErrorWithCause("Outer", .{}) catch {};
    const cause_names = errors.lastErrorCauseNames();
    try std.testing.expectEqual(@as(usize, 2), cause_names.len);
    try std.testing.expectEqualStrings("WrappedError", cause_names[0]);
    try std.testing.expectEqualStrings("FatalError", cause_names[1]);

    // A new error without a cause has none.
    failWithValue(3) catch {};
    try std.testing.expectEqual(@as(usize, 0), errors.lastErrorCauseNames().len);
}

test "errorToString gives String(error): the name JavaScript gives the error and its message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    errors.recordError("RangeError", "stdout maxBuffer length exceeded", .{});
    try std.testing.expectEqualStrings("RangeError: stdout maxBuffer length exceeded", try errors.errorToString(allocator, error.Thrown));

    try std.testing.expectEqual(error.FatalError, errors.throwFatalError("No database", .{}));
    try std.testing.expectEqualStrings("FatalError: No database", try errors.errorToString(allocator, error.FatalError));

    // A WrappedError sets no name, so it is an Error; so is an error without a stack.
    try std.testing.expectEqual(error.Thrown, errors.throwWrappedError("Outer", .{}));
    try std.testing.expectEqualStrings("Error: Outer: No database", try errors.errorToString(allocator, error.Thrown));
    try std.testing.expectEqual(error.Thrown, errors.throwStacklessError("stream closed", .{}));
    try std.testing.expectEqualStrings("Error: stream closed", try errors.errorToString(allocator, error.Thrown));

    // A runtime error is an Error with the Zig error name as its message, and an empty message leaves the name alone.
    try std.testing.expectEqualStrings("Error: FileNotFound", try errors.errorToString(allocator, error.FileNotFound));
    errors.recordError("TypeError", "", .{});
    try std.testing.expectEqualStrings("TypeError", try errors.errorToString(allocator, error.Thrown));
}

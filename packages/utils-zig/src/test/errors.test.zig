const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

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
    try std.testing.expectEqualStrings("Context", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Failed with value 1", errors.lastErrorCauseMessage());
    try std.testing.expectEqualStrings("WrappedError", errors.lastErrorName());
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
    try std.testing.expectEqualStrings("Outer", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("Middle", errors.lastErrorCauseMessage());
    var cause_chain = errors.lastErrorCauseChain();
    try std.testing.expectEqualStrings("Middle", cause_chain.next().?);
    try std.testing.expectEqualStrings("Failed with value 1", cause_chain.next().?);
    try std.testing.expect(cause_chain.next() == null);
}

test "lastErrorCauseChain is empty when there is no cause" {
    failWithValue(2) catch {};
    var cause_chain = errors.lastErrorCauseChain();
    try std.testing.expect(cause_chain.next() == null);
}

//
// Throws an error on another thread and captures it.
//
fn throwOnThread(record: *errors.ErrorRecord) void {
    failWithValue(99) catch {};
    errors.captureError(record);
}

test "captureError and restoreError move an error between threads" {
    errors.clearError();
    const record = try std.testing.allocator.create(errors.ErrorRecord);
    defer std.testing.allocator.destroy(record);
    const thread = try std.Thread.spawn(.{}, throwOnThread, .{record});
    thread.join();
    try std.testing.expectEqualStrings("", errors.lastErrorMessage());
    errors.restoreError(record);
    try std.testing.expectEqualStrings("Failed with value 99", errors.lastErrorMessage());
}

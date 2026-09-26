const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;
const wrapped_error = utils.wrapped_error;
const WrappedError = wrapped_error.WrappedError;

//
// Throws a plain error with the given message.
//
fn throwOriginal(message: []const u8) errors.ThrownError!void {
    return errors.throwError("{s}", .{message});
}

//
// Wraps the most recent error in a WrappedError with the given message.
//
fn throwWrapped(message: []const u8) errors.ThrownError!void {
    return WrappedError.throw("{s}", .{message});
}

//
// Throws `root`, wraps it in `middle`, then wraps that in `outer`.
//
fn throwThreeLevels() errors.ThrownError!void {
    throwOriginal("root") catch {
        WrappedError.throw("middle", .{}) catch {
            return WrappedError.throw("outer", .{});
        };
    };
}

//
// Throws `root cause` wrapped in `outer`.
//
fn throwTwoLevels() errors.ThrownError!void {
    throwOriginal("root cause") catch {
        return WrappedError.throw("outer", .{});
    };
}

test "the message carries the context and the cause, because somewhere the message is all that survives" {
    throwOriginal("original") catch {};
    const result: errors.ThrownError!void = WrappedError.throw("context", .{});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("context: original", errors.lastErrorMessage());
}

test "should set cause on the standard cause property" {
    throwOriginal("original") catch {};
    throwWrapped("context") catch {};
    try std.testing.expectEqualStrings("original", errors.lastErrorCauseMessage());
}

test "should be an instance of Error" {
    throwOriginal("original") catch {};
    throwWrapped("context") catch |err| {
        try std.testing.expectEqual(error.Thrown, err);
    };
}

test "should be an instance of WrappedError" {
    throwOriginal("original") catch {};
    throwWrapped("context") catch |err| {
        try std.testing.expect(WrappedError.isInstance(err));
    };
    throwOriginal("plain") catch |err| {
        try std.testing.expect(!WrappedError.isInstance(err));
    };
}

test "should format a single error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    throwOriginal("something went wrong") catch |err| {
        const result = try wrapped_error.formatErrorChain(arena.allocator(), err);
        try std.testing.expect(std.mem.indexOf(u8, result, "something went wrong") != null);
    };
}

test "should include cause in output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    throwTwoLevels() catch |err| {
        const result = try wrapped_error.formatErrorChain(arena.allocator(), err);
        try std.testing.expect(std.mem.indexOf(u8, result, "outer") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "root cause") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "Caused by:") != null);
    };
}

test "should traverse multiple levels of cause chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    throwThreeLevels() catch |err| {
        const result = try wrapped_error.formatErrorChain(arena.allocator(), err);
        try std.testing.expectEqualStrings("Error: outer: middle: root\nCaused by:\nError: middle: root\nCaused by:\nError: root", result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "Caused by:"));
    };
}

test "should not append Caused by: after the last error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    throwTwoLevels() catch |err| {
        const result = try wrapped_error.formatErrorChain(arena.allocator(), err);
        try std.testing.expect(!std.mem.endsWith(u8, std.mem.trimEnd(u8, result, " \n"), "Caused by:"));
    };
}

test "should use stack when available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Zig errors have no stack: the first line of the JavaScript stack is used.
    throwOriginal("with stack") catch |err| {
        const result = try wrapped_error.formatErrorChain(arena.allocator(), err);
        try std.testing.expectEqualStrings("Error: with stack", result);
    };
}

test "should fall back to message when stack is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Runtime Zig errors have no recorded message: the error name is used.
    const result = try wrapped_error.formatErrorChain(arena.allocator(), error.FileNotFound);
    try std.testing.expectEqualStrings("Error: FileNotFound", result);
}

test "writeErrorChain writes the chain to a writer" {
    var buffer: [256]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    throwTwoLevels() catch |err| {
        try wrapped_error.writeErrorChain(&fixed_writer, err);
    };
    try std.testing.expectEqualStrings("Error: outer: root cause\nCaused by:\nError: root cause", fixed_writer.buffered());
}

// Not ported: "should prepend the message when the stack omits it (JavaScriptCore stacks)" (Zig errors have
// no stack; the "Error: <message>" line that stands in for it always contains the message).

test "should not duplicate the message when the stack already contains it (V8 stacks)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    throwOriginal("already here") catch |err| {
        const result = try wrapped_error.formatErrorChain(arena.allocator(), err);
        try std.testing.expectEqualStrings("Error: already here", result);
    };
}

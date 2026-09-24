const std = @import("std");
const utils = @import("utils-zig");
const log_module = utils.log;
const errors = utils.errors;
const console = utils.console;

//
// A log that records the last message it received (to test setLog and forwarding).
//
const RecordingLog = struct {
    // The last message received by any method.
    lastMessage: []const u8 = "",

    // The name of the method that received the last message.
    lastMethod: []const u8 = "",

    // The name of the last error passed to exception.
    lastErrorName: []const u8 = "",

    //
    // Gets the ILog interface for this log.
    //
    fn ilog(self: *RecordingLog) log_module.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log.
    //
    const vtable: log_module.ILog.VTable = .{
        .info = info,
        .verbose = verbose,
        .@"error" = logError,
        .exception = exception,
        .warn = warn,
        .debug = debug,
        .tool = tool,
        .event = event,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
    };

    //
    // Records a message.
    //
    fn record(ptr: *anyopaque, method: []const u8, message: []const u8) void {
        const self: *RecordingLog = @ptrCast(@alignCast(ptr));
        self.lastMethod = method;
        self.lastMessage = message;
    }

    //
    // Records an info message.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "info", message);
    }

    //
    // Records a verbose message.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "verbose", message);
    }

    //
    // Records an error message.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "error", message);
    }

    //
    // Records an exception message.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        record(ptr, "exception", message);
        const self: *RecordingLog = @ptrCast(@alignCast(ptr));
        self.lastErrorName = @errorName(err);
    }

    //
    // Records a warning message.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "warn", message);
    }

    //
    // Records a debug message.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "debug", message);
    }

    //
    // Records tool output.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: log_module.IToolOutput) void {
        _ = data;
        record(ptr, "tool", toolName);
    }

    //
    // Records an event.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        record(ptr, "event", message);
    }

    //
    // Verbose logging is always enabled for this log.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    //
    // Returns fixed log details.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!log_module.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return .{ .logFilePath = "/tmp/test.log", .logHeader = "header" };
    }
};

//
// Throws an error with the message "root cause".
//
fn throwRootCause() errors.ThrownError!void {
    return errors.throwError("root cause", .{});
}

test "default log writes info and event to stdout and error, warn and exception to stderr" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);

    const log = log_module.log;
    log.info("info message");
    log.verbose("verbose message");
    log.debug("debug message");
    log.event("something happened");
    log.tool("ffprobe", .{ .stdout = "out", .stderr = null });
    log.@"error"("error message");
    log.warn("warn message");
    throwRootCause() catch |err| {
        log.exception("Failed.", err);
    };

    try std.testing.expectEqualStrings("info message\ndebug message\n[EVENT] something happened\n", stdout_capture.written());
    try std.testing.expectEqualStrings("error message\nwarn message\nFailed.\nError: root cause\n", stderr_capture.written());
    try std.testing.expect(!log.verboseEnabled());
}

test "default log has no log details" {
    const details = try log_module.log.getLogDetails(std.testing.allocator, std.testing.io);
    try std.testing.expect(details.logFilePath == null);
    try std.testing.expectEqualStrings("No log file available", details.logHeader);
    try std.testing.expectEqualStrings(log_module.noLogDetails.logHeader, details.logHeader);
}

test "setLog replaces the global log" {
    const original = log_module.log;
    defer log_module.setLog(original);
    var recording: RecordingLog = .{};
    log_module.setLog(recording.ilog());

    log_module.log.info("a");
    try std.testing.expectEqualStrings("info", recording.lastMethod);
    log_module.log.verbose("b");
    try std.testing.expectEqualStrings("verbose", recording.lastMethod);
    log_module.log.@"error"("c");
    try std.testing.expectEqualStrings("error", recording.lastMethod);
    log_module.log.exception("d", error.FileNotFound);
    try std.testing.expectEqualStrings("exception", recording.lastMethod);
    try std.testing.expectEqualStrings("FileNotFound", recording.lastErrorName);
    log_module.log.warn("e");
    try std.testing.expectEqualStrings("warn", recording.lastMethod);
    log_module.log.debug("f");
    try std.testing.expectEqualStrings("debug", recording.lastMethod);
    log_module.log.tool("g", .{ .stdout = null, .stderr = null });
    try std.testing.expectEqualStrings("tool", recording.lastMethod);
    log_module.log.event("h");
    try std.testing.expectEqualStrings("event", recording.lastMethod);
    try std.testing.expectEqualStrings("h", recording.lastMessage);
    try std.testing.expect(log_module.log.verboseEnabled());
    const details = try log_module.log.getLogDetails(std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("/tmp/test.log", details.logFilePath.?);
}

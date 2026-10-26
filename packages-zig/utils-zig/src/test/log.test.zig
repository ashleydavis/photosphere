const std = @import("std");
const utils = @import("utils-zig");
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
    fn ilog(self: *RecordingLog) utils.log.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log.
    //
    const vtable: utils.log.ILog.VTable = .{
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
    fn tool(ptr: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
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
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
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

test "default log writes info and event to stdout, error, warn and exception to stderr and leaves out verbose, debug and tool lines" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);

    const log = utils.log.log;
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

    try std.testing.expectEqualStrings("info message\n[EVENT] something happened\n", stdout_capture.written());
    try std.testing.expectEqualStrings("error message\nwarn message\nFailed.\nError: root cause\n", stderr_capture.written());
    try std.testing.expect(!log.verboseEnabled());
}

test "default log has no log details" {
    const details = try utils.log.log.getLogDetails(std.testing.allocator, std.testing.io);
    try std.testing.expect(details.logFilePath == null);
    try std.testing.expectEqualStrings("No log file available", details.logHeader);
    try std.testing.expectEqualStrings(utils.log.noLogDetails.logHeader, details.logHeader);
}

test "setLog replaces the log of the calling thread" {
    const original = utils.log.currentLog();
    defer utils.log.setLog(original);
    var recording: RecordingLog = .{};
    utils.log.setLog(recording.ilog());

    utils.log.log.info("a");
    try std.testing.expectEqualStrings("info", recording.lastMethod);
    utils.log.log.verbose("b");
    try std.testing.expectEqualStrings("verbose", recording.lastMethod);
    utils.log.log.@"error"("c");
    try std.testing.expectEqualStrings("error", recording.lastMethod);
    utils.log.log.exception("d", error.FileNotFound);
    try std.testing.expectEqualStrings("exception", recording.lastMethod);
    try std.testing.expectEqualStrings("FileNotFound", recording.lastErrorName);
    utils.log.log.warn("e");
    try std.testing.expectEqualStrings("warn", recording.lastMethod);
    utils.log.log.debug("f");
    try std.testing.expectEqualStrings("debug", recording.lastMethod);
    utils.log.log.tool("g", .{ .stdout = null, .stderr = null });
    try std.testing.expectEqualStrings("tool", recording.lastMethod);
    utils.log.log.event("h");
    try std.testing.expectEqualStrings("event", recording.lastMethod);
    try std.testing.expectEqualStrings("h", recording.lastMessage);
    try std.testing.expect(utils.log.log.verboseEnabled());
    const details = try utils.log.log.getLogDetails(std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("/tmp/test.log", details.logFilePath.?);
}

test "ilog of a console log gives a log that writes to the console" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    console.setCapture(&stdout_capture.writer, null);
    defer console.setCapture(null, null);
    var consoleLog: utils.log.ConsoleLog = .{
        .verbose_enabled = false,
        .debug_enabled = false,
        .tools_enabled = false,
    };
    const log = consoleLog.ilog();
    log.info("from ilog");
    try std.testing.expectEqualStrings("from ilog\n", stdout_capture.written());
    try std.testing.expect(!log.verboseEnabled());
}

const std = @import("std");
const utils = @import("utils-zig");
const log = utils.log;

//
// A log that counts and records the calls to exception. Every other method does nothing.
//
pub const ExceptionLog = struct {
    // How many times exception has been called.
    exceptionCalls: u32 = 0,

    // The message of the last call to exception.
    lastMessage: []const u8 = "",

    // The error of the last call to exception.
    lastError: ?anyerror = null,

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *ExceptionLog) log.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log.
    //
    const vtable: log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = ignoreMessage,
        .@"error" = ignoreMessage,
        .exception = exception,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = tool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };

    //
    // Records a call to exception.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *ExceptionLog = @ptrCast(@alignCast(ptr));
        self.exceptionCalls += 1;
        self.lastMessage = message;
        self.lastError = err;
    }

    //
    // Does nothing with a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Does nothing with tool output.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: log.IToolOutput) void {
        _ = ptr;
        _ = toolName;
        _ = data;
    }

    //
    // Verbose logging is off.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    //
    // Returns the placeholder log details.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return log.noLogDetails;
    }

    //
    // This log writes no file.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }
};

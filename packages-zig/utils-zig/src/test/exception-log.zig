const std = @import("std");
const utils = @import("utils-zig");
const log_module = utils.log;

//
// A log that counts and records the calls to exception (the jest.mock of `log` in the TypeScript
// tests, whose `exception` is a jest.fn()). Every other method does nothing.
//
pub const ExceptionLog = struct {
    // How many times exception has been called.
    exceptionCalls: u32 = 0,

    // The message of the last call to exception.
    lastMessage: []const u8 = "",

    // The error of the last call to exception.
    lastError: ?anyerror = null,

    // The log that was active before this one was installed.
    previousLog: ?log_module.ILog = null,

    //
    // Makes this the global log (TypeScript: jest.mock("../../lib/log")).
    //
    pub fn install(self: *ExceptionLog) void {
        self.previousLog = log_module.log;
        log_module.setLog(self.ilog());
    }

    //
    // Restores the log that was active before install.
    //
    pub fn uninstall(self: *ExceptionLog) void {
        if (self.previousLog) |previous| {
            log_module.setLog(previous);
        }
    }

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *ExceptionLog) log_module.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log.
    //
    const vtable: log_module.ILog.VTable = .{
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
    fn tool(ptr: *anyopaque, toolName: []const u8, data: log_module.IToolOutput) void {
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
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!log_module.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return log_module.noLogDetails;
    }
};

const std = @import("std");
const utils = @import("utils-zig");

//
// A log for the tests that keeps the errors and the tool output it is given, and ignores everything else. It is made on the thread
// that gives it to a call, which every message of the call reaches.
//
pub const ICapturedLog = struct {
    // Every error the log was given, each on a line of its own.
    errors: std.ArrayList(u8),

    // Every tool name and standard error the log was given, one after another.
    stderr: std.ArrayList(u8),

    // The allocator the text is kept with.
    allocator: std.mem.Allocator,

    //
    // Makes the log, which keeps nothing yet.
    //
    pub fn init(allocator: std.mem.Allocator) ICapturedLog {
        return .{
            .errors = .empty,
            .stderr = .empty,
            .allocator = allocator,
        };
    }

    //
    // The ILog interface of this log.
    //
    pub fn ilog(self: *ICapturedLog) utils.log.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Keeps an error.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        const self: *ICapturedLog = @ptrCast(@alignCast(ptr));
        self.errors.print(self.allocator, "{s}\n", .{message}) catch @panic("out of memory keeping an error");
    }

    //
    // Keeps the standard error of a tool.
    //
    fn tool(ptr: *anyopaque, tool_name: []const u8, data: utils.log.IToolOutput) void {
        const self: *ICapturedLog = @ptrCast(@alignCast(ptr));
        if (data.stderr) |stderr| {
            self.stderr.print(self.allocator, "{s}: {s}", .{ tool_name, stderr }) catch @panic("out of memory keeping a tool's output");
        }
    }

    //
    // Ignores a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Ignores an error with its cause.
    //
    fn ignoreException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        _ = message;
        _ = @intFromError(err);
    }

    //
    // Verbose logging is off.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    //
    // The log has no file.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return utils.log.noLogDetails;
    }

    //
    // This log writes no file.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }

    // The ILog functions of the log.
    const vtable: utils.log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = ignoreMessage,
        .@"error" = logError,
        .exception = ignoreException,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = tool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };
};

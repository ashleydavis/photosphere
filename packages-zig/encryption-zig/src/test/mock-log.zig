const std = @import("std");
const utils = @import("utils-zig");

//
// A log that counts the calls to verbose and exception and prints nothing (the jest.mock of the utils log in the
// TypeScript tests, whose `verbose` and `exception` are jest.fn()s). Every other method does nothing.
//
pub const MockLog = struct {
    // How many times verbose has been called.
    verboseCalls: u32 = 0,

    // How many times exception has been called.
    exceptionCalls: u32 = 0,

    // The log that was active before this one was installed.
    previousLog: ?utils.log.ILog = null,

    //
    // Makes this the global log.
    //
    pub fn install(self: *MockLog) void {
        self.previousLog = utils.log.log;
        utils.log.setLog(self.ilog());
    }

    //
    // Restores the log that was active before install.
    //
    pub fn uninstall(self: *MockLog) void {
        if (self.previousLog) |previous| {
            utils.log.setLog(previous);
        }
    }

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *MockLog) utils.log.ILog {
        return .{
            .ptr = self,
            .vtable = &mock_log_vtable,
        };
    }
};

//
// The ILog functions of MockLog.
//
const mock_log_vtable: utils.log.ILog.VTable = .{
    .info = mockIgnoreMessage,
    .verbose = mockVerbose,
    .@"error" = mockIgnoreMessage,
    .exception = mockException,
    .warn = mockIgnoreMessage,
    .debug = mockIgnoreMessage,
    .tool = mockTool,
    .event = mockIgnoreMessage,
    .verboseEnabled = mockVerboseEnabled,
    .getLogDetails = mockGetLogDetails,
};

//
// Records a call to verbose.
//
fn mockVerbose(ptr: *anyopaque, message: []const u8) void {
    const self: *MockLog = @ptrCast(@alignCast(ptr));
    _ = message;
    self.verboseCalls += 1;
}

//
// Records a call to exception.
//
fn mockException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
    const self: *MockLog = @ptrCast(@alignCast(ptr));
    _ = message;
    _ = @intFromError(err);
    self.exceptionCalls += 1;
}

//
// Does nothing with a message.
//
fn mockIgnoreMessage(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    _ = message;
}

//
// Does nothing with tool output.
//
fn mockTool(ptr: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
    _ = ptr;
    _ = toolName;
    _ = data;
}

//
// Verbose logging is off.
//
fn mockVerboseEnabled(ptr: *anyopaque) bool {
    _ = ptr;
    return false;
}

//
// Returns the placeholder log details.
//
fn mockGetLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
    _ = ptr;
    _ = allocator;
    _ = io;
    return utils.log.noLogDetails;
}

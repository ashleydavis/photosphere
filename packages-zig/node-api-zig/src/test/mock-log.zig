const std = @import("std");
const utils = @import("utils-zig");

//
// A log that swallows every message (the jest.mock of `log` in the TypeScript tests, whose methods are jest.fn()s).
// For a test whose code under test logs to stderr: a passing test program must write nothing to stderr, because
// Zig 0.16.0 prints a misleading "failed command" line after any (https://codeberg.org/ziglang/zig/issues/35202).
//
pub const MutedLog = struct {
    // The log that was active before this one was installed.
    previousLog: ?utils.log.ILog = null,

    //
    // Makes this the global log.
    //
    pub fn install(self: *MutedLog) void {
        self.previousLog = utils.log.log;
        utils.log.setLog(self.ilog());
    }

    //
    // Restores the log that was active before install.
    //
    pub fn uninstall(self: *MutedLog) void {
        if (self.previousLog) |previous| {
            utils.log.setLog(previous);
        }
    }

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *MutedLog) utils.log.ILog {
        return .{
            .ptr = self,
            .vtable = &mutedLogVtable,
        };
    }
};

//
// The ILog functions of MutedLog.
//
const mutedLogVtable: utils.log.ILog.VTable = .{
    .info = mutedMessage,
    .verbose = mutedMessage,
    .@"error" = mutedMessage,
    .exception = mutedException,
    .warn = mutedMessage,
    .debug = mutedMessage,
    .tool = mutedTool,
    .event = mutedMessage,
    .verboseEnabled = mutedVerboseEnabled,
    .getLogDetails = mutedLogDetails,
};

//
// Does nothing with a message.
//
fn mutedMessage(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    _ = message;
}

//
// Does nothing with an exception.
//
fn mutedException(_: *anyopaque, _: []const u8, _: anyerror) void {}

//
// Does nothing with tool output.
//
fn mutedTool(ptr: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
    _ = ptr;
    _ = toolName;
    _ = data;
}

//
// Verbose logging is off.
//
fn mutedVerboseEnabled(ptr: *anyopaque) bool {
    _ = ptr;
    return false;
}

//
// Returns the placeholder log details.
//
fn mutedLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
    _ = ptr;
    _ = allocator;
    _ = io;
    return utils.log.noLogDetails;
}

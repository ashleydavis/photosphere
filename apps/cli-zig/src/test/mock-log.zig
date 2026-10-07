const std = @import("std");
const utils = @import("utils-zig");
const log_module = utils.log;

//
// The log methods a MockLog records calls to.
//
pub const LogMethod = enum {
    // log.info
    info,

    // log.verbose
    verbose,

    // log.error
    @"error",

    // log.exception
    exception,

    // log.warn
    warn,

    // log.debug
    debug,

    // log.tool
    tool,

    // log.event
    event,
};

//
// One call recorded by a MockLog.
//
pub const IMockLogCall = struct {
    // The method that was called.
    method: LogMethod,

    // The message passed to it (a copy owned by the MockLog).
    message: []const u8,
};

//
// A log that records every call made to it (the mocked `log` of `utils` in the TypeScript tests, whose
// methods are jest.fn()s). Nothing is written anywhere.
//
pub const MockLog = struct {
    // Allocator the recorded calls are copied with.
    allocator: std.mem.Allocator,

    // Every call, in the order made.
    calls: std.ArrayList(IMockLogCall) = .empty,

    // The log that was active before this one was installed.
    previousLog: ?log_module.ILog = null,

    //
    // Creates a mock log that records with the allocator.
    //
    pub fn init(allocator: std.mem.Allocator) MockLog {
        return .{
            .allocator = allocator,
        };
    }

    //
    // Frees what was recorded.
    //
    pub fn deinit(self: *MockLog) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.message);
        }
        self.calls.deinit(self.allocator);
    }

    //
    // Makes this the global log (TypeScript: the mocked `utils` module).
    //
    pub fn install(self: *MockLog) void {
        self.previousLog = log_module.log;
        log_module.setLog(self.ilog());
    }

    //
    // Restores the log that was active before install.
    //
    pub fn uninstall(self: *MockLog) void {
        if (self.previousLog) |previous| {
            log_module.setLog(previous);
        }
    }

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *MockLog) log_module.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The number of calls to a method (TypeScript: log.info.mock.calls.length).
    //
    pub fn callCount(self: *const MockLog, method: LogMethod) usize {
        var count: usize = 0;
        for (self.calls.items) |call| {
            if (call.method == method) {
                count += 1;
            }
        }
        return count;
    }

    //
    // True when a method was called with exactly this message (TypeScript: toHaveBeenCalledWith(message)).
    //
    pub fn wasCalledWith(self: *const MockLog, method: LogMethod, message: []const u8) bool {
        for (self.calls.items) |call| {
            if (call.method == method and std.mem.eql(u8, call.message, message)) {
                return true;
            }
        }
        return false;
    }

    //
    // True when a method was called with a message containing the text (TypeScript: toHaveBeenCalledWith(expect.stringContaining(text))).
    //
    pub fn wasCalledContaining(self: *const MockLog, method: LogMethod, text: []const u8) bool {
        for (self.calls.items) |call| {
            if (call.method == method and std.mem.indexOf(u8, call.message, text) != null) {
                return true;
            }
        }
        return false;
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
    // Records a call.
    //
    fn record(ptr: *anyopaque, method: LogMethod, message: []const u8) void {
        const self: *MockLog = @ptrCast(@alignCast(ptr));
        const copy = self.allocator.dupe(u8, message) catch @panic("MockLog ran out of memory");
        self.calls.append(self.allocator, .{
            .method = method,
            .message = copy,
        }) catch @panic("MockLog ran out of memory");
    }

    //
    // Records a call to info.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        record(ptr, .info, message);
    }

    //
    // Records a call to verbose.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        record(ptr, .verbose, message);
    }

    //
    // Records a call to error.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        record(ptr, .@"error", message);
    }

    //
    // Records a call to exception.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = @errorName(err);
        record(ptr, .exception, message);
    }

    //
    // Records a call to warn.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        record(ptr, .warn, message);
    }

    //
    // Records a call to debug.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        record(ptr, .debug, message);
    }

    //
    // Records a call to tool.
    //
    fn tool(ptr: *anyopaque, toolName: []const u8, data: log_module.IToolOutput) void {
        _ = data;
        record(ptr, .tool, toolName);
    }

    //
    // Records a call to event.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        record(ptr, .event, message);
    }

    //
    // Verbose logging is off (TypeScript: verboseEnabled: false).
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

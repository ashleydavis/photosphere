const std = @import("std");
const utils = @import("utils-zig");
const file_logger = @import("file-logger.zig");
const process_argv = @import("process-argv.zig");
const console_output = @import("console-output.zig");
const writeOutputLine = console_output.writeOutputLine;
const writeErrorLine = console_output.writeErrorLine;
const ILog = utils.log.ILog;
const ILogDetails = utils.log.ILogDetails;
const IToolOutput = utils.log.IToolOutput;
const noLogDetails = utils.log.noLogDetails;
const setLog = utils.log.setLog;
const FileLogger = file_logger.FileLogger;

//
// Options for configuring the log.
//
pub const ILogOptions = struct {
    //
    // Enables verbose logging.
    //
    verbose: ?bool = null,

    //
    // Enables debug logging.
    //
    debug: ?bool = null,

    //
    // Enables tool output logging.
    //
    tools: ?bool = null,

    //
    // Disables file logging (console only)
    //
    disableFileLogging: ?bool = null,
};

//
// Global reference to the file logger for access from other modules
//
var fileLogger: ?*FileLogger = null;

//
// Prints a line of the CLI's output built from a format string (no TypeScript counterpart: TypeScript uses
// template strings). Lines longer than the internal buffer are truncated.
//
fn writeOutputLineFormat(comptime format: []const u8, args: anytype) void {
    var buffer: [16 * 1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    writeOutputLine(message);
}

//
// The console log of the CLI.
//
pub const Log = struct {
    // The options that enable the optional kinds of output.
    options: ILogOptions,

    //
    // Creates the log.
    //
    pub fn init(options: ILogOptions) Log {
        return .{ .options = options };
    }

    //
    // Gets the ILog interface for this log (the Log must not move while it is used).
    //
    pub fn ilog(self: *Log) ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this log.
    //
    const vtable: ILog.VTable = .{
        .info = infoErased,
        .verbose = verboseErased,
        .@"error" = errorErased,
        .exception = exceptionErased,
        .warn = warnErased,
        .debug = debugErased,
        .tool = toolErased,
        .event = eventErased,
        .verboseEnabled = verboseEnabledErased,
        .getLogDetails = getLogDetailsErased,
    };

    //
    // True when verbose logging is enabled.
    //
    pub fn verboseEnabled(self: *Log) bool {
        return self.options.verbose orelse false;
    }

    //
    // Writes an informational message to stdout.
    //
    pub fn info(self: *Log, message: []const u8) void {
        _ = self;
        writeOutputLine(message);
    }

    //
    // Writes a verbose message to stdout when verbose logging is enabled.
    //
    pub fn verbose(self: *Log, message: []const u8) void {
        if (!(self.options.verbose orelse false)) {
            return;
        }

        writeOutputLine(message);
    }

    //
    // Writes an error message to stderr.
    //
    pub fn @"error"(self: *Log, message: []const u8) void {
        _ = self;
        writeErrorLine(message);
    }

    //
    // Writes a message and the error's cause chain to stderr.
    //
    pub fn exception(self: *Log, message: []const u8, err: anyerror) void {
        _ = self;
        writeErrorLine(message);
        var buffer: [16 * 1024]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&buffer);
        utils.wrapped_error.writeErrorChain(&fixed_writer, err) catch {};
        writeErrorLine(fixed_writer.buffered());
    }

    //
    // Writes a warning to stderr.
    //
    pub fn warn(self: *Log, message: []const u8) void {
        _ = self;
        writeErrorLine(message);
    }

    //
    // Writes a debug message to stderr when debug logging is enabled.
    //
    pub fn debug(self: *Log, message: []const u8) void {
        if (!(self.options.debug orelse false)) {
            return;
        }

        writeErrorLine(message);
    }

    //
    // Writes the output of an external tool to stdout when tool logging is enabled.
    //
    pub fn tool(self: *Log, toolName: []const u8, data: IToolOutput) void {
        if (!(self.options.tools orelse false)) {
            return;
        }

        if (data.stdout) |stdout| {
            if (stdout.len > 0) {
                writeOutputLineFormat("== {s} stdout ==\n{s}", .{ toolName, stdout });
            }
        }
        if (data.stderr) |stderr| {
            if (stderr.len > 0) {
                writeOutputLineFormat("== {s} stderr ==\n{s}", .{ toolName, stderr });
            }
        }
    }

    //
    // Writes an event to stdout.
    //
    pub fn event(self: *Log, message: []const u8) void {
        _ = self;
        writeOutputLineFormat("[EVENT] {s}", .{message});
    }

    //
    // Gets details about the active log file for inclusion in bug reports.
    // The console logger has no log file.
    //
    pub fn getLogDetails(self: *Log) ILogDetails {
        _ = self;
        return noLogDetails;
    }

    //
    // ILog.info for this implementation.
    //
    fn infoErased(ptr: *anyopaque, message: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.info(message);
    }

    //
    // ILog.verbose for this implementation.
    //
    fn verboseErased(ptr: *anyopaque, message: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.verbose(message);
    }

    //
    // ILog.error for this implementation.
    //
    fn errorErased(ptr: *anyopaque, message: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.@"error"(message);
    }

    //
    // ILog.exception for this implementation.
    //
    fn exceptionErased(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.exception(message, err);
    }

    //
    // ILog.warn for this implementation.
    //
    fn warnErased(ptr: *anyopaque, message: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.warn(message);
    }

    //
    // ILog.debug for this implementation.
    //
    fn debugErased(ptr: *anyopaque, message: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.debug(message);
    }

    //
    // ILog.tool for this implementation.
    //
    fn toolErased(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.tool(toolName, data);
    }

    //
    // ILog.event for this implementation.
    //
    fn eventErased(ptr: *anyopaque, message: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        self.event(message);
    }

    //
    // ILog.verboseEnabled for this implementation.
    //
    fn verboseEnabledErased(ptr: *anyopaque) bool {
        const self: *Log = @ptrCast(@alignCast(ptr));
        return self.verboseEnabled();
    }

    //
    // ILog.getLogDetails for this implementation.
    //
    fn getLogDetailsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        _ = allocator;
        _ = io;
        const self: *Log = @ptrCast(@alignCast(ptr));
        return self.getLogDetails();
    }
};

//
// Configure the log based on input.
// The loggers are allocated with the allocator and must live until the process exits.
//
pub fn configureLog(allocator: std.mem.Allocator, io: std.Io, options: ILogOptions) !void {
    const consoleLogger = try allocator.create(Log);
    consoleLogger.* = Log.init(options);
    setLog(consoleLogger.ilog()); // Set the console logger before trying to create the file logger, just in case we need the log!

    if (!(options.disableFileLogging orelse false)) {
        const userArgs = process_argv.userArgs();
        const joined = try std.mem.join(allocator, " ", userArgs);
        const command = if (joined.len > 0) joined else "unknown";
        const created = try FileLogger.create(allocator, io, consoleLogger.ilog(), command);
        fileLogger = created;
        setLog(created.ilog());
    }
}

//
// Get the current file logger instance
//
pub fn getFileLogger() ?*FileLogger {
    return fileLogger;
}

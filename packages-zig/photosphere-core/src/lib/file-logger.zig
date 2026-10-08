//
// The log of the desktop app: a port of apps/desktop/src/lib/file-logger-electron.ts and of the message a worker sends to it
// (worker-log-electron.ts, IWorkerLogMessage). It writes every log line to a log file, and every error, exception and warning
// to a second file that is only ever written to for those, as the Electron one does.
//
// Writes are queued in memory and a thread appends them to the file, as the TypeScript queues them and awaits fs.appendFile, so a
// call to log never waits for the disk. There is one queue and one thread for each of the two files.
//
// Where the TypeScript uses an Electron or Node call, this takes the value as a parameter of init: the directory to log in (the
// TypeScript derives it from PHOTOSPHERE_LOG_DIR or the operating system's temporary directory) and the app's version.
//
// How it is created: `const file_logger = try FileLogger.init(allocator, io, logs_dir, app_version);` then
// `utils.log.setLog(file_logger.ilog());`. At shutdown call `try file_logger.close();` (which writes the footers and waits for the
// queues to drain) and then `file_logger.deinit();`. The logger must outlive every use of the installed ILog.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");

const ILog = utils.log.ILog;
const ILogDetails = utils.log.ILogDetails;
const IToolOutput = utils.log.IToolOutput;

//
// The levels of the log message a worker (or the page) sends, from IWorkerLogMessage.level.
//
pub const WorkerLogLevel = enum {
    // An informational message.
    info,
    // A verbose message.
    verbose,
    // An error message.
    @"error",
    // An exception, with the text of its stack in `error`.
    exception,
    // A warning.
    warn,
    // A debug message.
    debug,
    // The output of an external tool, in `tool_data`.
    tool,
    // An event.
    event,
};

//
// A log message sent from a worker or from the page, from IWorkerLogMessage (the field `type` is not kept, it is always "log").
//
pub const WorkerLogMessage = struct {
    // The level of the message.
    level: WorkerLogLevel,
    // The message, or for the tool level the name of the tool.
    message: []const u8,
    // The text of the stack of the error, for the exception level.
    @"error": ?[]const u8,
    // The output of the tool, for the tool level.
    tool_data: ?IToolOutput,
};

//
// The text a log line ends and starts with in the header and footers.
//
const rule_line = "=" ** 80;

//
// The marker that ends the header of the log file, which getLogDetails reads up to.
//
const log_start_marker = "--- Log Start ---";

//
// How many bytes of the start of the log file getLogDetails reads to find the header. The header is written when the log is
// created and is a few hundred bytes, so this is a bound on the read and not a limit on the header.
//
const header_read_limit = 1024 * 1024;

//
// The text waiting to be written to one file, and the thread that is writing it.
//
const WriteQueue = struct {
    // The file the queue is appended to.
    path: []const u8,
    // The log lines not yet handed to the writing thread.
    pending: std.ArrayList(u8),
    // True while a thread is draining the queue.
    is_writing: bool,
    // The thread that is draining the queue, or that last drained it.
    writer_thread: ?std.Thread,
};

//
// Writes the log of the app to files. Make one with init.
//
pub const FileLogger = struct {
    // Allocates everything the logger owns.
    allocator: std.mem.Allocator,
    // The Io used for the clock, the files and the wait in close.
    io: std.Io,
    // The directory the log files are in.
    logs_dir: []const u8,
    // The path of the log file.
    log_file: []const u8,
    // The path of the error log file.
    error_log_file: []const u8,
    // When the logger was created, in milliseconds since the Unix epoch.
    start_ms: i64,
    // Guards everything below.
    mutex: std.Io.Mutex,
    // The queue of the log file.
    log_queue: WriteQueue,
    // The queue of the error log file.
    error_queue: WriteQueue,
    // True once close was called, after which nothing more is logged.
    is_closed: bool,
    // True once an error, an exception or a warning has been logged.
    has_errors: bool,

    //
    // Creates the logs directory if it is not there, and the log file and the error log file in it, with their headers. The names
    // are photosphere-<start time>.log and photosphere-<start time>-errors.log. The headers carry the system information and the
    // versions of the tools the app uses, as the Electron log's do, where the Node, Electron and Chrome versions are the version
    // of Zig this was built with and `app_version`. Nothing is rotated or cleaned up: the TypeScript does not do that either.
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, logs_dir: []const u8, app_version: []const u8) !*FileLogger {
        const start_ms = std.Io.Clock.real.now(io).toMilliseconds();
        try node_utils.fs.ensureDir(io, logs_dir);
        const start_iso = try (utils.timestamp_provider.Date{ .epochMilliseconds = start_ms }).toISOString(allocator);
        defer allocator.free(start_iso);
        // new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
        var file_timestamp: [19]u8 = undefined;
        @memcpy(&file_timestamp, start_iso[0..19]);
        std.mem.replaceScalar(u8, &file_timestamp, ':', '-');
        std.mem.replaceScalar(u8, &file_timestamp, '.', '-');
        const log_name = try std.fmt.allocPrint(allocator, "photosphere-{s}.log", .{file_timestamp});
        defer allocator.free(log_name);
        const error_log_name = try std.fmt.allocPrint(allocator, "photosphere-{s}-errors.log", .{file_timestamp});
        defer allocator.free(error_log_name);
        const logger = try allocator.create(FileLogger);
        errdefer allocator.destroy(logger);
        const owned_logs_dir = try allocator.dupe(u8, logs_dir);
        errdefer allocator.free(owned_logs_dir);
        const log_file = try std.fs.path.join(allocator, &.{ logs_dir, log_name });
        errdefer allocator.free(log_file);
        const error_log_file = try std.fs.path.join(allocator, &.{ logs_dir, error_log_name });
        errdefer allocator.free(error_log_file);
        logger.* = .{
            .allocator = allocator,
            .io = io,
            .logs_dir = owned_logs_dir,
            .log_file = log_file,
            .error_log_file = error_log_file,
            .start_ms = start_ms,
            .mutex = .init,
            .log_queue = .{
                .path = log_file,
                .pending = .empty,
                .is_writing = false,
                .writer_thread = null,
            },
            .error_queue = .{
                .path = error_log_file,
                .pending = .empty,
                .is_writing = false,
                .writer_thread = null,
            },
            .is_closed = false,
            .has_errors = false,
        };
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const system_information = try buildSystemInformation(arena, io, app_version);
        const tool_versions = try buildToolVersions(arena, io);
        const header = try std.mem.join(arena, "\n", &.{
            rule_line,
            "Photosphere Desktop Log",
            try std.fmt.allocPrint(arena, "Started: {s}", .{start_iso}),
            rule_line,
            "",
            system_information,
            "",
            tool_versions,
            "",
            log_start_marker,
            "",
        });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = log_file,
            .data = header,
        });
        const error_header = try std.mem.join(arena, "\n", &.{
            rule_line,
            "Photosphere Desktop Error Log",
            try std.fmt.allocPrint(arena, "Started: {s}", .{start_iso}),
            rule_line,
            "",
            system_information,
            "",
            tool_versions,
            "",
            "If this file contains nothing below, it means there were no errors.",
            "",
            "--- Error Log Start ---",
            "",
        });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = error_log_file,
            .data = error_header,
        });
        return logger;
    }

    //
    // Closes the logger if it is still open, and frees it. A failure to write the footers is reported on the console, because
    // there is nowhere to return it. Call close first to get the error.
    //
    pub fn deinit(self: *FileLogger) void {
        self.close() catch |err| {
            reportLoggingFailure("write the end of the log files", err);
        };
        self.log_queue.pending.deinit(self.allocator);
        self.error_queue.pending.deinit(self.allocator);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.log_file);
        self.allocator.free(self.error_log_file);
        self.allocator.destroy(self);
    }

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *FileLogger) ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Gives the logger behind an ILog, or null when the ILog is some other log (the console log, say).
    //
    pub fn fromILog(log: ILog) ?*FileLogger {
        if (log.vtable != &vtable) {
            return null;
        }
        return @ptrCast(@alignCast(log.ptr));
    }

    //
    // Writes the footers, waits for everything queued to be written, and stops accepting messages. Calling it again does nothing.
    // The first failure to write is returned after every write has been tried.
    //
    pub fn close(self: *FileLogger) !void {
        self.mutex.lockUncancelable(self.io);
        if (self.is_closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.is_closed = true;
        self.mutex.unlock(self.io);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const end_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const end_iso = try (utils.timestamp_provider.Date{ .epochMilliseconds = end_ms }).toISOString(arena);
        const duration_ms = end_ms - self.start_ms;
        const footer = try std.mem.join(arena, "\n", &.{
            "",
            "--- Log End ---",
            try std.fmt.allocPrint(arena, "Completed: {s}", .{end_iso}),
            try std.fmt.allocPrint(arena, "Duration: {d}ms ({d:.2}s)", .{ duration_ms, @as(f64, @floatFromInt(duration_ms)) / 1000.0 }),
            rule_line,
            "",
        });
        const error_footer = try std.mem.join(arena, "\n", &.{
            "",
            "--- Error Log End ---",
            try std.fmt.allocPrint(arena, "Completed: {s}", .{end_iso}),
            rule_line,
            "",
        });
        self.mutex.lockUncancelable(self.io);
        self.log_queue.pending.appendSlice(self.allocator, footer) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        while (self.isWriting()) {
            try utils.sleep.sleep(self.io, 10);
        }
        self.mutex.lockUncancelable(self.io);
        const log_content = self.log_queue.pending.toOwnedSlice(self.allocator);
        const error_content = self.error_queue.pending.toOwnedSlice(self.allocator);
        const has_errors = self.has_errors;
        self.mutex.unlock(self.io);
        const log_text = try log_content;
        defer self.allocator.free(log_text);
        const error_text = try error_content;
        defer self.allocator.free(error_text);
        if (self.log_queue.writer_thread) |thread| {
            thread.join();
            self.log_queue.writer_thread = null;
        }
        if (self.error_queue.writer_thread) |thread| {
            thread.join();
            self.error_queue.writer_thread = null;
        }
        var first_error: ?anyerror = null;
        appendToFile(self.io, self.log_file, log_text) catch |err| {
            first_error = err;
        };
        if (error_text.len > 0) {
            appendToFile(self.io, self.error_log_file, error_text) catch |err| {
                first_error = first_error orelse err;
            };
        }
        if (has_errors) {
            appendToFile(self.io, self.error_log_file, error_footer) catch |err| {
                first_error = first_error orelse err;
            };
        }
        if (first_error) |err| {
            return err;
        }
    }

    //
    // The path of the current log file.
    //
    pub fn getLogFilePath(self: *FileLogger) []const u8 {
        return self.log_file;
    }

    //
    // The path of the logs directory.
    //
    pub fn getLogsDirectory(self: *FileLogger) []const u8 {
        return self.logs_dir;
    }

    //
    // The path of the error log file.
    //
    pub fn getErrorLogFilePath(self: *FileLogger) []const u8 {
        return self.error_log_file;
    }

    //
    // True when any error, exception or warning has been logged.
    //
    pub fn hasLoggedErrors(self: *FileLogger) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.has_errors;
    }

    //
    // Logs a message sent from a worker or from the page, with the name of where it came from, as the TypeScript's
    // handleWorkerLogMessage does. The tool level with no tool data logs nothing.
    //
    pub fn handleWorkerLogMessage(self: *FileLogger, message: WorkerLogMessage, source: []const u8) !void {
        switch (message.level) {
            .info => try self.logInfo(message.message, source),
            .verbose => try self.writeToFile("verbose", message.message, source),
            .@"error" => try self.logError(message.message, source),
            .exception => {
                // The TypeScript tests the error text for truthiness, so an empty text counts as none.
                var error_text: ?[]const u8 = null;
                if (message.@"error") |text| {
                    if (text.len > 0) {
                        error_text = text;
                    }
                }
                const full_message = if (error_text) |text|
                    try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ message.message, text })
                else
                    try self.allocator.dupe(u8, message.message);
                defer self.allocator.free(full_message);
                try self.writeToFile("exception", full_message, source);
                try self.writeToErrorFile("exception", full_message, source);
                utils.console.errorFormat("[ERROR] [{s}] {s}", .{ source, message.message });
                if (error_text) |text| {
                    utils.console.errorFormat("[ERROR] [{s}] {s}", .{ source, text });
                }
            },
            .warn => try self.logWarn(message.message, source),
            .debug => try self.writeToFile("debug", message.message, source),
            .tool => {
                if (message.tool_data) |tool_data| {
                    try self.logTool(message.message, tool_data, source);
                    if (tool_data.stdout) |stdout| {
                        if (stdout.len > 0) {
                            utils.console.logFormat("[{s}] == {s} stdout ==\n{s}", .{ source, message.message, stdout });
                        }
                    }
                    if (tool_data.stderr) |stderr| {
                        if (stderr.len > 0) {
                            utils.console.logFormat("[{s}] == {s} stderr ==\n{s}", .{ source, message.message, stderr });
                        }
                    }
                }
            },
            .event => try self.logEvent(message.message, source),
        }
    }

    //
    // True while either queue has a thread writing it.
    //
    fn isWriting(self: *FileLogger) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.log_queue.is_writing or self.error_queue.is_writing;
    }

    //
    // Formats a line of a log file: [timestamp] [LEVEL] [source] message, with a newline.
    //
    fn formatEntry(self: *FileLogger, level: []const u8, message: []const u8, source: ?[]const u8) ![]u8 {
        const now_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const timestamp = try (utils.timestamp_provider.Date{ .epochMilliseconds = now_ms }).toISOString(self.allocator);
        defer self.allocator.free(timestamp);
        const upper_level = try std.ascii.allocUpperString(self.allocator, level);
        defer self.allocator.free(upper_level);
        const source_text = source orelse "";
        if (source_text.len > 0) {
            return std.fmt.allocPrint(self.allocator, "[{s}] [{s}] [{s}] {s}\n", .{ timestamp, upper_level, source_text, message });
        }
        return std.fmt.allocPrint(self.allocator, "[{s}] [{s}] {s}\n", .{ timestamp, upper_level, message });
    }

    //
    // Queues a line for the log file.
    //
    fn writeToFile(self: *FileLogger, level: []const u8, message: []const u8, source: ?[]const u8) !void {
        const entry = try self.formatEntry(level, message, source);
        defer self.allocator.free(entry);
        try self.enqueue(&self.log_queue, entry, false);
    }

    //
    // Queues a line for the error log file, and notes that there are errors.
    //
    fn writeToErrorFile(self: *FileLogger, level: []const u8, message: []const u8, source: ?[]const u8) !void {
        const entry = try self.formatEntry(level, message, source);
        defer self.allocator.free(entry);
        try self.enqueue(&self.error_queue, entry, true);
    }

    //
    // Adds text to a queue and starts a thread to write it when none is writing. Does nothing once the logger is closed.
    //
    fn enqueue(self: *FileLogger, queue: *WriteQueue, entry: []const u8, marks_errors: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.is_closed) {
            return;
        }
        if (marks_errors) {
            self.has_errors = true;
        }
        try queue.pending.appendSlice(self.allocator, entry);
        if (queue.is_writing) {
            return;
        }
        // The thread that last drained the queue has finished with the queue (it clears is_writing and returns), so this is quick.
        if (queue.writer_thread) |previous| {
            previous.join();
            queue.writer_thread = null;
        }
        queue.is_writing = true;
        queue.writer_thread = std.Thread.spawn(.{}, drainQueue, .{ self, queue }) catch |err| {
            queue.is_writing = false;
            return err;
        };
    }

    //
    // The writing thread: appends what is queued to the file until the queue is empty. A failed write drops that batch (as the
    // TypeScript's does) and is reported on the console, where the TypeScript ignores it.
    //
    fn drainQueue(self: *FileLogger, queue: *WriteQueue) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const taken = queue.pending.toOwnedSlice(self.allocator) catch |err| {
                queue.is_writing = false;
                self.mutex.unlock(self.io);
                reportLoggingFailure("take the queued log lines", err);
                return;
            };
            if (taken.len == 0) {
                queue.is_writing = false;
                self.mutex.unlock(self.io);
                self.allocator.free(taken);
                return;
            }
            self.mutex.unlock(self.io);
            appendToFile(self.io, queue.path, taken) catch |err| {
                utils.console.errorFormat("Photosphere could not write to the log file {s}: {s}", .{ queue.path, @errorName(err) });
            };
            self.allocator.free(taken);
        }
    }

    //
    // Logs an informational message to the file and the console.
    //
    fn logInfo(self: *FileLogger, message: []const u8, source: ?[]const u8) !void {
        try self.writeToFile("info", message, source);
        if (source) |source_text| {
            utils.console.logFormat("[{s}] {s}", .{ source_text, message });
        }
        else {
            utils.console.log(message);
        }
    }

    //
    // Logs an error message to both files and the console.
    //
    fn logError(self: *FileLogger, message: []const u8, source: ?[]const u8) !void {
        try self.writeToFile("error", message, source);
        try self.writeToErrorFile("error", message, source);
        if (source) |source_text| {
            utils.console.errorFormat("[ERROR] [{s}] {s}", .{ source_text, message });
        }
        else {
            utils.console.errorFormat("[ERROR] {s}", .{message});
        }
    }

    //
    // Logs a warning to both files and the console.
    //
    fn logWarn(self: *FileLogger, message: []const u8, source: ?[]const u8) !void {
        try self.writeToFile("warn", message, source);
        try self.writeToErrorFile("warn", message, source);
        if (source) |source_text| {
            const console_text = try std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ source_text, message });
            defer self.allocator.free(console_text);
            utils.console.warn(console_text);
        }
        else {
            utils.console.warn(message);
        }
    }

    //
    // Logs an event to the file and the console.
    //
    fn logEvent(self: *FileLogger, message: []const u8, source: ?[]const u8) !void {
        try self.writeToFile("event", message, source);
        if (source) |source_text| {
            utils.console.logFormat("[EVENT] [{s}] {s}", .{ source_text, message });
        }
        else {
            utils.console.logFormat("[EVENT] {s}", .{message});
        }
    }

    //
    // Logs the output of a tool to the file, one entry for its standard output and one for its standard error, when each has text.
    //
    fn logTool(self: *FileLogger, tool_name: []const u8, data: IToolOutput, source: ?[]const u8) !void {
        if (data.stdout) |stdout| {
            if (stdout.len > 0) {
                const text = try std.fmt.allocPrint(self.allocator, "== {s} stdout ==\n{s}", .{ tool_name, stdout });
                defer self.allocator.free(text);
                try self.writeToFile("tool", text, source);
            }
        }
        if (data.stderr) |stderr| {
            if (stderr.len > 0) {
                const text = try std.fmt.allocPrint(self.allocator, "== {s} stderr ==\n{s}", .{ tool_name, stderr });
                defer self.allocator.free(text);
                try self.writeToFile("tool", text, source);
            }
        }
    }

    //
    // The ILog functions of the file logger.
    //
    pub const vtable: ILog.VTable = .{
        .info = vtableInfo,
        .verbose = vtableVerbose,
        .@"error" = vtableError,
        .exception = vtableException,
        .warn = vtableWarn,
        .debug = vtableDebug,
        .tool = vtableTool,
        .event = vtableEvent,
        .verboseEnabled = vtableVerboseEnabled,
        .getLogDetails = vtableGetLogDetails,
    };

    //
    // ILog.info.
    //
    fn vtableInfo(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.logInfo(message, null) catch |err| {
            reportLoggingFailure("log a message", err);
        };
    }

    //
    // ILog.verbose, which writes to the file only.
    //
    fn vtableVerbose(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.writeToFile("verbose", message, null) catch |err| {
            reportLoggingFailure("log a message", err);
        };
    }

    //
    // ILog.error.
    //
    fn vtableError(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.logError(message, null) catch |err| {
            reportLoggingFailure("log a message", err);
        };
    }

    //
    // ILog.exception: the message and the error's cause chain, which stands where the TypeScript writes "Stack trace: ".
    //
    fn vtableException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.logException(message, err) catch |logging_err| {
            reportLoggingFailure("log an exception", logging_err);
        };
    }

    //
    // Logs an exception to both files and the console.
    //
    fn logException(self: *FileLogger, message: []const u8, err: anyerror) !void {
        const chain = try utils.wrapped_error.formatErrorChain(self.allocator, err);
        defer self.allocator.free(chain);
        const full_message = try std.fmt.allocPrint(self.allocator, "{s}\nStack trace: {s}", .{ message, chain });
        defer self.allocator.free(full_message);
        try self.writeToFile("exception", full_message, null);
        try self.writeToErrorFile("exception", full_message, null);
        utils.console.errorFormat("[ERROR] {s}", .{message});
        utils.console.errorFormat("{s}", .{chain});
    }

    //
    // ILog.warn.
    //
    fn vtableWarn(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.logWarn(message, null) catch |err| {
            reportLoggingFailure("log a message", err);
        };
    }

    //
    // ILog.debug, which writes to the file only.
    //
    fn vtableDebug(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.writeToFile("debug", message, null) catch |err| {
            reportLoggingFailure("log a message", err);
        };
    }

    //
    // ILog.tool, which writes to the file only.
    //
    fn vtableTool(ptr: *anyopaque, tool_name: []const u8, data: IToolOutput) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.logTool(tool_name, data, null) catch |err| {
            reportLoggingFailure("log the output of a tool", err);
        };
    }

    //
    // ILog.event.
    //
    fn vtableEvent(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.logEvent(message, null) catch |err| {
            reportLoggingFailure("log an event", err);
        };
    }

    //
    // ILog.verboseEnabled: the main process does not need verbose logging by default, so never.
    //
    fn vtableVerboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    //
    // ILog.getLogDetails: the path of the log file and its header, read from the file on demand, not cached. The header is
    // everything up to and including the "--- Log Start ---" line, or the first 50 lines when there is no such line. Only the start of
    // the file is read (the TypeScript reads all of it), which gives the same answer unless the marker is after the read limit
    // or a file with no marker is longer than it. The marker is written first, when the log is created, so neither happens to a
    // log this logger made. A log file that cannot be read is an error, as it is in the TypeScript.
    //
    fn vtableGetLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        const head = try node_utils.fs.readFileHead(allocator, io, self.log_file, header_read_limit);
        if (std.mem.indexOf(u8, head, log_start_marker)) |marker_at| {
            return .{
                .logFilePath = self.log_file,
                .logHeader = head[0 .. marker_at + log_start_marker.len],
            };
        }
        var end: usize = head.len;
        var newline_count: usize = 0;
        for (head, 0..) |character, index| {
            if (character == '\n') {
                newline_count += 1;
                if (newline_count == 50) {
                    end = index;
                    break;
                }
            }
        }
        return .{
            .logFilePath = self.log_file,
            .logHeader = head[0..end],
        };
    }
};

//
// Appends text to a file, creating the file when it is not there (as fs.appendFile does).
//
pub fn appendToFile(io: std.Io, file_path: []const u8, content: []const u8) !void {
    // Opened for reading as well, because file.length needs read access on Windows, where Zig opens a file with
    // GENERIC_WRITE alone and the size query is refused. The Windows job failed with AccessDenied from this function
    // in the file-logger tests and in "fps-measurement appends a row of the time and the frame rate".
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
        .truncate = false,
        .read = true,
    });
    defer file.close(io);
    const length = try file.length(io);
    try file.writePositionalAll(io, content, length);
}

//
// Says on the console that the logger could not do something, because a log function has no way to return an error and a failure
// to log must not pass unseen.
//
fn reportLoggingFailure(what: []const u8, err: anyerror) void {
    utils.console.errorFormat("Photosphere could not {s}: {s}", .{ what, @errorName(err) });
}

//
// The "--- System Information ---" lines of a header. The TypeScript's Node, Electron and Chrome version lines do not exist here, so
// the version of Zig and the version of the app stand where they are. The platform and architecture names are the ones Node's
// os.platform() and os.arch() give.
//
fn buildSystemInformation(arena: std.mem.Allocator, io: std.Io, app_version: []const u8) ![]const u8 {
    _ = io;
    const platform = switch (builtin.os.tag) {
        .linux => if (builtin.abi.isAndroid()) "android" else "linux",
        .macos => "darwin",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    };
    const architecture = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        else => @tagName(builtin.cpu.arch),
    };
    var release: []const u8 = "unknown";
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const uname = std.posix.uname();
        release = try arena.dupe(u8, std.mem.sliceTo(&uname.release, 0));
    }
    return std.mem.join(arena, "\n", &.{
        "--- System Information ---",
        try std.fmt.allocPrint(arena, "Platform: {s}", .{platform}),
        try std.fmt.allocPrint(arena, "Architecture: {s}", .{architecture}),
        try std.fmt.allocPrint(arena, "OS Release: {s}", .{release}),
        try std.fmt.allocPrint(arena, "Zig Version: {s}", .{builtin.zig_version_string}),
        try std.fmt.allocPrint(arena, "Photosphere Version: {s}", .{app_version}),
    });
}

//
// The "--- Tool Versions ---" lines of a header: ImageMagick, FFmpeg and FFprobe. Where the version or the kind of ImageMagick is
// not known the line says "unknown", where the TypeScript would print "undefined". The Zig checks of FFmpeg and FFprobe cannot
// fail, they report the tool as not available, so the "error checking version" line exists for ImageMagick only.
//
fn buildToolVersions(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const image_magick_line = blk: {
        const status = tools.Image.verifyImageMagick(arena, io) catch {
            break :blk "ImageMagick: error checking version";
        };
        if (!status.available) {
            break :blk "ImageMagick: not found";
        }
        break :blk try std.fmt.allocPrint(arena, "ImageMagick: {s} ({s})", .{
            status.version orelse "unknown",
            if (status.@"type") |image_magick_type| @tagName(image_magick_type) else "unknown",
        });
    };
    const ffmpeg_status = tools.Video.verifyFfmpeg(arena, io);
    const ffmpeg_line = if (ffmpeg_status.available)
        try std.fmt.allocPrint(arena, "FFmpeg: {s}", .{ffmpeg_status.version orelse "unknown"})
    else
        "FFmpeg: not found";
    const ffprobe_status = tools.Video.verifyFfprobe(arena, io);
    const ffprobe_line = if (ffprobe_status.available)
        try std.fmt.allocPrint(arena, "FFprobe: {s}", .{ffprobe_status.version orelse "unknown"})
    else
        "FFprobe: not found";
    return std.mem.join(arena, "\n", &.{
        "--- Tool Versions ---",
        image_magick_line,
        ffmpeg_line,
        ffprobe_line,
    });
}

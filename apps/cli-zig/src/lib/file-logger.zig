const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const process_argv = @import("process-argv.zig");
const config = @import("config.zig");
const console = utils.console;
const ILog = utils.log.ILog;
const ILogDetails = utils.log.ILogDetails;
const IToolOutput = utils.log.IToolOutput;
const Date = utils.timestamp_provider.Date;
const Image = tools.Image;
const Video = tools.Video;
const ensureDirSync = node_utils.fs.ensureDirSync;
const registerTerminationCallback = node_utils.termination.registerTerminationCallback;

//
// The line of '=' characters that frames the headers and footers ('='.repeat(80)).
//
const separator = "=" ** 80;

//
// The marker at the end of the log file header.
//
const log_start_marker = "--- Log Start ---";

//
// Node's name for the platform (`os.platform()`).
//
fn osPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        .freebsd => "freebsd",
        else => @tagName(builtin.os.tag),
    };
}

//
// Node's name for the CPU architecture (`os.arch()`).
//
fn osArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}

//
// The operating system release (`os.release()`).
//
fn osRelease(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var versionInfo: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        versionInfo.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        if (std.os.windows.ntdll.RtlGetVersion(&versionInfo) != .SUCCESS) {
            return allocator.dupe(u8, "unknown");
        }
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ versionInfo.dwMajorVersion, versionInfo.dwMinorVersion, versionInfo.dwBuildNumber });
    }
    const uname = std.posix.uname();
    return allocator.dupe(u8, std.mem.sliceTo(&uname.release, 0));
}

//
// The runtime version (`process.version`). The Zig binary reports the Zig version it was built with.
//
fn processVersion() []const u8 {
    return "zig-" ++ builtin.zig_version_string;
}

//
// The current working directory (`process.cwd()`).
//
fn processCwd(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    return std.process.currentPathAlloc(io, allocator);
}

//
// Equivalent of JavaScript `value.toFixed(2)` for a non-negative value: picks the integer n for which
// n / 100 is closest to value (the larger n on a tie), using the exact binary value of the double.
//
pub fn toFixed2(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    const scaled: f128 = @as(f128, value) * 100;
    var hundredths: u128 = @intFromFloat(@floor(scaled));
    const fraction = scaled - @floor(scaled);
    if (fraction >= 0.5) {
        hundredths += 1;
    }
    return std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ hundredths / 100, hundredths % 100 });
}

//
// Appends text to a file (`fs.appendFile`).
//
fn appendFile(io: std.Io, filePath: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // Opened for reading too: on Windows reading the length of a write only handle is denied.
    const file = try cwd.openFile(io, filePath, .{ .mode = .read_write });
    defer file.close(io);
    const offset = try file.length(io);
    try file.writePositionalAll(io, content, offset);
}

//
// File logger that writes all logs to files in the Photosphere temp directory
//
pub const FileLogger = struct {
    // Allocator for the log's own memory (the process arena).
    allocator: std.mem.Allocator,

    // Io used for file access.
    io: std.Io,

    // Path of the log file.
    logFile: []const u8,

    // Path of the error log file.
    errorLogFile: []const u8,

    // When the logger was created.
    startTime: Date,

    // The command line of the command being logged.
    command: []const u8,

    // Set once the log has been closed; later messages are not written to the files.
    isClosed: bool,

    // True once an error, warning or exception has been written to the error log.
    hasErrors: bool,

    // True once the header of the error log has been written.
    errorFileHeaderWritten: bool,

    // The console log that every message is also written to.
    consoleLogger: ILog,

    // Serializes file writes (Zig only: messages can come from several threads).
    mutex: std.Io.Mutex,

    //
    // Creates the logger (TypeScript: the private constructor) and registers its termination callback.
    //
    fn init(self: *FileLogger, allocator: std.mem.Allocator, io: std.Io, consoleLogger: ILog, command: []const u8, logFile: []const u8, errorLogFile: []const u8, startTime: Date) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .logFile = logFile,
            .errorLogFile = errorLogFile,
            .startTime = startTime,
            .command = command,
            .isClosed = false,
            .hasErrors = false,
            .errorFileHeaderWritten = false,
            .consoleLogger = consoleLogger,
            .mutex = .init,
        };

        // Register termination callback to flush logs
        try registerTerminationCallback(io, .{ .context = self, .function = closeCallback });
    }

    //
    // The termination callback: closes the log.
    //
    fn closeCallback(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
        _ = io;
        _ = exitCode;
        const self: *FileLogger = @ptrCast(@alignCast(context.?));
        self.close();
    }

    //
    // Creates the log files under <tmp>/photosphere/logs, writes their headers and returns the logger.
    //
    pub fn create(allocator: std.mem.Allocator, io: std.Io, consoleLogger: ILog, command: []const u8) !*FileLogger {
        const startTime = Date{ .epochMilliseconds = std.Io.Clock.real.now(io).toMilliseconds() };

        // Create logs directory in Photosphere temp.
        //
        // getProcessTmpDir rather than os.tmpdir, so the logs land wherever the rest of this process's
        // temporary state lives. Under test that is the per-test TEST_TMP_DIR, which keeps one suite's
        // logs out of another's. It used to matter more: `hash-cache clear` deleted <tmp>/photosphere
        // outright, so with os.tmpdir every CLI process in the suite shared /tmp/photosphere/logs and one
        // process clearing the cache pulled the log directory out from under every other one. It now
        // deletes only the named database's cache directory, but the isolation is still worth having.
        const photosphereTempDir = try std.fs.path.join(allocator, &.{ try node_utils.fs.getProcessTmpDir(allocator, io), "photosphere" });
        const logsDir = try std.fs.path.join(allocator, &.{ photosphereTempDir, "logs" });
        try ensureDirSync(io, logsDir);

        // Create log file with timestamp
        const isoString = try startTime.toISOString(allocator);
        const timestamp = try allocator.dupe(u8, isoString[0..19]);
        for (timestamp) |*character| {
            if (character.* == ':' or character.* == '.') {
                character.* = '-';
            }
        }
        const logFile = try std.fs.path.join(allocator, &.{ logsDir, try std.fmt.allocPrint(allocator, "psi-{s}.log", .{timestamp}) });
        const errorLogFile = try std.fs.path.join(allocator, &.{ logsDir, try std.fmt.allocPrint(allocator, "psi-{s}-errors.log", .{timestamp}) });

        // Create the logger instance
        const logger = try allocator.create(FileLogger);
        try logger.init(allocator, io, consoleLogger, command, logFile, errorLogFile, startTime);

        // Write initial log headers for both files
        try logger.writeLogHeader();
        try logger.writeErrorLogHeader();

        return logger;
    }

    //
    // Writes the lines shared by both headers, from the first separator to the tool versions.
    //
    fn writeCommonHeader(self: *FileLogger, writer: *std.Io.Writer, title: []const u8) !void {
        const allocator = self.allocator;
        try writer.print("{s}\n", .{separator});
        try writer.print("{s}\n", .{title});
        try writer.print("Started: {s}\n", .{try self.startTime.toISOString(allocator)});
        try writer.print("Command: {s}\n", .{self.command});
        try writer.print("Working Directory: {s}\n", .{try processCwd(allocator, self.io)});
        try writer.print("{s}\n", .{separator});
        try writer.writeAll("\n");
        try writer.writeAll("--- System Information ---\n");
        try writer.print("Platform: {s}\n", .{osPlatform()});
        try writer.print("Architecture: {s}\n", .{osArch()});
        try writer.print("OS Release: {s}\n", .{try osRelease(allocator)});
        try writer.print("Node Version: {s}\n", .{processVersion()});
        try writer.writeAll("\n");
        try writer.writeAll("--- Photosphere Version ---\n");
        try writer.print("{s}\n", .{config.version});
        try writer.print("Build Commit: {s}\n", .{config.buildMetadata.commitHash});
        try writer.print("Build Date: {s}\n", .{config.buildMetadata.buildDate});
        try writer.print("Nightly Build: {}\n", .{config.buildMetadata.isNightly});
        try writer.writeAll("\n");
        try writer.writeAll("--- Tool Versions ---\n");
        try writer.print("{s}\n", .{try self.getImageMagickVersion()});
        try writer.print("{s}\n", .{try self.getFFmpegVersion()});
        try writer.print("{s}\n", .{try self.getFFprobeVersion()});
        try writer.writeAll("\n");
    }

    //
    // Writes the header of the log file.
    //
    fn writeLogHeader(self: *FileLogger) !void {
        var allocating_writer = std.Io.Writer.Allocating.init(self.allocator);
        const writer = &allocating_writer.writer;
        try self.writeCommonHeader(writer, "Photosphere CLI Log");
        try writer.writeAll("--- Command ---\n");
        const argv = process_argv.getArgv();
        try writer.print("{s}\n", .{try std.mem.join(self.allocator, " ", argv)});
        try writer.print("{s}\n", .{log_start_marker});

        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.logFile, .data = allocating_writer.written() });
    }

    //
    // Writes the header of the error log file.
    //
    fn writeErrorLogHeader(self: *FileLogger) !void {
        var allocating_writer = std.Io.Writer.Allocating.init(self.allocator);
        const writer = &allocating_writer.writer;
        try self.writeCommonHeader(writer, "Photosphere CLI Error Log");
        try writer.writeAll("If this file contains nothing below, it means there were no errors.\n");
        try writer.writeAll("\n");
        try writer.writeAll("--- Error Log Start ---\n");

        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.errorLogFile, .data = allocating_writer.written() });
        self.errorFileHeaderWritten = true;
    }

    //
    // Gets the ImageMagick line of the header.
    //
    fn getImageMagickVersion(self: *FileLogger) ![]const u8 {
        const result = Image.verifyImageMagick(self.allocator, self.io) catch {
            return "ImageMagick: error checking version";
        };
        if (result.available) {
            const kind = if (result.type) |imageMagickType| @tagName(imageMagickType) else "undefined";
            return std.fmt.allocPrint(self.allocator, "ImageMagick: {s} ({s})", .{ result.version orelse "undefined", kind });
        }
        else {
            return "ImageMagick: not found";
        }
    }

    //
    // Gets the FFmpeg line of the header.
    //
    fn getFFmpegVersion(self: *FileLogger) ![]const u8 {
        const result = Video.verifyFfmpeg(self.allocator, self.io);
        if (result.available) {
            return std.fmt.allocPrint(self.allocator, "FFmpeg: {s}", .{result.version orelse "undefined"});
        }
        else {
            return "FFmpeg: not found";
        }
    }

    //
    // Gets the FFprobe line of the header.
    //
    fn getFFprobeVersion(self: *FileLogger) ![]const u8 {
        const result = Video.verifyFfprobe(self.allocator, self.io);
        if (result.available) {
            return std.fmt.allocPrint(self.allocator, "FFprobe: {s}", .{result.version orelse "undefined"});
        }
        else {
            return "FFprobe: not found";
        }
    }

    //
    // Formats a log entry: `[<ISO timestamp>] [<LEVEL>] <message>\n`.
    //
    fn formatEntry(self: *FileLogger, buffer_allocator: std.mem.Allocator, level: []const u8, message: []const u8) ![]const u8 {
        const now = Date{ .epochMilliseconds = std.Io.Clock.real.now(self.io).toMilliseconds() };
        const timestamp = try now.toISOString(buffer_allocator);
        const upper_level = try std.ascii.allocUpperString(buffer_allocator, level);
        return std.fmt.allocPrint(buffer_allocator, "[{s}] [{s}] {s}\n", .{ timestamp, upper_level, message });
    }

    //
    // Appends a message to the log file. Write errors are ignored: logging must not break the app.
    // (TypeScript queues the entries and appends them asynchronously; Zig appends them directly.)
    //
    fn writeToFile(self: *FileLogger, level: []const u8, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isClosed) {
            return;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const logEntry = self.formatEntry(arena.allocator(), level, message) catch return;
        appendFile(self.io, self.logFile, logEntry) catch {
            // Silently ignore file write errors - we don't want logging to break the app
        };
    }

    //
    // Appends a message to the error log file. Write errors are ignored: logging must not break the app.
    //
    fn writeToErrorFile(self: *FileLogger, level: []const u8, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isClosed) {
            return;
        }

        self.hasErrors = true;

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const logEntry = self.formatEntry(arena.allocator(), level, message) catch return;
        appendFile(self.io, self.errorLogFile, logEntry) catch {
            // Silently ignore file write errors - we don't want logging to break the app
        };
    }

    //
    // Gets the ILog interface for this logger.
    //
    pub fn ilog(self: *FileLogger) ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ILog functions of this logger.
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
    pub fn verboseEnabled(self: *FileLogger) bool {
        return self.consoleLogger.verboseEnabled();
    }

    //
    // Logs an informational message.
    //
    pub fn info(self: *FileLogger, message: []const u8) void {
        self.writeToFile("info", message);
        self.consoleLogger.info(message);
    }

    //
    // Logs a verbose message.
    //
    pub fn verbose(self: *FileLogger, message: []const u8) void {
        self.writeToFile("verbose", message);
        self.consoleLogger.verbose(message);
    }

    //
    // Logs an error message.
    //
    pub fn @"error"(self: *FileLogger, message: []const u8) void {
        self.writeToFile("error", message);
        self.writeToErrorFile("error", message);
        self.consoleLogger.@"error"(message);
    }

    //
    // Logs a message and an error with its cause chain.
    //
    pub fn exception(self: *FileLogger, message: []const u8, err: anyerror) void {
        var buffer: [16 * 1024]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&buffer);
        fixed_writer.print("{s}\nStack trace: ", .{message}) catch {};
        utils.wrapped_error.writeErrorChain(&fixed_writer, err) catch {};
        const fullMessage = fixed_writer.buffered();
        self.writeToFile("exception", fullMessage);
        self.writeToErrorFile("exception", fullMessage);
        self.consoleLogger.exception(message, err);
    }

    //
    // Logs a warning.
    //
    pub fn warn(self: *FileLogger, message: []const u8) void {
        self.writeToFile("warn", message);
        self.writeToErrorFile("warn", message);
        self.consoleLogger.warn(message);
    }

    //
    // Logs a debug message.
    //
    pub fn debug(self: *FileLogger, message: []const u8) void {
        self.writeToFile("debug", message);
        self.consoleLogger.debug(message);
    }

    //
    // Logs the output of an external tool.
    //
    pub fn tool(self: *FileLogger, toolName: []const u8, data: IToolOutput) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        if (data.stdout) |stdout| {
            if (stdout.len > 0) {
                const text = std.fmt.allocPrint(arena.allocator(), "== {s} stdout ==\n{s}", .{ toolName, stdout }) catch "";
                self.writeToFile("tool", text);
            }
        }
        if (data.stderr) |stderr| {
            if (stderr.len > 0) {
                const text = std.fmt.allocPrint(arena.allocator(), "== {s} stderr ==\n{s}", .{ toolName, stderr }) catch "";
                self.writeToFile("tool", text);
            }
        }
        self.consoleLogger.tool(toolName, data);
    }

    //
    // Logs an event.
    //
    pub fn event(self: *FileLogger, message: []const u8) void {
        self.writeToFile("event", message);
        self.consoleLogger.event(message);
    }

    //
    // Gets details about the active log file for inclusion in bug reports.
    // The header is read from the log file on demand, not cached.
    //
    pub fn getLogDetails(self: *FileLogger, allocator: std.mem.Allocator, io: std.Io) !ILogDetails {
        return .{
            .logFilePath = self.logFile,
            .logHeader = try self.readLogHeader(allocator, io),
        };
    }

    //
    // Reads the header section of the log file (everything up to "--- Log Start ---").
    //
    fn readLogHeader(self: *FileLogger, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        const logContent = try std.Io.Dir.cwd().readFileAlloc(io, self.logFile, allocator, .unlimited);
        const logStartIndex = std.mem.indexOf(u8, logContent, log_start_marker) orelse {
            // No "--- Log Start ---" marker found, return the first 50 lines.
            var line_count: usize = 0;
            var end: usize = 0;
            while (end < logContent.len) {
                if (logContent[end] == '\n') {
                    line_count += 1;
                    if (line_count == 50) {
                        break;
                    }
                }
                end += 1;
            }
            return logContent[0..end];
        };

        // Return everything up to (and including) the "--- Log Start ---" line.
        return logContent[0 .. logStartIndex + log_start_marker.len];
    }

    //
    // Write final log footer when command completes and flush all pending writes
    //
    pub fn close(self: *FileLogger) void {
        self.mutex.lockUncancelable(self.io);
        if (self.isClosed) {
            self.mutex.unlock(self.io);
            return;
        }

        self.isClosed = true;
        const hasErrors = self.hasErrors;

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const endTime = Date{ .epochMilliseconds = std.Io.Clock.real.now(self.io).toMilliseconds() };
        const duration = endTime.epochMilliseconds - self.startTime.epochMilliseconds;
        const endIso = endTime.toISOString(allocator) catch "";
        const seconds = toFixed2(allocator, @as(f64, @floatFromInt(duration)) / 1000) catch "";

        const footer = std.fmt.allocPrint(allocator, "\n--- Log End ---\nCompleted: {s}\nDuration: {d}ms ({s}s)\n{s}\n", .{ endIso, duration, seconds, separator }) catch "";
        appendFile(self.io, self.logFile, footer) catch {
            // Silently ignore file write errors during close
        };

        // Add footer to error log if errors were logged
        if (hasErrors) {
            const errorFooter = std.fmt.allocPrint(allocator, "\n--- Error Log End ---\nCompleted: {s}\n{s}\n", .{ endIso, separator }) catch "";
            appendFile(self.io, self.errorLogFile, errorFooter) catch {
                // Silently ignore file write errors during close
            };
        }
        self.mutex.unlock(self.io);

        // Show error file location if errors were logged
        if (hasErrors) {
            console.log("");
            console.logFormat("Errors, warnings, and exceptions were logged to: {s}", .{self.errorLogFile});
        }
    }

    //
    // Get the path to the current log file
    //
    pub fn getLogFilePath(self: *FileLogger) []const u8 {
        return self.logFile;
    }

    //
    // Check if any errors, warnings, or exceptions were logged
    //
    pub fn hasLoggedErrors(self: *FileLogger) bool {
        return self.hasErrors;
    }

    //
    // Get the path to the error log file
    //
    pub fn getErrorLogFilePath(self: *FileLogger) []const u8 {
        return self.errorLogFile;
    }

    //
    // ILog.info for this implementation.
    //
    fn infoErased(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.info(message);
    }

    //
    // ILog.verbose for this implementation.
    //
    fn verboseErased(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.verbose(message);
    }

    //
    // ILog.error for this implementation.
    //
    fn errorErased(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.@"error"(message);
    }

    //
    // ILog.exception for this implementation.
    //
    fn exceptionErased(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.exception(message, err);
    }

    //
    // ILog.warn for this implementation.
    //
    fn warnErased(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.warn(message);
    }

    //
    // ILog.debug for this implementation.
    //
    fn debugErased(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.debug(message);
    }

    //
    // ILog.tool for this implementation.
    //
    fn toolErased(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.tool(toolName, data);
    }

    //
    // ILog.event for this implementation.
    //
    fn eventErased(ptr: *anyopaque, message: []const u8) void {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        self.event(message);
    }

    //
    // ILog.verboseEnabled for this implementation.
    //
    fn verboseEnabledErased(ptr: *anyopaque) bool {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        return self.verboseEnabled();
    }

    //
    // ILog.getLogDetails for this implementation.
    //
    fn getLogDetailsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        const self: *FileLogger = @ptrCast(@alignCast(ptr));
        return self.getLogDetails(allocator, io);
    }
};

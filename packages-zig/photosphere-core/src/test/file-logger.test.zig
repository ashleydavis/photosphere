const std = @import("std");
const utils = @import("utils-zig");
const file_logger = @import("../lib/file-logger.zig");

const FileLogger = file_logger.FileLogger;

//
// What every test of the file logger needs: a directory the test owns to log in, and the console output kept in memory (the
// test program's own standard output is how the build system talks to it, so nothing under test may write there).
//
const Fixture = struct {
    // The directory the test owns.
    tmp: std.testing.TmpDir,
    // The absolute path of the directory to log in, a folder of the one the test owns.
    logs_dir: []u8,
    // What the code under test wrote to standard output through the console.
    console_out: std.Io.Writer.Allocating,
    // What the code under test wrote to standard error through the console.
    console_err: std.Io.Writer.Allocating,

    //
    // Makes the directory and starts capturing the console. Call it on a Fixture that stays where it is.
    //
    fn start(self: *Fixture) !void {
        const allocator = std.testing.allocator;
        self.console_out = std.Io.Writer.Allocating.init(allocator);
        self.console_err = std.Io.Writer.Allocating.init(allocator);
        utils.console.setCapture(&self.console_out.writer, &self.console_err.writer);
        self.tmp = std.testing.tmpDir(.{});
        const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
        defer allocator.free(current_path);
        self.logs_dir = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &self.tmp.sub_path, "logs" });
    }

    //
    // Stops capturing and removes everything the test owns.
    //
    fn stop(self: *Fixture) void {
        utils.console.setCapture(null, null);
        self.console_out.deinit();
        self.console_err.deinit();
        std.testing.allocator.free(self.logs_dir);
        self.tmp.cleanup();
    }

    //
    // Makes a logger that logs in the directory.
    //
    fn createLogger(self: *Fixture) !*FileLogger {
        return FileLogger.init(std.testing.allocator, std.testing.io, self.logs_dir, "9.8.7");
    }
};

//
// Reads a whole file. The caller frees it.
//
fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
}

//
// Counts the lines of text that contain the needle.
//
fn countLinesContaining(text: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) {
            count += 1;
        }
    }
    return count;
}

test "init makes the logs directory and a log file and an error log file named for the start time, with headers" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    try std.testing.expectEqualStrings(fixture.logs_dir, logger.getLogsDirectory());
    const log_name = std.fs.path.basename(logger.getLogFilePath());
    const error_name = std.fs.path.basename(logger.getErrorLogFilePath());
    try std.testing.expect(std.mem.startsWith(u8, log_name, "photosphere-20"));
    try std.testing.expect(std.mem.endsWith(u8, log_name, ".log"));
    try std.testing.expectEqual(@as(usize, "photosphere-2026-10-07T12-34-56.log".len), log_name.len);
    try std.testing.expect(std.mem.indexOfAny(u8, log_name, ":.") == std.mem.lastIndexOfScalar(u8, log_name, '.'));
    try std.testing.expect(std.mem.endsWith(u8, error_name, "-errors.log"));
    try std.testing.expectEqualStrings(log_name[0 .. log_name.len - ".log".len], error_name[0 .. error_name.len - "-errors.log".len]);
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.startsWith(u8, log_text, "=" ** 80 ++ "\nPhotosphere Desktop Log\nStarted: 20"));
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\n--- System Information ---\nPlatform: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\nArchitecture: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\nOS Release: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\nPhotosphere Version: 9.8.7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\n--- Tool Versions ---\nImageMagick: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\nFFmpeg: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\nFFprobe: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, log_text, "\n--- Log Start ---\n"));
    const error_text = try readFile(logger.getErrorLogFilePath());
    defer std.testing.allocator.free(error_text);
    try std.testing.expect(std.mem.startsWith(u8, error_text, "=" ** 80 ++ "\nPhotosphere Desktop Error Log\nStarted: 20"));
    try std.testing.expect(std.mem.indexOf(u8, error_text, "\nPhotosphere Version: 9.8.7\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, error_text, "\nIf this file contains nothing below, it means there were no errors.\n\n--- Error Log Start ---\n"));
}

test "init fails with a message when the logs directory cannot be made" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    // A file where the directory should go.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs", .data = "not a directory" });
    try std.testing.expectError(error.Thrown, fixture.createLogger());
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.errorMessage(error.Thrown), "Path exists but is not a directory") != null);
}

test "info, verbose, debug, event and tool go to the log file only, with the level in capitals" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    const log = logger.ilog();
    log.info("an info line");
    log.verbose("a verbose line");
    log.debug("a debug line");
    log.event("an event line");
    log.tool("magick", .{ .stdout = "tool out", .stderr = "tool err" });
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [INFO] an info line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [VERBOSE] a verbose line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [DEBUG] a debug line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [EVENT] an event line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [TOOL] == magick stdout ==\ntool out\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [TOOL] == magick stderr ==\ntool err\n") != null);
    // Every line starts with the time, like [2026-10-07T12:34:56.789Z].
    const info_at = std.mem.indexOf(u8, log_text, "] [INFO] an info line").?;
    try std.testing.expectEqual(@as(u8, '['), log_text[info_at - 25]);
    try std.testing.expectEqual(@as(u8, 'Z'), log_text[info_at - 1]);
    const error_text = try readFile(logger.getErrorLogFilePath());
    defer std.testing.allocator.free(error_text);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "an info line") == null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "an event line") == null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "Error Log End") == null);
    try std.testing.expect(!logger.hasLoggedErrors());
    // The console gets the info and the event, as the Electron log's does.
    try std.testing.expectEqualStrings("an info line\n[EVENT] an event line\n", fixture.console_out.writer.buffered());
}

test "error, warn and exception go to both files and the error file ends with a footer" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    const log = logger.ilog();
    log.@"error"("an error line");
    log.warn("a warn line");
    log.exception("an exception line", error.OutOfMemory);
    try std.testing.expect(logger.hasLoggedErrors());
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    const error_text = try readFile(logger.getErrorLogFilePath());
    defer std.testing.allocator.free(error_text);
    for ([_][]const u8{ log_text, error_text }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, text, "] [ERROR] an error line\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "] [WARN] a warn line\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "] [EXCEPTION] an exception line\nStack trace: ") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, error_text, "\n--- Error Log End ---\nCompleted: 20") != null);
    try std.testing.expect(std.mem.endsWith(u8, error_text, "=" ** 80 ++ "\n"));
    const console_text = fixture.console_err.writer.buffered();
    const error_at = std.mem.indexOf(u8, console_text, "[ERROR] an error line\n").?;
    const warn_at = std.mem.indexOf(u8, console_text, "a warn line\n").?;
    const exception_at = std.mem.indexOf(u8, console_text, "[ERROR] an exception line\n").?;
    try std.testing.expect(error_at < warn_at);
    try std.testing.expect(warn_at < exception_at);
}

test "footer of the log file says when it ended and how long it ran" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    logger.ilog().info("something");
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\n\n--- Log End ---\nCompleted: 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "\nDuration: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "s)\n" ++ "=" ** 80 ++ "\n") != null);
    // The line logged before the footer comes before it.
    try std.testing.expect(std.mem.indexOf(u8, log_text, "something").? < std.mem.indexOf(u8, log_text, "--- Log End ---").?);
}

test "nothing is logged after close, and closing again does nothing" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    try logger.close();
    logger.ilog().info("too late");
    logger.ilog().@"error"("too late as well");
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "too late") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log_text, "--- Log End ---"));
    try std.testing.expect(!logger.hasLoggedErrors());
}

test "handleWorkerLogMessage writes each level with the source" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    try logger.handleWorkerLogMessage(.{ .level = .info, .message = "w info", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .verbose, .message = "w verbose", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .@"error", .message = "w error", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .exception, .message = "w exception", .@"error" = "at somewhere:1", .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .exception, .message = "w exception without stack", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .warn, .message = "w warn", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .debug, .message = "w debug", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .event, .message = "w event", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .tool, .message = "ffmpeg", .@"error" = null, .tool_data = .{ .stdout = "out text", .stderr = null } }, "Worker 1");
    try logger.handleWorkerLogMessage(.{ .level = .tool, .message = "no data", .@"error" = null, .tool_data = null }, "Worker 1");
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [INFO] [Worker 1] w info\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [VERBOSE] [Worker 1] w verbose\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [ERROR] [Worker 1] w error\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [EXCEPTION] [Worker 1] w exception\nat somewhere:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [EXCEPTION] [Worker 1] w exception without stack\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [WARN] [Worker 1] w warn\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [DEBUG] [Worker 1] w debug\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [EVENT] [Worker 1] w event\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [TOOL] [Worker 1] == ffmpeg stdout ==\nout text\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "ffmpeg stderr") == null);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "no data") == null);
    const error_text = try readFile(logger.getErrorLogFilePath());
    defer std.testing.allocator.free(error_text);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "] [ERROR] [Worker 1] w error\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "] [EXCEPTION] [Worker 1] w exception\nat somewhere:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "] [WARN] [Worker 1] w warn\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "w info") == null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "w verbose") == null);
    // What the console gets, as the TypeScript prints it.
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_out.writer.buffered(), "[Worker 1] w info\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_out.writer.buffered(), "[EVENT] [Worker 1] w event\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_out.writer.buffered(), "[Worker 1] == ffmpeg stdout ==\nout text\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_err.writer.buffered(), "[ERROR] [Worker 1] w error\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_err.writer.buffered(), "[ERROR] [Worker 1] at somewhere:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_err.writer.buffered(), "[Worker 1] w warn\n") != null);
}

test "getLogDetails gives the path and the header up to the start marker, not the lines logged after it" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    logger.ilog().info("after the header");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const details = try logger.ilog().getLogDetails(arena_state.allocator(), std.testing.io);
    try std.testing.expectEqualStrings(logger.getLogFilePath(), details.logFilePath.?);
    try std.testing.expect(std.mem.startsWith(u8, details.logHeader, "=" ** 80 ++ "\nPhotosphere Desktop Log\n"));
    try std.testing.expect(std.mem.endsWith(u8, details.logHeader, "\n--- Log Start ---"));
    try std.testing.expect(std.mem.indexOf(u8, details.logHeader, "after the header") == null);
    try logger.close();
}

test "getLogDetails gives the first 50 lines when the file has no start marker" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    var line_number: usize = 1;
    while (line_number <= 60) : (line_number += 1) {
        try content.print(std.testing.allocator, "line {d}\n", .{line_number});
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = logger.getLogFilePath(), .data = content.items });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const details = try logger.ilog().getLogDetails(arena_state.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 50), std.mem.count(u8, details.logHeader, "\n") + 1);
    try std.testing.expect(std.mem.startsWith(u8, details.logHeader, "line 1\nline 2\n"));
    try std.testing.expect(std.mem.endsWith(u8, details.logHeader, "\nline 50"));
}

test "getLogDetails fails when the log file is gone" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, logger.getLogFilePath());
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.FileNotFound, logger.ilog().getLogDetails(arena_state.allocator(), std.testing.io));
}

test "verboseEnabled is false, and fromILog finds the logger behind its ILog only" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    try std.testing.expect(!logger.ilog().verboseEnabled());
    try std.testing.expect(FileLogger.fromILog(logger.ilog()).? == logger);
    var console_log: utils.log.ConsoleLog = .{ .verbose_enabled = false };
    try std.testing.expect(FileLogger.fromILog(console_log.ilog()) == null);
}

test "a failed write is reported on the console and the lines after it are still written" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    // Put a directory where the log file is, so that appending to it fails.
    try std.Io.Dir.cwd().deleteFile(std.testing.io, logger.getLogFilePath());
    try std.Io.Dir.cwd().createDir(std.testing.io, logger.getLogFilePath(), .default_dir);
    logger.ilog().info("lost line");
    try std.testing.expectError(error.IsDir, logger.close());
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_err.writer.buffered(), "Photosphere could not write to the log file ") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.console_err.writer.buffered(), "IsDir") != null);
}

test "lines logged from several threads at once are all written whole" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, logManyLines, .{ logger, index });
    }
    for (threads) |thread| {
        thread.join();
    }
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    var thread_index: usize = 0;
    while (thread_index < thread_count) : (thread_index += 1) {
        var needle_buffer: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buffer, "] [INFO] thread {d} line ", .{thread_index});
        try std.testing.expectEqual(@as(usize, 200), countLinesContaining(log_text, needle));
    }
    // Lines of one thread are in the order that thread logged them.
    const first_at = std.mem.indexOf(u8, log_text, "thread 0 line 0\n").?;
    const last_at = std.mem.indexOf(u8, log_text, "thread 0 line 199\n").?;
    try std.testing.expect(first_at < last_at);
}

//
// Logs 200 numbered lines from the thread with the index.
//
fn logManyLines(logger: *FileLogger, thread_index: usize) void {
    var line_number: usize = 0;
    while (line_number < 200) : (line_number += 1) {
        var buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "thread {d} line {d}", .{ thread_index, line_number }) catch @panic("the message did not fit the buffer");
        logger.ilog().info(message);
    }
}

test "handleWorkerLogMessage treats an empty error text as no error text, as the TypeScript's truthiness test does" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const logger = try fixture.createLogger();
    defer logger.deinit();
    try logger.handleWorkerLogMessage(.{ .level = .exception, .message = "w exception empty stack", .@"error" = "", .tool_data = null }, "Worker 1");
    try logger.close();
    const log_text = try readFile(logger.getLogFilePath());
    defer std.testing.allocator.free(log_text);
    try std.testing.expect(std.mem.indexOf(u8, log_text, "] [EXCEPTION] [Worker 1] w exception empty stack\n") != null);
    try std.testing.expectEqualStrings("[ERROR] [Worker 1] w exception empty stack\n", fixture.console_err.writer.buffered());
}

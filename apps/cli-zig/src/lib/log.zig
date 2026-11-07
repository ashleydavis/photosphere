const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const process_argv = @import("process-argv.zig");
const config = @import("config.zig");
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const FileLog = utils.file_log.FileLog;
const ConsoleLog = utils.log.ConsoleLog;
const registerTerminationCallback = node_utils.termination.registerTerminationCallback;

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
// Makes the CLI's log and returns it, for main to pass down: Ziggy's file log, writing psi-<start time>.log and
// psi-<start time>-errors.log under <process tmp dir>/photosphere/logs, or with file logging disabled Ziggy's console log. The options
// decide what the console shows; the log file always gets every line. The file log is closed, writing its footers, when the process
// ends, by a termination callback.
// consoleLog is the console log the program starts with, which finding the header writes to. toolRunner runs the ImageMagick and FFmpeg
// built into the program, whose versions the file log's header gives.
// The log is allocated with the allocator and must live until the process exits.
//
pub fn configureLog(allocator: std.mem.Allocator, io: std.Io, consoleLog: ILog, toolRunner: InProcessRunner, options: ILogOptions) !utils.log.ILog {
    if (options.disableFileLogging orelse false) {
        return ConsoleLog.initWith(.{
            .verbose = options.verbose orelse false,
            .debug = options.debug orelse false,
            .tools = options.tools orelse false,
        });
    }

    // getProcessTmpDir rather than the operating system's temporary directory, so the logs land wherever the rest of this process's
    // temporary state lives. Under test that is the per-test directory, which keeps one suite's logs out of another's.
    const logsDir = try node_utils.path.join(allocator, &.{ try node_utils.fs.getProcessTmpDir(allocator, io), "photosphere", "logs" });
    const userArgs = process_argv.userArgs();
    const joined = try std.mem.join(allocator, " ", userArgs);
    const command = if (joined.len > 0) joined else "unknown";
    const logger = try FileLog.start(allocator, io, .{
        .file_prefix = "psi",
        .title = "Photosphere CLI Log",
        .logs_dir = logsDir,
        .command = command,
        .version = config.version,
        // The file log does not exist until this returns, so what finding the header writes goes to the console log.
        .header_lines = try headerLines(allocator, io, consoleLog, toolRunner),
        .verbose = options.verbose orelse false,
        .debug = options.debug orelse false,
        .tools = options.tools orelse false,
    });
    try registerTerminationCallback(io, .{
        .context = logger,
        .function = closeAtExit,
    });
    return logger.ilog();
}

//
// The termination callback: closes the file log, writing its footers. A failure to write them is reported on the console.
//
fn closeAtExit(context: ?*anyopaque, io: std.Io, _: ILog, exitCode: u8) anyerror!void {
    _ = exitCode;
    const logger: *FileLog = @ptrCast(@alignCast(context.?));
    logger.close(io) catch |err| {
        utils.console.errorFormat("Could not write the end of the log file {s}: {s}", .{ logger.getLogFilePath(), @errorName(err) });
    };
}

//
// The CLI's own lines of the log files' header: its build, the versions of the tools built into it and the whole command line.
//
fn headerLines(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner) ![]const []const u8 {
    const imageMagick = try tools.Image.verifyImageMagick(allocator, io, log, toolRunner);
    const ffmpeg = try tools.Video.verifyFfmpeg(allocator, io, log, toolRunner);
    const ffprobe = try tools.Video.verifyFfprobe(allocator, io, log, toolRunner);
    return try allocator.dupe([]const u8, &.{
        "--- Photosphere Version ---",
        config.version,
        try std.fmt.allocPrint(allocator, "Build Commit: {s}", .{config.buildMetadata.commitHash}),
        try std.fmt.allocPrint(allocator, "Build Date: {s}", .{config.buildMetadata.buildDate}),
        try std.fmt.allocPrint(allocator, "Nightly Build: {}", .{config.buildMetadata.isNightly}),
        "",
        "--- Tool Versions ---",
        if (imageMagick.available) try std.fmt.allocPrint(allocator, "ImageMagick: {s}", .{imageMagick.version orelse "undefined"}) else "ImageMagick: not found",
        if (ffmpeg.available) try std.fmt.allocPrint(allocator, "FFmpeg: {s}", .{ffmpeg.version orelse "undefined"}) else "FFmpeg: not found",
        if (ffprobe.available) try std.fmt.allocPrint(allocator, "FFprobe: {s}", .{ffprobe.version orelse "undefined"}) else "FFprobe: not found",
        "",
        "--- Command ---",
        try std.mem.join(allocator, " ", process_argv.getArgv()),
    });
}

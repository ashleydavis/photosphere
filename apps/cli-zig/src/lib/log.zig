const std = @import("std");
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
// Configures the log of the calling thread, the CLI's main thread: Ziggy's file log, writing psi-<start time>.log and
// psi-<start time>-errors.log under <process tmp dir>/photosphere/logs, or with file logging disabled Ziggy's console log. The options
// decide what the console shows; the log file always gets every line. The file log is closed, writing its footers, when the process
// ends, by a termination callback.
// toolRunner runs the ImageMagick and FFmpeg built into the program, whose versions the file log's header gives.
// The log is allocated with the allocator and must live until the process exits.
//
pub fn configureLog(allocator: std.mem.Allocator, io: std.Io, toolRunner: InProcessRunner, options: ILogOptions) !void {
    if (options.disableFileLogging orelse false) {
        const consoleLog = try allocator.create(ConsoleLog);
        consoleLog.* = .{
            .verbose_enabled = options.verbose orelse false,
            .debug_enabled = options.debug orelse false,
            .tools_enabled = options.tools orelse false,
        };
        utils.log.setLog(consoleLog.ilog());
        return;
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
        .header_lines = try headerLines(allocator, io, toolRunner),
        .verbose = options.verbose orelse false,
        .debug = options.debug orelse false,
        .tools = options.tools orelse false,
    });
    try registerTerminationCallback(io, .{
        .context = logger,
        .function = closeAtExit,
    });
}

//
// The termination callback: closes the file log, writing its footers. A failure to write them is reported on the console.
//
fn closeAtExit(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
    _ = exitCode;
    const logger: *FileLog = @ptrCast(@alignCast(context.?));
    logger.close(io) catch |err| {
        utils.console.errorFormat("Could not write the end of the log file {s}: {s}", .{ logger.getLogFilePath(), @errorName(err) });
    };
}

//
// The CLI's own lines of the log files' header: its build, the versions of the tools built into it and the whole command line.
//
fn headerLines(allocator: std.mem.Allocator, io: std.Io, toolRunner: InProcessRunner) ![]const []const u8 {
    const imageMagick = try tools.Image.verifyImageMagick(allocator, io, toolRunner);
    const ffmpeg = try tools.Video.verifyFfmpeg(allocator, io, toolRunner);
    const ffprobe = try tools.Video.verifyFfprobe(allocator, io, toolRunner);
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

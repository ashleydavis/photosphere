const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const log_module = @import("../lib/log.zig");
const file_logger = @import("../lib/file-logger.zig");
const pc = @import("../lib/picocolors.zig");
const prompts = @import("../lib/clack/prompts.zig");
const commander = @import("../lib/commander.zig");
const config = @import("../lib/config.zig");
const open_module = @import("../lib/third-party/open.zig");
const configureLog = log_module.configureLog;
const exit = node_utils.termination.exit;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const text = prompts.text;
const isCancel = prompts.isCancel;
const intro = prompts.intro;
const outro = prompts.outro;
const ValidateFn = prompts.ValidateFn;
const Image = tools.Image;
const Video = tools.Video;
const version = config.version;
const open = open_module.open;
const jsLength = commander.jsLength;

//
// Options of the bug command.
//
pub const IBugReportCommandOptions = struct {
    //
    // Enables verbose logging.
    //
    verbose: ?bool = null,

    //
    // Enables tool output logging.
    //
    tools: ?bool = null,

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes: ?bool = null,

    //
    // Don't open the browser automatically
    //
    noBrowser: ?bool = null,
};

//
// The details of the bug that go into the report (TypeScript: the `bugInfo` object).
//
pub const IBugInfo = struct {
    // The title of the GitHub issue.
    title: []const u8,

    // What happened.
    description: []const u8,

    // The numbered steps to reproduce the bug, one per line.
    stepsToReproduce: []const u8,

    // What was expected to happen.
    expectedBehavior: []const u8,

    // What actually happened.
    actualBehavior: []const u8,
};

//
// The system the bug happened on (TypeScript: the object getSystemInfo returns).
//
pub const ISystemInfo = struct {
    // `os.platform()`.
    platform: []const u8,

    // `os.arch()`.
    arch: []const u8,

    // `os.release()`.
    release: []const u8,

    // `process.version`.
    nodeVersion: []const u8,

    // `process.cwd()`.
    workingDirectory: []const u8,
};

//
// The versions of the media tools (TypeScript: the object getToolVersions returns).
//
pub const IToolVersions = struct {
    // The ImageMagick version line.
    imagemagick: []const u8,

    // The ffmpeg version line.
    ffmpeg: []const u8,

    // The ffprobe version line.
    ffprobe: []const u8,
};

//
// The characters JavaScript's `String.prototype.trim` removes (the ASCII ones).
//
const js_whitespace = " \t\n\r\x0b\x0c";

//
// Validates the bug title.
//
fn validateTitle(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or std.mem.trim(u8, value.?, js_whitespace).len == 0) {
        return "Please provide a title for the bug report";
    }
    if (jsLength(std.mem.trim(u8, value.?, js_whitespace)) > 100) {
        return "Title should be under 100 characters";
    }
    return null;
}

//
// Validates the bug description.
//
fn validateDescription(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or std.mem.trim(u8, value.?, js_whitespace).len == 0) {
        return "Please provide a description of the bug";
    }
    return null;
}

//
// Validates a step to reproduce: the first one is required (the context is the current step number).
//
fn validateStep(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    const stepNumber: *const usize = @ptrCast(@alignCast(context.?));
    if (stepNumber.* == 1 and (value == null or std.mem.trim(u8, value.?, js_whitespace).len == 0)) {
        return "Please provide at least one step";
    }
    return null;
}

//
// Validates the expected behavior.
//
fn validateExpectedBehavior(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or std.mem.trim(u8, value.?, js_whitespace).len == 0) {
        return "Please describe what you expected to happen";
    }
    return null;
}

//
// Validates the actual behavior.
//
fn validateActualBehavior(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    if (value == null or std.mem.trim(u8, value.?, js_whitespace).len == 0) {
        return "Please describe what actually happened";
    }
    return null;
}

//
// Ends the bug report when a prompt was cancelled.
//
fn cancelled(io: std.Io) noreturn {
    outro(io, "Bug report cancelled.", .{}) catch {};
    exit(io, 0);
}

//
// Command that generates a bug report for GitHub
//
pub fn bugReportCommand(allocator: std.mem.Allocator, io: std.Io, options: *const IBugReportCommandOptions) !void {

    try configureLog(allocator, io, .{
        .verbose = options.verbose,
        .tools = options.tools,
        .disableFileLogging = true,
    });

    try intro(io, try pc.blue(allocator, "\u{1F41B} Photosphere Bug Report\n"), .{});

    // Get system information
    const systemInfo = try getSystemInfo(allocator, io);
    const toolVersions = try getToolVersions(allocator, io);

    // Get latest log file and header
    const latestLogFile = getLatestLogFile(allocator, io);
    const logHeader = try getLogHeader(allocator, io, latestLogFile);

    var bugInfo: IBugInfo = undefined;

    if (!(options.yes orelse false)) {
        // Prompt user for bug report details

        const title = try text(allocator, io, .{
            .message = "Bug title (short summary):",
            .placeholder = "e.g., 'CLI crashes when adding large video files'",
            .validate = .{ .context = null, .function = validateTitle },
        });

        if (isCancel(title)) {
            cancelled(io);
        }

        const description = try text(allocator, io, .{
            .message = "Bug description (detailed explanation):",
            .placeholder = "Describe what happened in detail...",
            .validate = .{ .context = null, .function = validateDescription },
        });

        if (isCancel(description)) {
            cancelled(io);
        }

        // Steps to reproduce

        var steps: std.ArrayList([]const u8) = .empty;
        var stepNumber: usize = 1;

        while (true) {
            const step = try text(allocator, io, .{
                .message = try std.fmt.allocPrint(allocator, "Step {d}:", .{stepNumber}),
                .placeholder = if (stepNumber == 1) "e.g., Run command 'psi add /path/to/photos'" else "Next step, or press Enter to finish",
                .validate = .{ .context = @ptrCast(&stepNumber), .function = validateStep },
            });

            if (isCancel(step)) {
                cancelled(io);
            }

            // (TypeScript also breaks when the step is undefined; the Zig prompt returns an empty string for it,
            // which the next check breaks on.)

            const stepText = std.mem.trim(u8, step.value, js_whitespace);
            if (stepText.len == 0 and stepNumber > 1) {
                break; // User finished entering steps
            }

            if (stepText.len > 0) {
                try steps.append(allocator, try std.fmt.allocPrint(allocator, "{d}. {s}", .{ stepNumber, stepText }));
                stepNumber += 1;
            }
        }

        const stepsToReproduce = try std.mem.join(allocator, "\n", steps.items);

        const expectedBehavior = try text(allocator, io, .{
            .message = "Expected behavior:",
            .placeholder = "What did you expect to happen?",
            .validate = .{ .context = null, .function = validateExpectedBehavior },
        });

        if (isCancel(expectedBehavior)) {
            cancelled(io);
        }

        const actualBehavior = try text(allocator, io, .{
            .message = "Actual behavior:",
            .placeholder = "What actually happened?",
            .validate = .{ .context = null, .function = validateActualBehavior },
        });

        if (isCancel(actualBehavior)) {
            cancelled(io);
        }

        bugInfo = .{
            .title = title.value,
            .description = description.value,
            .stepsToReproduce = stepsToReproduce,
            .expectedBehavior = expectedBehavior.value,
            .actualBehavior = actualBehavior.value,
        };
    }
    else {
        // Non-interactive mode - use generic template
        bugInfo = .{
            .title = "Bug Report",
            .description = "<!-- Please describe the bug you encountered -->",
            .stepsToReproduce = "1. \n2. \n3. ",
            .expectedBehavior = "<!-- What did you expect to happen? -->",
            .actualBehavior = "<!-- What actually happened? -->",
        };
    }

    // Generate bug report template (with log header)
    const bugReportTemplate = try generateBugReportTemplate(allocator, io, systemInfo, toolVersions, version, bugInfo, logHeader);

    // Create GitHub issue URL
    const githubUrl = try createGitHubIssueUrl(allocator, bugInfo.title, bugReportTemplate);

    // Prepare summary information
    const summaryInfo = try std.fmt.allocPrint(allocator, "Title: {s}\nPhotosphere Version: {s}\nSystem: {s} {s} ({s})\nLog File: {s}", .{
        bugInfo.title,
        version,
        systemInfo.platform,
        systemInfo.arch,
        systemInfo.release,
        latestLogFile orelse "None available",
    });

    const logInfo = if (latestLogFile != null)
        try std.fmt.allocPrint(allocator, "\n\n{s}\n{s}", .{ try pc.blue(allocator, "\u{1F4CE} Log File Information:"), try pc.dim(allocator, "The log file path is included in the bug report template.\nYou can attach it to the GitHub issue by dragging and dropping the file.") })
    else
        "";

    if (options.noBrowser orelse false) {
        try outro(io, try std.fmt.allocPrint(allocator, "{s}\n\n{s}{s}\n\n{s}\n{s}\n\n{s}", .{
            try pc.green(allocator, "\u{2713} Bug report generated successfully!"),
            summaryInfo,
            logInfo,
            try pc.yellow(allocator, "GitHub Issue URL:"),
            githubUrl,
            try pc.dim(allocator, "Copy and paste the URL above into your browser to create the issue."),
        }), .{});
    }
    else {
        if (open(allocator, io, githubUrl)) {
            try outro(io, try std.fmt.allocPrint(allocator, "{s}\n\n{s}{s}", .{ try pc.green(allocator, "\u{2713} Bug report opened in browser!"), summaryInfo, logInfo }), .{});
        }
        else |_| {
            try outro(io, try std.fmt.allocPrint(allocator, "{s}\n\n{s}{s}\n\n{s}\n{s}\n\n{s}", .{
                try pc.green(allocator, "\u{2713} Bug report generated successfully!"),
                summaryInfo,
                logInfo,
                try pc.red(allocator, "Failed to open browser. Here's the URL:"),
                githubUrl,
                try pc.yellow(allocator, "Please copy the URL above to submit the bug report."),
            }), .{});
        }
    }

    exit(io, 0);
}

//
// Gets the system the bug happened on.
//
pub fn getSystemInfo(allocator: std.mem.Allocator, io: std.Io) !ISystemInfo {
    return .{
        .platform = file_logger.osPlatform(),
        .arch = file_logger.osArch(),
        .release = try file_logger.osRelease(allocator),
        .nodeVersion = file_logger.processVersion(),
        .workingDirectory = try file_logger.processCwd(allocator, io),
    };
}

//
// Gets the versions of the media tools ("Not available" for a tool that cannot be run).
//
pub fn getToolVersions(allocator: std.mem.Allocator, io: std.Io) !IToolVersions {
    var versions: IToolVersions = .{
        .imagemagick = "Not available",
        .ffmpeg = "Not available",
        .ffprobe = "Not available",
    };

    if (Image.verifyImageMagick(allocator, io)) |imageMagickStatus| {
        if (imageMagickStatus.available and imageMagickStatus.version != null) {
            const kind = if (imageMagickStatus.type) |imageMagickType| @tagName(imageMagickType) else "unknown";
            versions.imagemagick = try std.fmt.allocPrint(allocator, "ImageMagick v{s} ({s})", .{ imageMagickStatus.version.?, kind });
        }
    }
    else |_| {
        // ImageMagick not available
    }

    const ffmpegStatus = Video.verifyFfmpeg(allocator, io);
    if (ffmpegStatus.available and ffmpegStatus.version != null) {
        versions.ffmpeg = try std.fmt.allocPrint(allocator, "ffmpeg v{s}", .{ffmpegStatus.version.?});
    }

    const ffprobeStatus = Video.verifyFfprobe(allocator, io);
    if (ffprobeStatus.available and ffprobeStatus.version != null) {
        versions.ffprobe = try std.fmt.allocPrint(allocator, "ffprobe v{s}", .{ffprobeStatus.version.?});
    }

    return versions;
}

//
// A log file with its modification time (TypeScript: the objects getLatestLogFile sorts).
//
const ILogFileEntry = struct {
    // The path of the log file.
    path: []const u8,

    // When the log file was last modified, in milliseconds (`mtime.getTime()`).
    mtime: i64,
};

//
// Orders log files newest first.
//
fn newerFirst(context: void, left: ILogFileEntry, right: ILogFileEntry) bool {
    _ = context;
    return left.mtime > right.mtime;
}

//
// The body of getLatestLogFile inside its try block (errors become null).
//
fn getLatestLogFileUnsafe(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const logsDir = try node_utils.path.join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere", "logs" });
    if (!node_utils.fs.pathExists(io, logsDir)) {
        return null;
    }

    var directory = try std.Io.Dir.cwd().openDir(io, logsDir, .{ .iterate = true });
    defer directory.close(io);
    var logFiles: std.ArrayList(ILogFileEntry) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "psi-") and std.mem.endsWith(u8, entry.name, ".log")) {
            const filePath = try node_utils.path.join(allocator, &.{ logsDir, entry.name });
            const stat = try std.Io.Dir.cwd().statFile(io, filePath, .{});
            try logFiles.append(allocator, .{ .path = filePath, .mtime = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)) });
        }
    }
    std.sort.block(ILogFileEntry, logFiles.items, {}, newerFirst);

    return if (logFiles.items.len > 0) logFiles.items[0].path else null;
}

//
// Gets the path of the newest psi-*.log file in the log directory, or null when there is none.
//
pub fn getLatestLogFile(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    return getLatestLogFileUnsafe(allocator, io) catch null;
}

//
// The marker at the end of the header of a log file.
//
const log_start_marker = "--- Log Start ---";

//
// Gets the header of the log file: everything up to and including the "--- Log Start ---" line, or its first
// 50 lines when it has no such line.
//
pub fn getLogHeader(allocator: std.mem.Allocator, io: std.Io, logFilePath: ?[]const u8) ![]const u8 {
    if (logFilePath == null or !node_utils.fs.pathExists(io, logFilePath.?)) {
        return "No log file available";
    }

    const logContent = std.Io.Dir.cwd().readFileAlloc(io, logFilePath.?, allocator, .unlimited) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading log file: {s}", .{utils.errors.errorMessage(err)});
    };
    const logStartIndex = std.mem.indexOf(u8, logContent, log_start_marker) orelse {
        // If no "--- Log Start ---" marker found, return first 50 lines
        var lines: std.ArrayList([]const u8) = .empty;
        var iterator = std.mem.splitScalar(u8, logContent, '\n');
        while (iterator.next()) |line| {
            if (lines.items.len == 50) {
                break;
            }
            try lines.append(allocator, line);
        }
        return std.mem.join(allocator, "\n", lines.items);
    };

    // Return everything up to (and including) the "--- Log Start ---" line
    return logContent[0 .. logStartIndex + log_start_marker.len];
}

//
// Generates the body of the GitHub issue.
//
pub fn generateBugReportTemplate(allocator: std.mem.Allocator, io: std.Io, systemInfo: ISystemInfo, toolVersions: IToolVersions, photosphereVersion: []const u8, bugInfo: IBugInfo, logHeader: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\## Bug Description
        \\{s}
        \\
        \\## Steps to Reproduce
        \\{s}
        \\
        \\## Expected Behavior
        \\{s}
        \\
        \\## Actual Behavior
        \\{s}
        \\
        \\## System Information
        \\- Photosphere Version: {s}
        \\- Platform: {s} {s}
        \\- OS Release: {s}
        \\- Node.js Version: {s}
        \\
        \\## Tool Versions
        \\- ImageMagick: {s}
        \\- FFmpeg: {s}
        \\- FFprobe: {s}
        \\
        \\## Log Header
        \\```
        \\{s}
        \\```
        \\
        \\## Log File
        \\Please attach the full log file located at:
        \\`{s}`
        \\
        \\You can drag and drop the log file into this issue, or copy and paste its contents into a code block.
        \\
        \\## Additional Context
        \\<!-- Add any other context about the problem here -->
        \\
        \\
    , .{
        bugInfo.description,
        bugInfo.stepsToReproduce,
        bugInfo.expectedBehavior,
        bugInfo.actualBehavior,
        photosphereVersion,
        systemInfo.platform,
        systemInfo.arch,
        systemInfo.release,
        systemInfo.nodeVersion,
        toolVersions.imagemagick,
        toolVersions.ffmpeg,
        toolVersions.ffprobe,
        logHeader,
        getLatestLogFile(allocator, io) orelse "No log file available",
    });
}

//
// Appends a name or value in the application/x-www-form-urlencoded form `URLSearchParams.toString()` gives it:
// ASCII letters, digits and `*-._` as they are, a space as `+` and every other byte as `%XX`.
//
fn appendFormEncoded(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '*' or byte == '-' or byte == '.' or byte == '_') {
            try output.append(allocator, byte);
        }
        else if (byte == ' ') {
            try output.append(allocator, '+');
        }
        else {
            try output.print(allocator, "%{X:0>2}", .{byte});
        }
    }
}

//
// Creates the URL that opens a new GitHub issue with the title, the body and the bug label.
//
pub fn createGitHubIssueUrl(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]const u8 {
    const baseUrl = "https://github.com/ashleydavis/photosphere/issues/new";
    var params: std.ArrayList(u8) = .empty;
    try params.appendSlice(allocator, "title=");
    try appendFormEncoded(allocator, &params, title);
    try params.appendSlice(allocator, "&body=");
    try appendFormEncoded(allocator, &params, body);
    try params.appendSlice(allocator, "&labels=bug");

    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ baseUrl, params.items });
}

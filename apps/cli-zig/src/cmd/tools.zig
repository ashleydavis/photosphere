//
// The command that shows the media processing tools built into psi.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const pc = @import("../lib/picocolors.zig");
const Image = tools.Image;
const Video = tools.Video;
const exit = node_utils.termination.exit;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;

//
// Options of the tools command.
//
pub const IToolsCommandOptions = struct {
    // Non-interactive mode - use defaults and command line arguments.
    yes: ?bool = null,
};

//
// The versions of the ImageMagick and FFmpeg built into the program.
//
pub const IBuiltInToolVersions = struct {
    // The ImageMagick version.
    magick: []const u8,

    // The ffmpeg version.
    ffmpeg: []const u8,

    // The ffprobe version.
    ffprobe: []const u8,
};

//
// A tool the command reports on.
//
const IToolEntry = struct {
    // The name the report shows for the tool.
    name: []const u8,

    // The version of the tool.
    version: []const u8,

    // What the tool is used for.
    description: []const u8,
};

//
// Formats a message into the allocator.
//
fn text(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// The version a check of a tool built into the program read from it. The tools are compiled into the program, so they
// cannot be missing: a tool that did not run throws with the error of its check.
//
fn builtInVersion(status: anytype) ![]const u8 {
    if (!status.available) {
        return utils.errors.throwError("{s}", .{status.@"error".?});
    }
    return status.version.?;
}

//
// Gets the versions of the ImageMagick and FFmpeg built into the program, run through toolRunner. Throws with the
// tool's error when one of them does not run.
//
pub fn getBuiltInToolVersions(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner) !IBuiltInToolVersions {
    return .{
        .magick = try builtInVersion(try Image.verifyImageMagick(allocator, io, log, toolRunner)),
        .ffmpeg = try builtInVersion(try Video.verifyFfmpeg(allocator, io, log, toolRunner)),
        .ffprobe = try builtInVersion(try Video.verifyFfprobe(allocator, io, log, toolRunner)),
    };
}

//
// Command that shows the media processing tools built into psi, with their versions.
// toolRunner runs the ImageMagick and FFmpeg built into the program. The tools are built in, so there is nothing to
// install and nothing to ask, and the options change nothing.
//
pub fn toolsCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner, options: *const IToolsCommandOptions) !void {
    _ = options;
    try listTools(allocator, io, log, toolRunner);
}

//
// Prints each tool with its version and what it is used for, then exits with 0.
//
fn listTools(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner) !void {
    log.info("");
    log.info(try pc.bold(allocator, "📦 Media Processing Tools\n"));

    const versions = try getBuiltInToolVersions(allocator, io, log, toolRunner);

    const toolEntries = [_]IToolEntry{
        .{
            .name = "ImageMagick (magick)",
            .version = versions.magick,
            .description = "Image processing - resizing, format conversion, metadata extraction",
        },
        .{
            .name = "ffmpeg",
            .version = versions.ffmpeg,
            .description = "Video processing - format conversion and thumbnail extraction",
        },
        .{
            .name = "ffprobe",
            .version = versions.ffprobe,
            .description = "Video analysis - metadata extraction, duration, dimensions, codecs",
        },
    };

    log.info(try pc.bold(allocator, "Built into psi:"));
    log.info("");

    for (toolEntries) |tool| {
        log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, tool.name), try pc.green(allocator, try text(allocator, "v{s}", .{tool.version})) }));
        log.info(try text(allocator, "   {s}", .{tool.description}));
        log.info("");
    }

    exit(io, log, 0);
}

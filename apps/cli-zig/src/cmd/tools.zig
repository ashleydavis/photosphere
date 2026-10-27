//
// The command that checks for the required media processing tools.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const pc = @import("../lib/picocolors.zig");
const verifyTools = tools.verifyTools;
const ToolStatus = tools.ToolStatus;
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
// A tool the command reports on.
//
const IToolEntry = struct {
    // The name the report shows for the tool.
    name: []const u8,

    // The status verifyTools gave the tool.
    status: ToolStatus,

    // True for ImageMagick, which is listed as missing under the name "ImageMagick".
    isMagick: bool,

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
// Command that checks for required media processing tools.
// toolRunner runs the ImageMagick and FFmpeg built into the program. The tools are built in, so there is nothing to
// install and nothing to ask, and the options change nothing.
//
pub fn toolsCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner, options: *const IToolsCommandOptions) !void {
    _ = options;
    try listTools(allocator, io, log, toolRunner);
}

//
// Prints the status of each tool, then exits: 0 when all are available, otherwise 1 after naming the tools that
// did not run.
//
fn listTools(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner) !void {
    log.info("");
    log.info(try pc.bold(allocator, "📦 Media Processing Tools Status\n"));

    const toolsStatus = try verifyTools(allocator, io, log, toolRunner);

    // Show status of each tool
    const toolEntries = [_]IToolEntry{
        .{
            .name = "ImageMagick (magick)",
            .status = toolsStatus.magick,
            .isMagick = true,
            .description = "Image processing - resizing, format conversion, metadata extraction",
        },
        .{
            .name = "ffmpeg",
            .status = toolsStatus.ffmpeg,
            .isMagick = false,
            .description = "Video processing - format conversion and thumbnail extraction",
        },
        .{
            .name = "ffprobe",
            .status = toolsStatus.ffprobe,
            .isMagick = false,
            .description = "Video analysis - metadata extraction, duration, dimensions, codecs",
        },
    };

    var allAvailable = true;
    var missingTools: std.ArrayList([]const u8) = .empty;

    log.info(try pc.bold(allocator, "Tool Status:"));
    log.info("");

    for (toolEntries) |tool| {
        const status = tool.status;
        const icon = if (status.available) "✅" else "❌";
        var statusText: []const u8 = undefined;
        if (status.available) {
            var versionText: []const u8 = "";
            if (status.version) |toolVersion| {
                if (toolVersion.len > 0) {
                    versionText = try text(allocator, " (v{s})", .{toolVersion});
                }
            }
            statusText = try pc.green(allocator, try text(allocator, "Available{s}", .{versionText}));
        }
        else {
            statusText = try pc.red(allocator, "Not found");
        }

        log.info(try text(allocator, "{s} {s}: {s}", .{ icon, try pc.bold(allocator, tool.name), statusText }));
        log.info(try text(allocator, "   {s}", .{tool.description}));
        if (status.@"error") |toolError| {
            log.info(try text(allocator, "   {s}", .{try pc.red(allocator, toolError)}));
        }

        if (!status.available) {
            allAvailable = false;
            if (tool.isMagick) {
                try missingTools.append(allocator, "ImageMagick");
            }
            else {
                try missingTools.append(allocator, tool.name);
            }
        }
        log.info("");
    }

    if (allAvailable) {
        log.info(try pc.green(allocator, "🎉 All tools are available and ready to use!"));
        exit(io, log, 0);
    }
    else {
        log.info(try pc.yellow(allocator, try text(allocator, "⚠️ {d} tool(s) missing: {s}", .{ missingTools.items.len, try std.mem.join(allocator, ", ", missingTools.items) })));
        exit(io, log, 1);
    }
}

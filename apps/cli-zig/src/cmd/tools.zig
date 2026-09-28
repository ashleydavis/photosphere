//
// Port of apps/cli/src/cmd/tools.ts: the command that checks for the required media processing tools.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const pc = @import("../lib/picocolors.zig");
const prompts = @import("../lib/clack/prompts.zig");
const installation_instructions = @import("../lib/installation-instructions.zig");
const log = &utils.log.log;
const verifyTools = tools.verifyTools;
const Image = tools.Image;
const ToolStatus = tools.ToolStatus;
const exit = node_utils.termination.exit;
const confirm = prompts.confirm;
const isCancel = prompts.isCancel;
const showInstallationInstructions = installation_instructions.showInstallationInstructions;

//
// Options of the tools command (TypeScript: IToolsCommandOptions).
//
pub const IToolsCommandOptions = struct {
    // Non-interactive mode - use defaults and command line arguments.
    yes: ?bool = null,
};

//
// A tool the command reports on (TypeScript: the elements of the `tools` array in listTools).
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
// Formats a message into the allocator (TypeScript: a template literal).
//
fn text(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// Command that checks for required media processing tools.
//
pub fn toolsCommand(allocator: std.mem.Allocator, io: std.Io, options: *const IToolsCommandOptions) !void {
    try listTools(allocator, io, options);
}

//
// Prints the status of each tool, then exits: 0 when all are available, otherwise 1 after offering the
// installation instructions.
//
fn listTools(allocator: std.mem.Allocator, io: std.Io, options: *const IToolsCommandOptions) !void {
    log.info("");
    log.info(try pc.bold(allocator, "📦 Media Processing Tools Status\n"));

    const toolsStatus = try verifyTools(allocator, io);

    // Get ImageMagick type to display the correct command name
    const imageMagickType = Image.getImageMagickType();
    var imageMagickName: []const u8 = "ImageMagick";

    if (imageMagickType == .legacy) {
        imageMagickName = "ImageMagick (convert/identify)";
    }
    else if (imageMagickType == .modern) {
        imageMagickName = "ImageMagick (magick)";
    }

    // Show status of each tool
    const toolEntries = [_]IToolEntry{
        .{
            .name = imageMagickName,
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
        exit(io, 0);
    }
    else {
        log.info(try pc.yellow(allocator, try text(allocator, "⚠️ {d} tool(s) missing: {s}", .{ missingTools.items.len, try std.mem.join(allocator, ", ", missingTools.items) })));
        log.info("");

        // Ask if user wants to see installation instructions (or show them automatically in --yes mode)
        var showInstructions = true;
        if (!(options.yes orelse false)) {
            const userChoice = try confirm(allocator, io, .{
                .message = "Would you like to see installation instructions?",
                .initialValue = true,
            });

            if (isCancel(userChoice)) {
                log.info("");
                log.info(try pc.dim(allocator, "Please install the missing tools and try again."));
                exit(io, 1);
            }
            showInstructions = userChoice.value;
        }

        if (!showInstructions) {
            log.info("");
            log.info(try pc.dim(allocator, "Please install the missing tools and try again."));
            exit(io, 1);
        }

        try showInstallationInstructions(allocator, missingTools.items);

        exit(io, 1);
    }
}

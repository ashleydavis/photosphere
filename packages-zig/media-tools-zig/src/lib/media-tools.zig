const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const image_magick = @import("image-magick.zig");
const ffmpeg = @import("ffmpeg.zig");

const in_process_tools = node_utils.in_process_tools;

//
// The tools the program has built in and runs in its own process: ImageMagick for the `magick` tool, and FFmpeg for the `ffmpeg`
// and `ffprobe` tools. A program holds one of these for its whole life and gives its runner to the code that runs tools, which then
// runs a command for a tool listed here in the process.
//
pub const MediaTools = struct {
    // ImageMagick, for `magick`.
    image_magick: image_magick.ImageMagick,

    // FFmpeg, for `ffmpeg` and `ffprobe`.
    ffmpeg: ffmpeg.Ffmpeg,

    //
    // Starts the tools. Fails when ImageMagick cannot set its security policy.
    //
    pub fn init(io: std.Io) !MediaTools {
        return .{
            .image_magick = try image_magick.ImageMagick.init(io),
            .ffmpeg = ffmpeg.Ffmpeg.init(io),
        };
    }

    //
    // Stops the tools.
    //
    pub fn deinit(self: *MediaTools) void {
        self.ffmpeg.deinit();
        self.image_magick.deinit();
    }

    //
    // The runner exec calls, backed by these tools. The runner points at this, so this must not move while the runner is used.
    //
    pub fn runner(self: *MediaTools) in_process_tools.InProcessRunner {
        return .{
            .context = self,
            .handles = handles,
            .run = run,
        };
    }

    //
    // Whether the tool is one of the built in ones.
    //
    fn handles(context: ?*anyopaque, tool: []const u8) bool {
        _ = context;
        return std.mem.eql(u8, tool, "magick") or std.mem.eql(u8, tool, "ffmpeg") or std.mem.eql(u8, tool, "ffprobe");
    }

    //
    // Runs the tool with the arguments, which do not include the tool's name. Fails for a tool that is not built in.
    //
    fn run(context: ?*anyopaque, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!in_process_tools.ToolOutput {
        const self: *MediaTools = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, tool, "magick")) {
            return try self.image_magick.runMagick(allocator, arguments);
        }
        if (std.mem.eql(u8, tool, "ffmpeg")) {
            return try self.ffmpeg.runFfmpeg(allocator, arguments);
        }
        if (std.mem.eql(u8, tool, "ffprobe")) {
            return try self.ffmpeg.runFfprobe(allocator, arguments);
        }
        return utils.errors.throwError("{s} is not built into the program.", .{tool});
    }
};

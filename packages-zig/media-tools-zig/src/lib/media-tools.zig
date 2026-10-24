const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const image_magick = @import("image-magick.zig");
const ffmpeg = @import("ffmpeg.zig");

const in_process_tools = node_utils.in_process_tools;

//
// The tools the program has built in and runs in its own process: ImageMagick for the `magick` tool, and FFmpeg for the `ffmpeg`
// and `ffprobe` tools. The program's main thread holds one of these for its whole life: it starts the tools for the whole program and
// runs the main thread's own commands through `runner`, and a task makes `ThreadTools` of its own on its own thread when it needs
// them. Nothing of it is shared.
//
pub const MediaTools = struct {
    // ImageMagick started for the program.
    image_magick_started: image_magick.Started,

    // FFmpeg started for the program.
    ffmpeg_started: ffmpeg.Started,

    // The main thread's own runner of the tools.
    tools: ThreadTools,

    //
    // Starts the tools, on the main thread. Fails when ImageMagick cannot set its security policy.
    //
    pub fn init() !MediaTools {
        var image_magick_started = try image_magick.Started.start();
        errdefer image_magick_started.stop();
        return .{
            .image_magick_started = image_magick_started,
            .ffmpeg_started = ffmpeg.Started.start(),
            .tools = .{},
        };
    }

    //
    // Stops the tools, once no thread runs a command.
    //
    pub fn deinit(self: *MediaTools) void {
        self.ffmpeg_started.stop();
        self.image_magick_started.stop();
    }

    //
    // The main thread's runner, which exec calls. The runner points at this, so this must not move while the runner is used.
    //
    pub fn runner(self: *MediaTools) in_process_tools.InProcessRunner {
        return self.tools.runner();
    }
};

//
// One thread's runners of the tools, which the thread makes for itself.
//
pub const ThreadTools = struct {
    //
    // Makes the runners of the calling thread, once the program has started the tools (see MediaTools). Each run is given the thread's Io.
    //
    pub fn init() ThreadTools {
        return .{};
    }

    //
    // The runner exec calls, backed by these tools. The runner points at this, so this must not move while the runner is used.
    //
    pub fn runner(self: *ThreadTools) in_process_tools.InProcessRunner {
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
    fn run(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!in_process_tools.ToolOutput {
        _ = context;
        if (std.mem.eql(u8, tool, "magick")) {
            return try image_magick.ImageMagick.runMagick(io, allocator, arguments);
        }
        if (std.mem.eql(u8, tool, "ffmpeg")) {
            return try ffmpeg.Ffmpeg.runFfmpeg(io, allocator, arguments);
        }
        if (std.mem.eql(u8, tool, "ffprobe")) {
            return try ffmpeg.Ffmpeg.runFfprobe(io, allocator, arguments);
        }
        return utils.errors.throwError("{s} is not built into the program.", .{tool});
    }
};

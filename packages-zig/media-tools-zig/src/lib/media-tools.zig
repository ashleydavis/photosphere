const image_magick = @import("image-magick.zig");
const ffmpeg = @import("ffmpeg.zig");

//
// The tools the program has built in and runs in its own process: ImageMagick for the `magick` tool, and FFmpeg for the `ffmpeg`
// and `ffprobe` tools. The program's main thread holds one of these for its whole life: it starts the libraries for the whole program
// before any thread runs a tool, and stops them after the last has ended. Any thread then runs a tool by calling it (see tool-run.zig).
//
pub const MediaTools = struct {
    // ImageMagick started for the program.
    image_magick_started: image_magick.Started,

    // FFmpeg started for the program.
    ffmpeg_started: ffmpeg.Started,

    //
    // Starts the tools, on the main thread. Fails when ImageMagick cannot set its security policy.
    //
    pub fn init() !MediaTools {
        var image_magick_started = try image_magick.Started.start();
        errdefer image_magick_started.stop();
        return .{
            .image_magick_started = image_magick_started,
            .ffmpeg_started = ffmpeg.Started.start(),
        };
    }

    //
    // Stops the tools, once no thread runs a command.
    //
    pub fn deinit(self: *MediaTools) void {
        self.ffmpeg_started.stop();
        self.image_magick_started.stop();
    }
};

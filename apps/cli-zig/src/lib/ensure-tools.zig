const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const tools = @import("tools-zig");
const Image = tools.Image;
const Video = tools.Video;

//
// Ensures the ImageMagick and FFmpeg built into the program run, for commands that need media processing.
// They run in the program's process. When one of them does not run, this throws with that tool's error.
//
pub fn ensureMediaProcessingTools(allocator: std.mem.Allocator, io: std.Io, log: ILog) !void {
    const imageMagickStatus = try Image.verifyImageMagick(allocator, io, log);
    try requireAvailable(imageMagickStatus.available, imageMagickStatus.@"error", "The built-in ImageMagick did not run.");

    const ffprobeStatus = try Video.verifyFfprobe(allocator, io, log);
    try requireAvailable(ffprobeStatus.available, ffprobeStatus.@"error", "The built-in ffprobe did not run.");

    const ffmpegStatus = try Video.verifyFfmpeg(allocator, io, log);
    try requireAvailable(ffmpegStatus.available, ffmpegStatus.@"error", "The built-in ffmpeg did not run.");
}

//
// Throws with the error of a tool's check when the tool is not available, or with the fallback when the check gave no error.
//
pub fn requireAvailable(available: bool, toolError: ?[]const u8, fallback: []const u8) !void {
    if (!available) {
        return utils.errors.throwError("{s}", .{toolError orelse fallback});
    }
}

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const Image = tools.Image;
const Video = tools.Video;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;

//
// Ensures the ImageMagick and FFmpeg built into the program run, for commands that need media processing.
// toolRunner runs them in the program's process. When one of them does not run, this throws with that tool's error.
//
pub fn ensureMediaProcessingTools(allocator: std.mem.Allocator, io: std.Io, toolRunner: InProcessRunner) !void {
    const imageMagickStatus = try Image.verifyImageMagick(allocator, io, toolRunner);
    if (!imageMagickStatus.available) {
        return utils.errors.throwError("{s}", .{imageMagickStatus.@"error" orelse "The built-in ImageMagick did not run."});
    }

    const ffprobeStatus = try Video.verifyFfprobe(allocator, io, toolRunner);
    if (!ffprobeStatus.available) {
        return utils.errors.throwError("{s}", .{ffprobeStatus.@"error" orelse "The built-in ffprobe did not run."});
    }

    const ffmpegStatus = try Video.verifyFfmpeg(allocator, io, toolRunner);
    if (!ffmpegStatus.available) {
        return utils.errors.throwError("{s}", .{ffmpegStatus.@"error" orelse "The built-in ffmpeg did not run."});
    }
}

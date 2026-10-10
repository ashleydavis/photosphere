const std = @import("std");
const node_utils = @import("node-utils-zig");
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const Image = @import("image.zig").Image;
const Video = @import("video.zig").Video;

//
// The availability of one tool.
//
pub const ToolStatus = struct {
    // True when the tool can be run.
    available: bool,

    // The tool version, when available.
    version: ?[]const u8 = null,

    // Why the tool is not available.
    @"error": ?[]const u8 = null,
};

//
// The availability of all the tools Photosphere needs.
//
pub const ToolsStatus = struct {
    // ImageMagick.
    magick: ToolStatus,

    // ffprobe.
    ffprobe: ToolStatus,

    // ffmpeg.
    ffmpeg: ToolStatus,

    // True when every tool is available.
    allAvailable: bool,

    // Display names of the tools that are not available.
    missingTools: []const []const u8,
};

//
// Check the availability of all required tools
//
pub fn verifyTools(allocator: std.mem.Allocator, io: std.Io, tools: ?InProcessRunner) !ToolsStatus {
    // Serialize tool verification to avoid race conditions
    const magickStatus = try Image.verifyImageMagick(allocator, io, tools);
    const ffprobeStatus = Video.verifyFfprobe(allocator, io, tools);
    const ffmpegStatus = Video.verifyFfmpeg(allocator, io, tools);

    var missingTools: std.ArrayList([]const u8) = .empty;

    if (!magickStatus.available) {
        try missingTools.append(allocator, "ImageMagick");
    }
    if (!ffprobeStatus.available) {
        try missingTools.append(allocator, "ffprobe");
    }
    if (!ffmpegStatus.available) {
        try missingTools.append(allocator, "ffmpeg");
    }

    return .{
        .magick = .{ .available = magickStatus.available, .version = magickStatus.version, .@"error" = magickStatus.@"error" },
        .ffprobe = .{ .available = ffprobeStatus.available, .version = ffprobeStatus.version, .@"error" = ffprobeStatus.@"error" },
        .ffmpeg = .{ .available = ffmpegStatus.available, .version = ffmpegStatus.version, .@"error" = ffmpegStatus.@"error" },
        .allAvailable = missingTools.items.len == 0,
        .missingTools = missingTools.items,
    };
}


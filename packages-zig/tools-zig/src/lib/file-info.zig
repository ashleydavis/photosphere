const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const Image = @import("image.zig").Image;
const Video = @import("video.zig").Video;
const AssetInfo = @import("types.zig").AssetInfo;
const errors = utils.errors;

//
// Gets file information for an image or video file based on content type
// @param tools The runner that runs ImageMagick, ffmpeg and ffprobe in the app's process, or null to start them as programs
// @param filePath Path to the file to analyze
// @param contentType MIME type of the file (e.g., 'image/jpeg', 'video/mp4')
// @returns AssetInfo for images/videos, or undefined for other file types
//
pub fn getFileInfo(allocator: std.mem.Allocator, io: std.Io, tools: ?InProcessRunner, filePath: []const u8, contentType: []const u8) !?AssetInfo {
    if (std.mem.startsWith(u8, contentType, "image/")) {
        var image = Image.init(filePath);
        return image.getInfo(allocator, io, tools) catch |err| {
            // The stack goes in because the message alone does not say where the failure came from.
            // (Zig: the error name stands in for the stack.)
            return errors.throwError("Failed to get image info for {s}: {s}\n{s}", .{ filePath, try utils.errors.errorToString(allocator, err), @errorName(err) });
        };
    }
    else if (std.mem.startsWith(u8, contentType, "video/")) {
        var video = Video.init(allocator, io, tools, filePath);
        return video.getInfo(allocator, io, tools) catch |err| {
            return errors.throwError("Failed to get video info for {s}: {s}\n{s}", .{ filePath, try utils.errors.errorToString(allocator, err), @errorName(err) });
        };
    }

    // Return undefined for unsupported file types
    return null;
}

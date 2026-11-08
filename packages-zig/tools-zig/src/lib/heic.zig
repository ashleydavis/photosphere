const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const ffmpeg = @import("media-tools-zig").ffmpeg;
const pathExists = node_utils.fs.pathExists;
const errors = utils.errors;
const types = @import("types.zig");
const AssetInfo = types.AssetInfo;

//
// HEIC and HEIF pictures, which ImageMagick is built without (third-party/imagemagick builds no HEIF delegate) and FFmpeg reads.
//
// A phone's HEIC is a grid of HEVC tiles. FFmpeg's demuxer reports the grid as a stream group, whose tiles media-tools-zig's ffmpeg.zig
// decodes, puts in place and trims to the picture's size, turning the result as the file's rotation and mirroring say. So the size of
// a HEIC comes from FFmpeg, and everything ImageMagick does to a picture is done to a JPEG decoded from the HEIC.
//

//
// The JPEG quality of the picture decoded from a HEIC, which the pictures the app keeps are made from.
//
const decoded_quality = 95;

//
// Whether a content type is a HEIC or HEIF still picture.
//
pub fn isHeicContentType(contentType: []const u8) bool {
    return std.ascii.eqlIgnoreCase(contentType, "image/heic") or std.ascii.eqlIgnoreCase(contentType, "image/heif");
}

//
// Reads the size of a HEIC with FFmpeg: the size of its tile grid, or of its one coded picture, before the file's rotation. The rest
// of what AssetInfo holds is not known for a still picture, and the date is read from the file's EXIF, not here.
//
pub fn getHeicInfo(allocator: std.mem.Allocator, io: std.Io, log: ILog, filePath: []const u8) !AssetInfo {
    if (!pathExists(io, filePath)) {
        return errors.throwError("File not found: {s}", .{filePath});
    }
    const size = try ffmpeg.readPictureSize(allocator, io, log, filePath);
    return .{
        .filePath = filePath,
        .dimensions = .{
            .width = @floatFromInt(size.width),
            .height = @floatFromInt(size.height),
        },
        .duration = null,
        .fps = null,
        .bitrate = null,
        .hasAudio = false,
    };
}

//
// Decodes a HEIC into a JPEG at the given path with FFmpeg: the whole picture, its tiles joined and trimmed, turned upright as the file
// says. The JPEG is made at a high quality, because the pictures the app keeps are made from it, and it has no EXIF.
//
pub fn decodeHeic(allocator: std.mem.Allocator, io: std.Io, log: ILog, filePath: []const u8, outputPath: []const u8) !void {
    if (!pathExists(io, filePath)) {
        return errors.throwError("File not found: {s}", .{filePath});
    }
    if (pathExists(io, outputPath)) {
        return errors.throwError("Output file already exists: {s}", .{outputPath});
    }
    ffmpeg.decodePicture(allocator, io, log, .{
        .input_path = filePath,
        .output_path = outputPath,
        .quality = decoded_quality,
    }) catch |err| {
        return errors.throwError("Failed to decode the HEIC {s}: {s}", .{ filePath, try utils.errors.errorToString(allocator, err) });
    };
}

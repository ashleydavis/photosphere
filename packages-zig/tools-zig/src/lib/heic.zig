const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const exec = node_utils.exec.exec;
const execLogged = node_utils.exec.execLogged;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const pathExists = node_utils.fs.pathExists;
const errors = utils.errors;
const types = @import("types.zig");
const AssetInfo = types.AssetInfo;
const Dimensions = types.Dimensions;

//
// HEIC and HEIF pictures, which ImageMagick is built without (third-party/imagemagick builds no HEIF delegate) and FFmpeg reads.
//
// A phone's HEIC is a grid of HEVC tiles. FFmpeg's demuxer reports the grid as a stream group, and its command line program joins the
// tiles with the xstack filter, trims them to the picture's size and turns the result as the file's rotation and mirroring say
// (which is why third-party/ffmpeg is built with xstack). So the size of a HEIC comes from ffprobe, and everything ImageMagick does to
// a picture is done to a JPEG FFmpeg decodes the HEIC into.
//

//
// Whether a content type is a HEIC or HEIF still picture.
//
pub fn isHeicContentType(contentType: []const u8) bool {
    return std.ascii.eqlIgnoreCase(contentType, "image/heic") or std.ascii.eqlIgnoreCase(contentType, "image/heif");
}

//
// Reads the size of the picture from ffprobe's JSON report of a HEIC (`-show_streams -show_stream_groups`): the size of the tile grid
// when the picture is one, otherwise the size of its one coded picture. The size is the stored one, before the file's rotation.
//
pub fn dimensionsFromProbe(allocator: std.mem.Allocator, probeJson: []const u8) !Dimensions {
    const report = std.json.parseFromSliceLeaky(std.json.Value, allocator, probeJson, .{}) catch |err| {
        return errors.throwError("ffprobe's report of the HEIC is not JSON: {s}", .{@errorName(err)});
    };
    if (report != .object) {
        return errors.throwError("ffprobe's report of the HEIC is not a JSON object", .{});
    }

    if (report.object.get("stream_groups")) |groups| {
        if (groups == .array) {
            for (groups.array.items) |group| {
                if (group != .object) {
                    continue;
                }
                const groupType = group.object.get("type") orelse continue;
                if (groupType != .string or !std.mem.eql(u8, groupType.string, "Tile Grid")) {
                    continue;
                }
                const components = group.object.get("components") orelse {
                    return errors.throwError("ffprobe reported a HEIC tile grid with no components", .{});
                };
                if (components != .array or components.array.items.len == 0 or components.array.items[0] != .object) {
                    return errors.throwError("ffprobe reported a HEIC tile grid whose components are not an array of objects", .{});
                }
                return sizeOf(components.array.items[0], "the HEIC tile grid");
            }
        }
    }

    const streams = report.object.get("streams") orelse {
        return errors.throwError("ffprobe reported no streams in the HEIC", .{});
    };
    if (streams != .array) {
        return errors.throwError("ffprobe reported streams in the HEIC that are not an array", .{});
    }
    for (streams.array.items) |stream| {
        if (stream != .object) {
            continue;
        }
        const codecType = stream.object.get("codec_type") orelse continue;
        if (codecType == .string and std.mem.eql(u8, codecType.string, "video")) {
            return sizeOf(stream, "the HEIC picture");
        }
    }
    return errors.throwError("ffprobe found no picture in the HEIC", .{});
}

//
// The width and height properties of an object of ffprobe's report, which must both be positive whole numbers.
//
fn sizeOf(value: std.json.Value, what: []const u8) !Dimensions {
    const width = value.object.get("width") orelse .null;
    const height = value.object.get("height") orelse .null;
    if (width != .integer or height != .integer or width.integer <= 0 or height.integer <= 0) {
        return errors.throwError("ffprobe gave no usable width and height for {s}", .{what});
    }
    return .{
        .width = @floatFromInt(width.integer),
        .height = @floatFromInt(height.integer),
    };
}

//
// Reads the size of a HEIC with ffprobe. The rest of what AssetInfo holds is not known for a still picture, and the date is read from
// the file's EXIF, not here.
//
pub fn getHeicInfo(allocator: std.mem.Allocator, io: std.Io, log: ILog, tools: InProcessRunner, filePath: []const u8) !AssetInfo {
    if (!pathExists(io, filePath)) {
        return errors.throwError("File not found: {s}", .{filePath});
    }
    const command = try std.fmt.allocPrint(allocator, "ffprobe -v error -print_format json -show_streams -show_stream_groups \"{s}\"", .{filePath});
    const result = try exec(allocator, io, log, tools, command);
    return .{
        .filePath = filePath,
        .dimensions = try dimensionsFromProbe(allocator, result.stdout),
        .duration = null,
        .fps = null,
        .bitrate = null,
        .hasAudio = false,
    };
}

//
// Decodes a HEIC into a JPEG at the given path with FFmpeg: the whole picture, its tiles joined and trimmed, turned upright as the file
// says. The JPEG is made at FFmpeg's best quality (-q:v 2), because the pictures the app keeps are made from it, and it has no EXIF.
// JPEG because it is the one picture encoder the bundled FFmpeg is built with.
//
pub fn decodeHeic(allocator: std.mem.Allocator, io: std.Io, log: ILog, tools: InProcessRunner, filePath: []const u8, outputPath: []const u8) !void {
    if (!pathExists(io, filePath)) {
        return errors.throwError("File not found: {s}", .{filePath});
    }
    if (pathExists(io, outputPath)) {
        return errors.throwError("Output file already exists: {s}", .{outputPath});
    }
    const command = try std.fmt.allocPrint(allocator, "ffmpeg -v error -i \"{s}\" -frames:v 1 -q:v 2 \"{s}\"", .{ filePath, outputPath });
    _ = execLogged(allocator, io, log, tools, "ffmpeg", command, null) catch |err| {
        return errors.throwError("Failed to decode the HEIC {s}: {s}", .{ filePath, try utils.errors.errorToString(allocator, err) });
    };
    if (!pathExists(io, outputPath)) {
        return errors.throwError("FFmpeg decoded the HEIC {s} without writing {s}", .{ filePath, outputPath });
    }
}

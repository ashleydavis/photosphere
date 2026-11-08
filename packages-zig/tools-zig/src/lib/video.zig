const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const node_utils = @import("node-utils-zig");
const ffmpeg = @import("media-tools-zig").ffmpeg;
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const js_date = serialization_zig.js_date;
const pathExists = node_utils.fs.pathExists;
const errors = utils.errors;
const types = @import("types.zig");
const AssetInfo = types.AssetInfo;
const Dimensions = types.Dimensions;

//
// The JPEG quality of a frame taken from a video, which the thumbnail is then made from.
//
const screenshot_quality = 90;

//
// The result of Video.verifyFfprobe and Video.verifyFfmpeg.
//
pub const VideoToolStatus = struct {
    // True when the tool can be run.
    available: bool,

    // The tool version, when available.
    version: ?[]const u8 = null,

    // Why the tool is not available.
    @"error": ?[]const u8 = null,
};

//
// Wraps FFmpeg's reading of videos.
//
pub const Video = struct {
    // The file the video is read from.
    filePath: []const u8,

    // The information read from the file, once it has been read.
    _info: ?AssetInfo = null,

    //
    // Creates a video for a file.
    //
    pub fn init(filePath: []const u8) Video {
        return .{ .filePath = filePath };
    }

    //
    // The status of the FFmpeg that probes videos, which is built into the program and needs nothing to start: available, with its
    // version.
    //
    pub fn verifyFfprobe() VideoToolStatus {
        return .{
            .available = true,
            .version = ffmpeg.version(),
        };
    }

    //
    // The status of the FFmpeg that decodes videos, the same library as verifyFfprobe's: available, with its version.
    //
    pub fn verifyFfmpeg() VideoToolStatus {
        return .{
            .available = true,
            .version = ffmpeg.version(),
        };
    }

    //
    // Reads the information about the video with FFmpeg.
    //
    fn getVideoInfo(self: *Video, allocator: std.mem.Allocator, io: std.Io, log: ILog) !AssetInfo {
        if (self._info) |info| {
            return info;
        }

        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        const probe = ffmpeg.probeFile(allocator, io, log, self.filePath) catch |err| {
            return errors.throwError("Failed to get video info: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
        self._info = try readProbe(allocator, self.filePath, probe);
        return self._info.?;
    }

    //
    // Reads the information about the video at filePath from what FFmpeg read of it. Fails with "Failed to get video info: " and
    // the reason when the file has no video stream.
    //
    pub fn readProbe(allocator: std.mem.Allocator, filePath: []const u8, probe: ffmpeg.IProbe) !AssetInfo {
        return readProbeInner(allocator, filePath, probe) catch |err| {
            return errors.throwError("Failed to get video info: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
    }

    //
    // The body of the try block of readProbe.
    //
    fn readProbeInner(allocator: std.mem.Allocator, filePath: []const u8, probe: ffmpeg.IProbe) !AssetInfo {
        const videoStream = findStream(probe.streams, .video);
        const audioStream = findStream(probe.streams, .audio);
        const stream = videoStream orelse {
            return errors.throwError("No video stream found in file", .{});
        };

        // The container's tags, then the codecs and the pixel format.
        var createdAt: ?f64 = null;
        var metadata: BsonDocument = .{};
        for (probe.tags) |tag| {
            try metadata.put(allocator, tag.key, .{ .string = tag.value });
            if (std.mem.eql(u8, tag.key, "creation_time") and tag.value.len > 0) {
                createdAt = js_date.parseDate(tag.value);
            }
        }
        try metadata.put(allocator, "videoCodec", .{ .string = stream.codec_name });
        try metadata.put(allocator, "audioCodec", if (audioStream) |audio| .{ .string = audio.codec_name } else .undefined);
        try metadata.put(allocator, "pixelFormat", .{ .string = stream.pixel_format });

        return .{
            .filePath = filePath,

            .dimensions = .{
                .width = @floatFromInt(stream.width),
                .height = @floatFromInt(stream.height),
            },

            // A duration, bitrate or frame rate FFmpeg cannot tell is NaN, as it was when it was read from ffprobe's report.
            .duration = probe.duration_seconds orelse std.math.nan(f64),
            .fps = @as(f64, @floatFromInt(stream.frame_rate.numerator)) / @as(f64, @floatFromInt(stream.frame_rate.denominator)),
            .bitrate = if (probe.bit_rate) |bitRate| @floatFromInt(bitRate) else std.math.nan(f64),
            .hasAudio = audioStream != null,

            .createdAt = createdAt,

            .metadata = .{ .document = metadata },
        };
    }

    //
    // Gets the information about the video.
    //
    pub fn getInfo(self: *Video, allocator: std.mem.Allocator, io: std.Io, log: ILog) !AssetInfo {
        return self.getVideoInfo(allocator, io, log);
    }

    //
    // Gets the width and height of the video.
    //
    pub fn getDimensions(self: *Video, allocator: std.mem.Allocator, io: std.Io, log: ILog) !Dimensions {
        const info = try self.getVideoInfo(allocator, io, log);
        return info.dimensions;
    }

    //
    // Writes a JPEG of the frame of the video at a time, turned upright as the video says, to the output path, and returns the path.
    //
    pub fn extractScreenshot(self: *Video, allocator: std.mem.Allocator, io: std.Io, log: ILog, outputPath: []const u8, timeInSeconds: f64) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        ffmpeg.extractFrame(allocator, io, log, .{
            .input_path = self.filePath,
            .output_path = outputPath,
            .time_seconds = timeInSeconds,
            .quality = screenshot_quality,
        }) catch |err| {
            return errors.throwError("Failed to extract screenshot: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
        return outputPath;
    }
};

//
// The first stream of the kind, or null when there is none.
//
fn findStream(streams: []const ffmpeg.IProbeStream, kind: ffmpeg.IStreamKind) ?ffmpeg.IProbeStream {
    for (streams) |stream| {
        if (stream.kind == kind) {
            return stream;
        }
    }
    return null;
}

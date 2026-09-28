const std = @import("std");
const node_utils = @import("node-utils-zig");
const version_match = @import("version-match.zig");
const exec = node_utils.exec.exec;
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const jsonParse = serialization_zig.json_parse.jsonParse;
const js_date = serialization_zig.js_date;
const pathExists = node_utils.fs.pathExists;
const errors = utils.errors;
const parseFloat = utils.js_number.parseFloat;
const parseInt = @import("image.zig").parseInt;
const types = @import("types.zig");
const AssetInfo = types.AssetInfo;
const Dimensions = types.Dimensions;

//
// The result of Video.verifyFfprobe and Video.verifyFfmpeg
// (TypeScript: `{ available: boolean; version?: string; error?: string }`).
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
// Wraps ffprobe and ffmpeg. Only the tool verification is ported.
//
pub const Video = struct {
    // The command used to probe videos.
    var ffprobeCommand: []const u8 = "ffprobe";

    // The command used to process videos.
    var ffmpegCommand: []const u8 = "ffmpeg";

    // The file the video is read from.
    filePath: []const u8,

    // The information read from the file, once it has been read.
    _info: ?AssetInfo = null,

    // True once initializeCommands has run.
    var isInitialized: bool = false;

    //
    // Creates a video for a file (TypeScript: `new Video(filePath)`).
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) Video {
        // Initialize ffmpeg/ffprobe commands on first use
        if (!isInitialized) {
            initializeCommands(allocator, io);
        }
        return .{ .filePath = filePath };
    }

    //
    // Initialize ffmpeg/ffprobe commands by checking system PATH (TypeScript does not wait for it; it only logs,
    // because the commands it sets are the defaults they already have).
    //
    fn initializeCommands(allocator: std.mem.Allocator, io: std.Io) void {
        if (isInitialized) {
            return;
        }

        // Test if ffprobe command is available in system PATH
        const result = exec(allocator, io, "ffprobe -version") catch {
            // ffprobe not found in PATH
            isInitialized = true;
            return;
        };

        // If we get here, ffprobe works (and ffmpeg should too)
        ffprobeCommand = "ffprobe";
        ffmpegCommand = "ffmpeg";
        isInitialized = true;

        // Get version info
        const version = version_match.matchAfter(result.stdout, "ffprobe version ", version_match.isVersionNumberCharacter) orelse "unknown";

        utils.log.log.verbose("Using system ffprobe: ffprobe");
        const message = std.fmt.allocPrint(allocator, "ffprobe version: {s}", .{version}) catch return;
        utils.log.log.verbose(message);
    }

    // Not ported: configure (Photosphere does not configure custom binaries).

    //
    // Verify that ffprobe is available
    //
    pub fn verifyFfprobe(allocator: std.mem.Allocator, io: std.Io) VideoToolStatus {
        const result = exec(allocator, io, "ffprobe -version") catch {
            return .{
                .available = false,
                .@"error" = "ffprobe not found. Make sure ffmpeg is installed.",
            };
        };

        const versionMatch = version_match.matchAfter(result.stdout, "ffprobe version ", version_match.isNonWhitespaceCharacter);
        return .{
            .available = true,
            .version = versionMatch orelse "unknown",
        };
    }

    //
    // Verify that ffmpeg is available
    //
    pub fn verifyFfmpeg(allocator: std.mem.Allocator, io: std.Io) VideoToolStatus {
        const result = exec(allocator, io, "ffmpeg -version") catch {
            return .{
                .available = false,
                .@"error" = "ffmpeg not found. Make sure ffmpeg is installed.",
            };
        };

        const versionMatch = version_match.matchAfter(result.stdout, "ffmpeg version ", version_match.isNonWhitespaceCharacter);
        return .{
            .available = true,
            .version = versionMatch orelse "unknown",
        };
    }

    //
    // Reads the information about the video with ffprobe.
    //
    fn getVideoInfo(self: *Video, allocator: std.mem.Allocator, io: std.Io) !AssetInfo {
        if (self._info) |info| {
            return info;
        }

        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        self._info = self.getVideoInfoInner(allocator, io) catch |err| {
            return errors.throwError("Failed to get video info: Error: {s}", .{try allocator.dupe(u8, utils.errors.errorMessage(err))});
        };
        return self._info.?;
    }

    //
    // The body of the try block of getVideoInfo.
    //
    fn getVideoInfoInner(self: *Video, allocator: std.mem.Allocator, io: std.Io) !AssetInfo {

        // Run ffprobe to get video information in JSON format
        const command = try std.fmt.allocPrint(allocator, "{s} -v quiet -print_format json -show_format -show_streams \"{s}\"", .{ ffprobeCommand, self.filePath });
        const result = try exec(allocator, io, command);

        const probeData = (try jsonParse(allocator, result.stdout)).document;
        const format = probeData.get("format") orelse BsonValue.undefined;
        const streams = switch (probeData.get("streams") orelse BsonValue.undefined) {
            .array => |items| items,
            else => return errors.throwError("TypeError: probeData.streams.find is not a function", .{}),
        };
        const videoStream = findStream(streams, "video");
        const audioStream = findStream(streams, "audio");
        const stream = videoStream orelse {
            return errors.throwError("No video stream found in file", .{});
        };

        const tags = property(format, "tags");

        // Parse creation time if available
        var createdAt: ?f64 = null;
        const creationTime = property(tags, "creation_time");
        if (isTruthy(creationTime)) {
            createdAt = switch (creationTime) {
                .string => |text| js_date.parseDate(text),
                else => std.math.nan(f64),
            };
        }

        // Parse framerate
        var fps: ?f64 = null;
        const frameRate = property(.{ .document = stream }, "r_frame_rate");
        if (isTruthy(frameRate)) {
            if (frameRate == .string) {
                var parts = std.mem.splitScalar(u8, frameRate.string, '/');
                const num = jsNumber(parts.next() orelse "");
                const den = if (parts.next()) |text| jsNumber(text) else std.math.nan(f64);
                fps = num / den;
            }
        }

        var metadata: BsonDocument = .{};
        switch (tags) {
            .document => |tagsDocument| {
                for (tagsDocument.fields.items) |field| {
                    try metadata.put(allocator, field.key, field.value);
                }
            },
            else => {},
        }
        try metadata.put(allocator, "videoCodec", property(.{ .document = stream }, "codec_name"));
        try metadata.put(allocator, "audioCodec", if (audioStream) |audio| property(.{ .document = audio }, "codec_name") else .undefined);
        try metadata.put(allocator, "pixelFormat", property(.{ .document = stream }, "pix_fmt"));

        return .{
            .filePath = self.filePath,

            .dimensions = .{
                .width = numberProperty(stream, "width"),
                .height = numberProperty(stream, "height"),
            },

            .duration = parseFloat(textOf(property(format, "duration"))),
            .fps = fps,
            .bitrate = parseInt(textOf(property(format, "bit_rate"))),
            .hasAudio = audioStream != null,

            .createdAt = createdAt,

            .metadata = .{ .document = metadata },
        };
    }

    //
    // Gets the information about the video.
    //
    pub fn getInfo(self: *Video, allocator: std.mem.Allocator, io: std.Io) !AssetInfo {
        return self.getVideoInfo(allocator, io);
    }

    //
    // Gets the width and height of the video.
    //
    pub fn getDimensions(self: *Video, allocator: std.mem.Allocator, io: std.Io) !Dimensions {
        const info = try self.getVideoInfo(allocator, io);
        return info.dimensions;
    }

    // Not ported: getDuration, getPath (not used by psi add).

    //
    // Extract a screenshot/thumbnail from the video at a specific time. Only the default options are ported (no
    // scaling, quality 85), which is how getVideoDetails calls it.
    //
    pub fn extractScreenshot(self: *Video, allocator: std.mem.Allocator, io: std.Io, outputPath: []const u8, timeInSeconds: f64) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        const quality: f64 = 85;

        var command: std.ArrayList(u8) = .empty;
        try command.print(allocator, "{s} -i \"{s}\" -ss {d} -vframes 1", .{ ffmpegCommand, self.filePath, timeInSeconds });

        // Add quality
        try command.print(allocator, " -q:v {d}", .{jsRound((100 - quality) / 10)});

        // Force overwrite and specify output
        try command.print(allocator, " -y \"{s}\"", .{outputPath});

        _ = exec(allocator, io, command.items) catch |err| {
            return errors.throwError("Failed to extract screenshot: Error: {s}", .{try allocator.dupe(u8, utils.errors.errorMessage(err))});
        };
        return outputPath;
    }
};

//
// The first stream of the given codec type (TypeScript: `probeData.streams.find(s => s.codec_type === type)`).
//
fn findStream(streams: []const BsonValue, codecType: []const u8) ?BsonDocument {
    for (streams) |stream| {
        switch (stream) {
            .document => |document| {
                const streamType = document.get("codec_type") orelse continue;
                if (streamType == .string and std.mem.eql(u8, streamType.string, codecType)) {
                    return document;
                }
            },
            else => {},
        }
    }
    return null;
}

//
// A property of a JavaScript value (`value?.name`), undefined when there is none.
//
fn property(value: BsonValue, name: []const u8) BsonValue {
    return switch (value) {
        .document => |document| document.get(name) orelse .undefined,
        else => .undefined,
    };
}

//
// A number property of a stream (TypeScript assigns it as is), NaN when it is not a number.
//
fn numberProperty(document: BsonDocument, name: []const u8) f64 {
    return switch (document.get(name) orelse BsonValue.undefined) {
        .number, .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        else => std.math.nan(f64),
    };
}

//
// The text `parseFloat` and `parseInt` read from a value (`String(value)` for a string, "undefined" otherwise,
// which parses to NaN).
//
fn textOf(value: BsonValue) []const u8 {
    return switch (value) {
        .string => |text| text,
        else => "undefined",
    };
}

//
// JavaScript truthiness of a value.
//
fn isTruthy(value: BsonValue) bool {
    return switch (value) {
        .number, .double => |number| number != 0 and !std.math.isNan(number),
        .int32 => |number| number != 0,
        .string => |text| text.len > 0,
        .undefined, .null => false,
        .boolean => |boolean| boolean,
        else => true,
    };
}

//
// JavaScript's `Number(text)` for a string: the trimmed text as a decimal number, 0 when it is empty, NaN when it
// is not a number.
//
fn jsNumber(text: []const u8) f64 {
    const trimmed = std.mem.trim(u8, text, " \t\n\r\x0b\x0c");
    if (trimmed.len == 0) {
        return 0;
    }
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

//
// JavaScript's `Math.round`: rounds half up.
//
fn jsRound(value: f64) f64 {
    return @floor(value + 0.5);
}

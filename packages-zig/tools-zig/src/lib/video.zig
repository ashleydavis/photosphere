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
const parseInt = utils.js_number.parseInt;
const stringToNumber = utils.js_number.stringToNumber;
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
            return errors.throwError("Failed to get video info: {s}", .{try utils.errors.errorToString(allocator, err)});
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

        const probeData = switch (try jsonParse(allocator, result.stdout)) {
            .document => |document| document,

            // `probeData.format` of null throws; any other value that is not an object has no format and no streams.
            .null => return typeError("null is not an object (evaluating 'probeData.format')"),
            else => return typeError("undefined is not an object (evaluating 'probeData.streams.find')"),
        };
        const format = probeData.get("format") orelse BsonValue.undefined;
        const streams = switch (probeData.get("streams") orelse BsonValue.undefined) {
            .array => |items| items,
            .undefined => return typeError("undefined is not an object (evaluating 'probeData.streams.find')"),
            .null => return typeError("null is not an object (evaluating 'probeData.streams.find')"),
            else => return typeError("probeData.streams.find is not a function. (In 'probeData.streams.find((s) => s.codec_type === \"video\")', 'probeData.streams.find' is undefined)"),
        };
        const videoStream = try findStream(streams, "video");
        const audioStream = try findStream(streams, "audio");
        const stream = videoStream orelse {
            return errors.throwError("No video stream found in file", .{});
        };

        // Parse creation time if available
        var createdAt: ?f64 = null;
        const tags = switch (format) {
            .undefined => return typeError("undefined is not an object (evaluating 'format.tags')"),
            .null => return typeError("null is not an object (evaluating 'format.tags')"),
            else => property(format, "tags"),
        };
        const creationTime = property(tags, "creation_time");
        if (isTruthy(creationTime)) {
            createdAt = try newDate(allocator, creationTime);
        }

        // Parse framerate
        var fps: ?f64 = null;
        const frameRate = property(.{ .document = stream }, "r_frame_rate");
        if (isTruthy(frameRate)) {
            if (frameRate != .string) {
                return typeError("videoStream.r_frame_rate.split is not a function. (In 'videoStream.r_frame_rate.split(\"/\")', 'videoStream.r_frame_rate.split' is undefined)");
            }
            var parts = std.mem.splitScalar(u8, frameRate.string, '/');
            const num = stringToNumber(parts.next() orelse "");
            const den = if (parts.next()) |text| stringToNumber(text) else std.math.nan(f64);
            fps = num / den;
        }

        var metadata: BsonDocument = .{};
        try spreadInto(allocator, &metadata, tags);
        try metadata.put(allocator, "videoCodec", property(.{ .document = stream }, "codec_name"));
        try metadata.put(allocator, "audioCodec", if (audioStream) |audio| property(.{ .document = audio }, "codec_name") else .undefined);
        try metadata.put(allocator, "pixelFormat", property(.{ .document = stream }, "pix_fmt"));

        return .{
            .filePath = self.filePath,

            .dimensions = .{
                .width = numberProperty(stream, "width"),
                .height = numberProperty(stream, "height"),
            },

            .duration = parseFloat(try jsString(allocator, property(format, "duration"))),
            .fps = fps,
            .bitrate = parseInt(try jsString(allocator, property(format, "bit_rate")), null),
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

        var command: std.Io.Writer.Allocating = .init(allocator);
        try command.writer.print("{s} -i \"{s}\" -ss ", .{ ffmpegCommand, self.filePath });
        try utils.js_number.writeNumber(&command.writer, timeInSeconds);
        try command.writer.writeAll(" -vframes 1");

        // Add quality
        try command.writer.writeAll(" -q:v ");
        try utils.js_number.writeNumber(&command.writer, jsRound((100 - quality) / 10));

        // Force overwrite and specify output
        try command.writer.print(" -y \"{s}\"", .{outputPath});

        _ = exec(allocator, io, command.written()) catch |err| {
            return errors.throwError("Failed to extract screenshot: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
        return outputPath;
    }
};

//
// The first stream of the given codec type (TypeScript: `probeData.streams.find(s => s.codec_type === type)`), which
// throws Bun's TypeError at a null stream it reaches.
//
fn findStream(streams: []const BsonValue, codecType: []const u8) !?BsonDocument {
    for (streams) |stream| {
        switch (stream) {
            .document => |document| {
                const streamType = document.get("codec_type") orelse continue;
                if (streamType == .string and std.mem.eql(u8, streamType.string, codecType)) {
                    return document;
                }
            },
            .null => return typeError("null is not an object (evaluating 's.codec_type')"),
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
// `String(value)` for a value JSON.parse gives, the text `parseFloat` and `parseInt` read: an array is its elements
// joined with commas (null elements as nothing), and an object is "[object Object]".
//
fn jsString(allocator: std.mem.Allocator, value: BsonValue) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeJsString(&output.writer, value);
    return output.written();
}

//
// Writes `String(value)` for a value JSON.parse gives.
//
fn writeJsString(writer: *std.Io.Writer, value: BsonValue) std.Io.Writer.Error!void {
    switch (value) {
        .string => |text| try writer.writeAll(text),
        .number, .double => |number| try utils.js_number.writeNumber(writer, number),
        .int32 => |number| try writer.print("{d}", .{number}),
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .null => try writer.writeAll("null"),
        .undefined => try writer.writeAll("undefined"),
        .array => |elements| {
            for (elements, 0..) |element, elementIndex| {
                if (elementIndex > 0) {
                    try writer.writeAll(",");
                }
                if (element != .null and element != .undefined) {
                    try writeJsString(writer, element);
                }
            }
        },
        else => try writer.writeAll("[object Object]"),
    }
}

//
// The time value of `new Date(value)` for a value JSON.parse gives: a string is parsed, a number or boolean is the
// time itself (TimeClip: NaN beyond 8.64e15, fractions dropped), and an array or object is parsed from its String().
//
fn newDate(allocator: std.mem.Allocator, value: BsonValue) !f64 {
    const time: f64 = switch (value) {
        .string => |text| return js_date.parseDate(text),
        .number, .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .boolean => |boolean| if (boolean) 1 else 0,
        .null => 0,
        else => return js_date.parseDate(try jsString(allocator, value)),
    };
    if (std.math.isNan(time) or @abs(time) > @as(f64, @floatFromInt(js_date.MAX_TIME_VALUE))) {
        return std.math.nan(f64);
    }
    return @trunc(time) + 0;
}

//
// Copies the own enumerable properties of a value JSON.parse gives into the document, as `{ ...value }` does: the
// fields of an object, the characters of a string and the elements of an array, under their index. Other values have
// none.
//
fn spreadInto(allocator: std.mem.Allocator, document: *BsonDocument, value: BsonValue) !void {
    switch (value) {
        .document => |source| {
            for (source.fields.items) |field| {
                try document.put(allocator, field.key, field.value);
            }
        },
        .string => |text| {
            // A string spreads its UTF-16 code units; a character outside the BMP gives its two surrogates, which
            // are written as U+FFFD each, as a lone surrogate is when the string is encoded as UTF-8.
            var index: usize = 0;
            var characterIndex: usize = 0;
            while (index < text.len) {
                const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
                const end = @min(index + width, text.len);
                if (width == 4) {
                    try document.put(allocator, try std.fmt.allocPrint(allocator, "{d}", .{characterIndex}), .{ .string = "\u{FFFD}" });
                    characterIndex += 1;
                    try document.put(allocator, try std.fmt.allocPrint(allocator, "{d}", .{characterIndex}), .{ .string = "\u{FFFD}" });
                }
                else {
                    try document.put(allocator, try std.fmt.allocPrint(allocator, "{d}", .{characterIndex}), .{ .string = text[index..end] });
                }
                characterIndex += 1;
                index = end;
            }
        },
        .array => |elements| {
            for (elements, 0..) |element, elementIndex| {
                try document.put(allocator, try std.fmt.allocPrint(allocator, "{d}", .{elementIndex}), element);
            }
        },
        else => {},
    }
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
// Throws the TypeError Bun throws with the message.
//
fn typeError(message: []const u8) errors.ThrownError {
    errors.recordError("TypeError", "{s}", .{message});
    return error.Thrown;
}

//
// JavaScript's `Math.round`: rounds half up.
//
fn jsRound(value: f64) f64 {
    return @floor(value + 0.5);
}

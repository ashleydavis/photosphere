const std = @import("std");
const utils = @import("utils-zig");
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const Video = tools.Video;
const ffmpeg = media_tools.ffmpeg;

//
// A stream of the kind and codec, 640x360 at 25 frames a second, for the probes the tests read.
//
fn stream(kind: ffmpeg.IStreamKind, codec_name: []const u8) ffmpeg.IProbeStream {
    return .{
        .kind = kind,
        .codec_name = codec_name,
        .width = if (kind == .video) 640 else 0,
        .height = if (kind == .video) 360 else 0,
        .pixel_format = if (kind == .video) "yuv420p" else "unknown",
        .frame_rate = .{
            .numerator = 25,
            .denominator = 1,
        },
    };
}

test "readProbe reads the first video and audio streams, the tags in order, then the codecs and the pixel format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = [_]ffmpeg.ITag{
        .{
            .key = "major_brand",
            .value = "qt  ",
        },
        .{
            .key = "creation_time",
            .value = "2024-01-02T03:04:05.000000Z",
        },
    };
    const streams = [_]ffmpeg.IProbeStream{ stream(.other, "bin_data"), stream(.audio, "aac"), stream(.video, "hevc"), stream(.audio, "mp3"), stream(.video, "h264") };
    const info = try Video.readProbe(arena.allocator(), "video.mov", .{
        .duration_seconds = 12.5,
        .bit_rate = 4000000,
        .tags = &tags,
        .streams = &streams,
    });
    try std.testing.expectEqualStrings("video.mov", info.filePath);
    try std.testing.expectEqual(@as(f64, 640), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 360), info.dimensions.height);
    try std.testing.expectEqual(@as(?f64, 12.5), info.duration);
    try std.testing.expectEqual(@as(?f64, 25), info.fps);
    try std.testing.expectEqual(@as(?f64, 4000000), info.bitrate);
    try std.testing.expectEqual(@as(?bool, true), info.hasAudio);
    try std.testing.expectEqual(@as(?f64, 1704164645000), info.createdAt);
    const fields = info.metadata.?.document.fields.items;
    const expected = [_][2][]const u8{
        .{ "major_brand", "qt  " },
        .{ "creation_time", "2024-01-02T03:04:05.000000Z" },
        .{ "videoCodec", "hevc" },
        .{ "audioCodec", "aac" },
        .{ "pixelFormat", "yuv420p" },
    };
    try std.testing.expectEqual(expected.len, fields.len);
    for (expected, fields) |pair, field| {
        try std.testing.expectEqualStrings(pair[0], field.key);
        try std.testing.expectEqualStrings(pair[1], field.value.string);
    }
}

test "readProbe gives NaN for a duration, bitrate or frame rate FFmpeg cannot tell, and no audio codec without sound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var silent = stream(.video, "h264");
    silent.frame_rate = .{
        .numerator = 0,
        .denominator = 0,
    };
    const streams = [_]ffmpeg.IProbeStream{silent};
    const info = try Video.readProbe(arena.allocator(), "silent.mp4", .{
        .duration_seconds = null,
        .bit_rate = null,
        .tags = &.{},
        .streams = &streams,
    });
    try std.testing.expect(std.math.isNan(info.duration.?));
    try std.testing.expect(std.math.isNan(info.bitrate.?));
    try std.testing.expect(std.math.isNan(info.fps.?));
    try std.testing.expectEqual(@as(?bool, false), info.hasAudio);
    try std.testing.expect(info.createdAt == null);
    try std.testing.expect(info.metadata.?.document.get("audioCodec").? == .undefined);
}

test "readProbe fails for a file with no video stream, and reads an empty creation time as no date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const audio_only = [_]ffmpeg.IProbeStream{stream(.audio, "aac")};
    try std.testing.expectError(error.Thrown, Video.readProbe(arena.allocator(), "sound.m4a", .{
        .duration_seconds = 1,
        .bit_rate = 128000,
        .tags = &.{},
        .streams = &audio_only,
    }));
    try std.testing.expectEqualStrings("Failed to get video info: Error: No video stream found in file", utils.errors.lastErrorMessage());

    const tags = [_]ffmpeg.ITag{.{
        .key = "creation_time",
        .value = "",
    }};
    const video = [_]ffmpeg.IProbeStream{stream(.video, "h264")};
    const info = try Video.readProbe(arena.allocator(), "video.mp4", .{
        .duration_seconds = 1,
        .bit_rate = 128000,
        .tags = &tags,
        .streams = &video,
    });
    try std.testing.expect(info.createdAt == null);
}

test "extractScreenshot at a time JavaScript would write with an exponent takes the first frame" {
    // The time of a screenshot is a number, so a tenth of a microsecond, which JavaScript writes as 1e-7, is read as that time: the
    // first frame of test.mp4, which is 1280x720.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    const outputPath = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, "frame.jpg" });
    var video = Video.init("../test/multiple-files/test.mp4");
    try std.testing.expectEqualStrings(outputPath, try video.extractScreenshot(allocator, std.testing.io, log, outputPath, 1e-7));
    const info = try media_tools.image_magick.readImageInfo(allocator, log, outputPath);
    try std.testing.expectEqual(@as(usize, 1280), info.width);
    try std.testing.expectEqual(@as(usize, 720), info.height);
}

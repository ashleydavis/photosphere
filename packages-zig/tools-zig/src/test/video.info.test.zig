const std = @import("std");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const Video = tools.Video;

//
// A key of the metadata the TypeScript Video reports, and its value.
//
const IMetadataEntry = struct {
    // The key.
    key: []const u8,

    // The value.
    value: []const u8,
};

//
// The metadata the TypeScript Video reports for test/multiple-files/test.mp4: the container's format tags, in the
// order ffprobe lists them, then videoCodec, audioCodec and pixelFormat
// (`{ ...format.tags, videoCodec, audioCodec, pixelFormat }`). The values are what the file's headers hold, as
// ffprobe (the tool the TypeScript Video runs) reads them: an H.264 video stream in yuvj420p and an AAC audio
// stream in an isom MP4 written by Lavf 60.16.100, with a location tag.
//
const TEST_MP4_METADATA = [_]IMetadataEntry{
    .{ .key = "major_brand", .value = "isom" },
    .{ .key = "minor_version", .value = "512" },
    .{ .key = "compatible_brands", .value = "isomiso2avc1mp41" },
    .{ .key = "encoder", .value = "Lavf60.16.100" },
    .{ .key = "location-eng", .value = "-29.0190+152.1895/" },
    .{ .key = "location", .value = "-29.0190+152.1895/" },
    .{ .key = "videoCodec", .value = "h264" },
    .{ .key = "audioCodec", .value = "aac" },
    .{ .key = "pixelFormat", .value = "yuvj420p" },
};

//
// Expects the information to be what the TypeScript Video reports for test/multiple-files/test.mp4: 1280x720,
// 7.874533 seconds (format.duration), 30000/1001 frames a second (r_frame_rate), 2100080 bits a second
// (format.bit_rate), with audio, no creation_time tag and the metadata above.
//
fn expectTestMp4Info(info: tools.types.AssetInfo) !void {
    try std.testing.expectEqualStrings("../test/multiple-files/test.mp4", info.filePath);
    try std.testing.expectEqual(@as(f64, 1280), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 720), info.dimensions.height);
    try std.testing.expectEqual(@as(?f64, 7.874533), info.duration);
    try std.testing.expectEqual(@as(?f64, 30000.0 / 1001.0), info.fps);
    try std.testing.expectEqual(@as(?f64, 2100080), info.bitrate);
    try std.testing.expectEqual(@as(?bool, true), info.hasAudio);
    try std.testing.expect(info.createdAt == null);
    const fields = info.metadata.?.document.fields.items;
    try std.testing.expectEqual(TEST_MP4_METADATA.len, fields.len);
    for (TEST_MP4_METADATA, fields) |expected, field| {
        try std.testing.expectEqualStrings(expected.key, field.key);
        try std.testing.expectEqualStrings(expected.value, field.value.string);
    }
}

//
// Runs a command and returns what it printed, failing the test when it fails.
//
fn runTool(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s} failed:\n{s}\n{s}\n", .{ argv[0], result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

//
// Reads a file.
//
fn readFile(allocator: std.mem.Allocator, filePath: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, filePath, allocator, .unlimited);
}

//
// Fails a test that needs ffmpeg, loudly, where it is not installed.
//
fn requireFfmpeg(allocator: std.mem.Allocator) !void {
    if (!Video.verifyFfprobe(allocator, std.testing.io).available or !Video.verifyFfmpeg(allocator, std.testing.io).available) {
        std.debug.print("This test needs ffmpeg and ffprobe installed.\n", .{});
        return error.RequiredToolsMissing;
    }
}

test "getInfo reads a video like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);
    var video = Video.init(allocator, std.testing.io, "../test/multiple-files/test.mp4");
    const info = try video.getInfo(allocator, std.testing.io);
    try expectTestMp4Info(info);
    try std.testing.expectEqual(info.dimensions, try video.getDimensions(allocator, std.testing.io));
}

test "getInfo fails for a file that is not a video" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);
    var video = Video.init(allocator, std.testing.io, "../test/demo-news.yaml");
    try std.testing.expectError(error.Thrown, video.getInfo(allocator, std.testing.io));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get video info: "));
}

test "extractScreenshot writes the frame the TypeScript ffmpeg command writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);
    var random_bytes: [8]u8 = undefined;
    std.testing.io.random(&random_bytes);
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/video-test-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    const screenshotPath = try std.fmt.allocPrint(allocator, "{s}/screenshot.jpg", .{dir});
    const referencePath = try std.fmt.allocPrint(allocator, "{s}/reference.jpg", .{dir});

    var video = Video.init(allocator, std.testing.io, "../test/multiple-files/test.mp4");
    try std.testing.expectEqualStrings(screenshotPath, try video.extractScreenshot(allocator, std.testing.io, screenshotPath, 3.9372665));

    // A JPEG of one full size frame of the 1280x720 video.
    const screenshot = try readFile(allocator, screenshotPath);
    try std.testing.expect(std.mem.startsWith(u8, screenshot, &.{ 0xFF, 0xD8, 0xFF }));
    try std.testing.expectEqualStrings("1280,720", try runTool(allocator, &.{ "ffprobe", "-v", "quiet", "-show_entries", "stream=width,height", "-of", "csv=p=0", screenshotPath }));

    // The same bytes as the command TypeScript builds with the default quality of 85:
    // `ffmpeg -i "<file>" -ss <time> -vframes 1 -q:v 2 -y "<output>"` (Math.round((100 - 85) / 10) is 2).
    _ = try runTool(allocator, &.{ "ffmpeg", "-i", "../test/multiple-files/test.mp4", "-ss", "3.9372665", "-vframes", "1", "-q:v", "2", "-y", referencePath });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), screenshot));
}

test "getFileInfo reads images and videos like TypeScript and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);

    // An image goes to the Image: the 100x90 PNG, with no audio, no EXIF date and no video properties.
    const image = (try tools.getFileInfo(allocator, std.testing.io, "../test/test.png", "image/png")).?;
    try std.testing.expectEqualStrings("../test/test.png", image.filePath);
    try std.testing.expectEqual(@as(f64, 100), image.dimensions.width);
    try std.testing.expectEqual(@as(f64, 90), image.dimensions.height);
    try std.testing.expectEqual(@as(?bool, false), image.hasAudio);
    try std.testing.expect(image.createdAt == null);
    try std.testing.expect(image.duration == null);
    try std.testing.expect(image.fps == null);
    try std.testing.expect(image.bitrate == null);
    try std.testing.expect(image.metadata == null);

    // A video goes to the Video.
    try expectTestMp4Info((try tools.getFileInfo(allocator, std.testing.io, "../test/multiple-files/test.mp4", "video/mp4")).?);

    // Anything else has no information.
    try std.testing.expect((try tools.getFileInfo(allocator, std.testing.io, "../test/test.png", "text/plain")) == null);

    try std.testing.expectError(error.Thrown, tools.getFileInfo(allocator, std.testing.io, "../test/missing.png", "image/png"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get image info for ../test/missing.png: Error: File not found: ../test/missing.png"));
}

//
// Creates a temporary directory for a test.
//
fn makeTempDir(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    std.testing.io.random(&random_bytes);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/video-test-{s}-{x}", .{ name, std.mem.readInt(u64, &random_bytes, .little) });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return path;
}

test "getInfo reads the creation time of a silent video like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);
    const dir = try makeTempDir(allocator, "creation-time");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    // A tenth of a second of 32x16 video at 10 frames a second, with no audio and a creation_time tag.
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/silent.mp4", .{dir});
    _ = try runTool(allocator, &.{ "ffmpeg", "-v", "quiet", "-f", "lavfi", "-i", "color=c=red:s=32x16:r=10:d=0.1", "-metadata", "creation_time=2024-01-02T03:04:05.000000Z", "-pix_fmt", "yuv420p", "-y", videoPath });

    var video = Video.init(allocator, std.testing.io, videoPath);
    const info = try video.getInfo(allocator, std.testing.io);
    try std.testing.expectEqual(@as(f64, 32), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 16), info.dimensions.height);
    try std.testing.expectEqual(@as(?f64, 10), info.fps);
    try std.testing.expectEqual(@as(?bool, false), info.hasAudio);

    // TypeScript: `new Date("2024-01-02T03:04:05.000000Z")`.
    try std.testing.expectEqual(@as(?f64, 1704164645000), info.createdAt);

    // No audio stream, so the audio codec is undefined.
    try std.testing.expect(info.metadata.?.document.get("audioCodec").? == .undefined);
}

test "getInfo fails for a file with no video stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);
    const dir = try makeTempDir(allocator, "audio-only");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    const audioPath = try std.fmt.allocPrint(allocator, "{s}/audio.m4a", .{dir});
    _ = try runTool(allocator, &.{ "ffmpeg", "-v", "quiet", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-y", audioPath });

    var video = Video.init(allocator, std.testing.io, audioPath);
    try std.testing.expectError(error.Thrown, video.getInfo(allocator, std.testing.io));
    try std.testing.expectEqualStrings("Failed to get video info: Error: No video stream found in file", utils.errors.lastErrorMessage());
}

test "getInfo and extractScreenshot fail for a file that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var video = Video.init(allocator, std.testing.io, "../test/no-such-video.mp4");
    try std.testing.expectError(error.Thrown, video.getInfo(allocator, std.testing.io));
    try std.testing.expectEqualStrings("File not found: ../test/no-such-video.mp4", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, video.extractScreenshot(allocator, std.testing.io, "screenshot.jpg", 0));
    try std.testing.expectEqualStrings("File not found: ../test/no-such-video.mp4", utils.errors.lastErrorMessage());
}

test "extractScreenshot fails loudly when ffmpeg cannot write the screenshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireFfmpeg(allocator);
    const dir = try makeTempDir(allocator, "screenshot-fails");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    const screenshotPath = try std.fmt.allocPrint(allocator, "{s}/missing/screenshot.jpg", .{dir});
    var video = Video.init(allocator, std.testing.io, "../test/multiple-files/test.mp4");
    try std.testing.expectError(error.Thrown, video.extractScreenshot(allocator, std.testing.io, screenshotPath, 0));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to extract screenshot: Error: "));
}

test "getFileInfo fails loudly for a video it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.Thrown, tools.getFileInfo(allocator, std.testing.io, "../test/missing.mp4", "video/mp4"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get video info for ../test/missing.mp4: Error: File not found: ../test/missing.mp4"));
}

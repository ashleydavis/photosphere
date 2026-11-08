const std = @import("std");
const inherited_environment = @import("inherited-environment.zig");
const builtin = @import("builtin");
const ILog = @import("utils-zig").log.ILog;
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const Video = tools.Video;
const MediaTools = media_tools.MediaTools;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;

//
// A key of the metadata that Video reports, and its value.
//
const IMetadataEntry = struct {
    // The key.
    key: []const u8,

    // The value.
    value: []const u8,
};

//
// The metadata that Video reports for test/multiple-files/test.mp4: the container's format tags, in the
// order ffprobe lists them, then videoCodec, audioCodec and pixelFormat
// (`{ ...format.tags, videoCodec, audioCodec, pixelFormat }`). The values are what the file's headers hold, as
// ffprobe (the tool Video runs) reads them: an H.264 video stream in yuvj420p and an AAC audio
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
// Expects the information to be what Video reports for test/multiple-files/test.mp4: 1280x720,
// 7.874533 seconds (format.duration), 30000/1001 frames a second (r_frame_rate), 2100080 bits a second
// (format.bit_rate), with audio, no creation_time tag and the metadata above, read from the file at expectedFilePath.
//
fn expectTestMp4Info(expectedFilePath: []const u8, info: tools.types.AssetInfo) !void {
    try std.testing.expectEqualStrings(expectedFilePath, info.filePath);
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
// Runs the ffmpeg built into the program with the arguments, which do not include the tool's name, failing the test when it
// fails. It runs the same FFmpeg as Video, so the expected bytes come from the same version of it.
//
fn runBuiltInFfmpeg(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner, arguments: []const []const u8) !void {
    const result = try runner.run(runner.context, std.testing.io, log, allocator, "ffmpeg", arguments);
    if (result.exit_code != 0) {
        std.debug.print("ffmpeg failed with exit code {d}\n", .{result.exit_code});
        return error.TestUnexpectedResult;
    }
}

//
// Reads a file.
//
fn readFile(allocator: std.mem.Allocator, filePath: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, filePath, allocator, .unlimited);
}

//
// Fails a test that needs ffmpeg, loudly, when the ffmpeg or ffprobe built into the program does not run.
//
fn requireFfmpeg(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner) !void {
    if (!(try Video.verifyFfprobe(allocator, std.testing.io, log, runner)).available or !(try Video.verifyFfmpeg(allocator, std.testing.io, log, runner)).available) {
        std.debug.print("This test needs the ffmpeg and ffprobe built into the program, which did not run.\n", .{});
        return error.RequiredToolsMissing;
    }
}

test "getInfo reads a video" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    var video = Video.init("../test/multiple-files/test.mp4");
    const info = try video.getInfo(allocator, std.testing.io, log, runner);
    try expectTestMp4Info("../test/multiple-files/test.mp4", info);
    try std.testing.expectEqual(info.dimensions, try video.getDimensions(allocator, std.testing.io, log, runner));
}

test "getInfo fails for a file that is not a video" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    var video = Video.init("../test/demo-news.yaml");
    try std.testing.expectError(error.Thrown, video.getInfo(allocator, std.testing.io, log, runner));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get video info: "));
}

test "extractScreenshot writes the frame the ffmpeg command writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    var random_bytes: [8]u8 = undefined;
    std.testing.io.random(&random_bytes);
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/video-test-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });
    const screenshotPath = try std.fs.path.join(allocator, &.{ dir, "screenshot.jpg" });
    const referencePath = try std.fs.path.join(allocator, &.{ dir, "reference.jpg" });

    var video = Video.init("../test/multiple-files/test.mp4");
    try std.testing.expectEqualStrings(screenshotPath, try video.extractScreenshot(allocator, std.testing.io, log, runner, screenshotPath, 3.9372665));

    // A JPEG of one full size frame of the 1280x720 video.
    const screenshot = try readFile(allocator, screenshotPath);
    try std.testing.expect(std.mem.startsWith(u8, screenshot, &.{ 0xFF, 0xD8, 0xFF }));
    try std.testing.expectEqualStrings("1280,720", try runTool(allocator, &.{ "ffprobe", "-v", "quiet", "-show_entries", "stream=width,height", "-of", "csv=p=0", screenshotPath }));

    // The same bytes as the command built with the default quality of 85:
    // `ffmpeg -i "<file>" -ss <time> -vframes 1 -q:v 2 -y "<output>"` (Math.round((100 - 85) / 10) is 2).
    try runBuiltInFfmpeg(log, allocator, runner, &.{ "-i", "../test/multiple-files/test.mp4", "-ss", "3.9372665", "-vframes", "1", "-q:v", "2", "-y", referencePath });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), screenshot));
}

test "getFileInfo reads images and videos and nothing else" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);

    // An image goes to the Image: the 100x90 PNG, with no audio, no EXIF date and no video properties.
    const image = (try tools.getFileInfo(allocator, std.testing.io, log, runner, "../test/test.png", "image/png")).?;
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
    try expectTestMp4Info("../test/multiple-files/test.mp4", (try tools.getFileInfo(allocator, std.testing.io, log, runner, "../test/multiple-files/test.mp4", "video/mp4")).?);

    // Anything else has no information.
    try std.testing.expect((try tools.getFileInfo(allocator, std.testing.io, log, runner, "../test/test.png", "text/plain")) == null);

    try std.testing.expectError(error.Thrown, tools.getFileInfo(allocator, std.testing.io, log, runner, "../test/missing.png", "image/png"));
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

test "getInfo reads the creation time of a silent video" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    const dir = try makeTempDir(allocator, "creation-time");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });

    // A tenth of a second of 32x16 video at 10 frames a second, with no audio and a creation_time tag.
    const videoPath = try std.fs.path.join(allocator, &.{ dir, "silent.mp4" });
    _ = try runTool(allocator, &.{ "ffmpeg", "-v", "quiet", "-f", "lavfi", "-i", "color=c=red:s=32x16:r=10:d=0.1", "-metadata", "creation_time=2024-01-02T03:04:05.000000Z", "-pix_fmt", "yuv420p", "-y", videoPath });

    var video = Video.init(videoPath);
    const info = try video.getInfo(allocator, std.testing.io, log, runner);
    try std.testing.expectEqual(@as(f64, 32), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 16), info.dimensions.height);
    try std.testing.expectEqual(@as(?f64, 10), info.fps);
    try std.testing.expectEqual(@as(?bool, false), info.hasAudio);

    // The creation_time tag "2024-01-02T03:04:05.000000Z" as a time value.
    try std.testing.expectEqual(@as(?f64, 1704164645000), info.createdAt);

    // No audio stream, so the audio codec is undefined.
    try std.testing.expect(info.metadata.?.document.get("audioCodec").? == .undefined);
}

test "getInfo fails for a file with no video stream" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    const dir = try makeTempDir(allocator, "audio-only");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });
    const audioPath = try std.fs.path.join(allocator, &.{ dir, "audio.m4a" });
    _ = try runTool(allocator, &.{ "ffmpeg", "-v", "quiet", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-y", audioPath });

    var video = Video.init(audioPath);
    try std.testing.expectError(error.Thrown, video.getInfo(allocator, std.testing.io, log, runner));
    try std.testing.expectEqualStrings("Failed to get video info: Error: No video stream found in file", utils.errors.lastErrorMessage());
}

test "getInfo and extractScreenshot fail for a file that does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    var video = Video.init("../test/no-such-video.mp4");
    try std.testing.expectError(error.Thrown, video.getInfo(allocator, std.testing.io, log, runner));
    try std.testing.expectEqualStrings("File not found: ../test/no-such-video.mp4", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, video.extractScreenshot(allocator, std.testing.io, log, runner, "screenshot.jpg", 0));
    try std.testing.expectEqualStrings("File not found: ../test/no-such-video.mp4", utils.errors.lastErrorMessage());
}

test "extractScreenshot fails loudly when ffmpeg cannot write the screenshot" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    const dir = try makeTempDir(allocator, "screenshot-fails");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });
    const screenshotPath = try std.fs.path.join(allocator, &.{ dir, "missing", "screenshot.jpg" });
    var video = Video.init("../test/multiple-files/test.mp4");
    try std.testing.expectError(error.Thrown, video.extractScreenshot(allocator, std.testing.io, log, runner, screenshotPath, 0));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to extract screenshot: Error: "));
}

test "getFileInfo fails loudly for a video it cannot read" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try std.testing.expectError(error.Thrown, tools.getFileInfo(allocator, std.testing.io, log, runner, "../test/missing.mp4", "video/mp4"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get video info for ../test/missing.mp4: Error: File not found: ../test/missing.mp4"));
}

test "getInfo and extractScreenshot work on a video whose name holds $, a backtick and a double quote" {
    // The goal is to show that a path holding a space, `$`, a backtick and `"` reaches ffprobe and ffmpeg unchanged, as the source
    // and as the output. The method is to copy test.mp4 under such a name, read it, and take a screenshot to a file with such a name.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    errdefer std.debug.print("The last error: {s}\n", .{utils.errors.lastErrorMessage()});
    const dir = try makeTempDir(allocator, "special-file-name");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });
    // `"` is a reserved character in Windows file names, so it is left out there.
    const specialName = if (builtin.os.tag == .windows) "Trip $5 `a`" else "Trip $5 `a` \"b\"";
    const videoPath = try std.fs.path.join(allocator, &.{ dir, specialName ++ ".mp4" });
    try std.Io.Dir.cwd().copyFile("../test/multiple-files/test.mp4", std.Io.Dir.cwd(), videoPath, std.testing.io, .{});

    var video = Video.init(videoPath);
    try expectTestMp4Info(videoPath, try video.getInfo(allocator, std.testing.io, log, runner));

    const screenshotPath = try std.fs.path.join(allocator, &.{ dir, specialName ++ ".jpg" });
    try std.testing.expectEqualStrings(screenshotPath, try video.extractScreenshot(allocator, std.testing.io, log, runner, screenshotPath, 1));
    const screenshot = (try tools.getFileInfo(allocator, std.testing.io, log, runner, screenshotPath, "image/jpeg")).?;
    try std.testing.expectEqual(@as(f64, 1280), screenshot.dimensions.width);
    try std.testing.expectEqual(@as(f64, 720), screenshot.dimensions.height);
}

//
// A video of one of the containers and codecs the bundled FFmpeg is built to read (third-party/ffmpeg/generate-config.sh), made
// with the ffmpeg on the path, which can write all of them.
//
const IContainerCase = struct {
    // The name of the file, whose extension picks the container the ffmpeg on the path writes.
    fileName: []const u8,

    // The arguments that choose the video encoder, and the audio encoder when the video has audio.
    encoderArguments: []const []const u8,

    // Whether the video has an audio stream.
    hasAudio: bool,

    // The video codec ffprobe names.
    videoCodec: []const u8,

    // The audio codec ffprobe names, when the video has audio.
    audioCodec: ?[]const u8,
};

//
// A video of every container the bundled FFmpeg's demuxers read, between them holding every video codec its decoders decode,
// each with audio where the container takes a codec the ffmpeg on the path encodes without an extra library. There is no audio
// decoder in the bundled FFmpeg, so the audio shows that ffprobe still reports it and that a screenshot ignores it.
//
const CONTAINER_CASES = [_]IContainerCase{
    .{
        .fileName = "h264.mov",
        .encoderArguments = &.{ "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac" },
        .hasAudio = true,
        .videoCodec = "h264",
        .audioCodec = "aac",
    },
    .{
        .fileName = "hevc.mp4",
        .encoderArguments = &.{ "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac" },
        .hasAudio = true,
        .videoCodec = "hevc",
        .audioCodec = "aac",
    },
    .{
        .fileName = "mpeg4.mp4",
        .encoderArguments = &.{ "-c:v", "mpeg4", "-c:a", "aac" },
        .hasAudio = true,
        .videoCodec = "mpeg4",
        .audioCodec = "aac",
    },
    .{
        .fileName = "h263.3gp",
        .encoderArguments = &.{ "-c:v", "h263", "-c:a", "aac" },
        .hasAudio = true,
        .videoCodec = "h263",
        .audioCodec = "aac",
    },
    .{
        .fileName = "prores.mov",
        .encoderArguments = &.{ "-c:v", "prores_ks", "-an" },
        .hasAudio = false,
        .videoCodec = "prores",
        .audioCodec = null,
    },
    .{
        .fileName = "vp9.mkv",
        .encoderArguments = &.{ "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-c:a", "aac" },
        .hasAudio = true,
        .videoCodec = "vp9",
        .audioCodec = "aac",
    },
    .{
        .fileName = "vp8.webm",
        .encoderArguments = &.{ "-c:v", "libvpx", "-pix_fmt", "yuv420p", "-an" },
        .hasAudio = false,
        .videoCodec = "vp8",
        .audioCodec = null,
    },
    .{
        .fileName = "mjpeg.avi",
        .encoderArguments = &.{ "-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-c:a", "mp2" },
        .hasAudio = true,
        .videoCodec = "mjpeg",
        .audioCodec = "mp2",
    },
    .{
        .fileName = "mpeg1.mpg",
        .encoderArguments = &.{ "-c:v", "mpeg1video", "-c:a", "mp2" },
        .hasAudio = true,
        .videoCodec = "mpeg1video",
        .audioCodec = "mp2",
    },
    .{
        .fileName = "mpeg2.vob",
        .encoderArguments = &.{ "-c:v", "mpeg2video", "-c:a", "mp2" },
        .hasAudio = true,
        .videoCodec = "mpeg2video",
        .audioCodec = "mp2",
    },
};

test "getInfo and extractScreenshot read a video of every container and codec the bundled FFmpeg is built for" {
    // The goal is to show that the demuxers, decoders and parsers the bundled FFmpeg is built with are enough for each container and
    // codec it is meant to read. The method is to make a short 128x96 video of each with the ffmpeg on the path, read it with
    // getInfo and take a screenshot of it with extractScreenshot, the two things the import does with a video.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    const dir = try makeTempDir(allocator, "containers");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });

    for (CONTAINER_CASES) |case| {
        errdefer std.debug.print("The video that failed: {s}\nThe last error: {s}\n", .{ case.fileName, utils.errors.lastErrorMessage() });
        const videoPath = try std.fs.path.join(allocator, &.{ dir, case.fileName });

        // Half a second at 25 frames a second, a rate MPEG-1 allows, and 128x96, a size H.263 allows.
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(allocator, &.{ "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=128x96:r=25:d=0.5" });
        if (case.hasAudio) {
            try argv.appendSlice(allocator, &.{ "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5" });
        }
        try argv.appendSlice(allocator, case.encoderArguments);
        try argv.appendSlice(allocator, &.{ "-y", videoPath });
        _ = try runTool(allocator, argv.items);

        var video = Video.init(videoPath);
        const info = try video.getInfo(allocator, std.testing.io, log, runner);
        try std.testing.expectEqual(@as(f64, 128), info.dimensions.width);
        try std.testing.expectEqual(@as(f64, 96), info.dimensions.height);
        try std.testing.expectEqual(@as(?bool, case.hasAudio), info.hasAudio);
        const metadata = info.metadata.?.document;
        try std.testing.expectEqualStrings(case.videoCodec, metadata.get("videoCodec").?.string);
        if (case.audioCodec) |audioCodec| {
            try std.testing.expectEqualStrings(audioCodec, metadata.get("audioCodec").?.string);
        }
        else {
            try std.testing.expect(metadata.get("audioCodec").? == .undefined);
        }

        const screenshotPath = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.jpg", .{case.fileName}) });
        _ = try video.extractScreenshot(allocator, std.testing.io, log, runner, screenshotPath, 0);
        const screenshot = try readFile(allocator, screenshotPath);
        try std.testing.expect(std.mem.startsWith(u8, screenshot, &.{ 0xFF, 0xD8, 0xFF }));
        try std.testing.expectEqualStrings("128,96", try runTool(allocator, &.{ "ffprobe", "-v", "quiet", "-show_entries", "stream=width,height", "-of", "csv=p=0", screenshotPath }));
    }
}

test "getFileInfo refuses a video in a container the bundled FFmpeg is built without" {
    // The goal is to show that a file the import takes as a video, in a container that is not one the bundled FFmpeg is built to
    // read, is refused rather than read. The method is to write an Autodesk FLIC animation (.fli, which the import's content types
    // name video/x-fli), check that the ffmpeg on the path, which has every demuxer, reads it as a video, and check that getFileInfo
    // fails because the bundled ffprobe finds nothing that reads it.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireFfmpeg(log, allocator, runner);
    const dir = try makeTempDir(allocator, "refused-container");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ dir, @errorName(err) });

    // A FLIC file written byte by byte from the format's description (the layout FFmpeg's libavformat/flic.c reads): the 128 byte
    // header, little endian, holding the file's size (144), the FLC magic number 0xAF12, one frame, a width of 32, a height of 16 and
    // a depth of 8, then one empty frame chunk of 16 bytes with the frame magic number 0xF1FA.
    const header = [_]u8{ 0x90, 0x00, 0x00, 0x00, 0x12, 0xAF, 0x01, 0x00, 0x20, 0x00, 0x10, 0x00, 0x08, 0x00, 0x03, 0x00 } ++ [_]u8{0} ** 112;
    const frame = [_]u8{ 0x10, 0x00, 0x00, 0x00, 0xFA, 0xF1 } ++ [_]u8{0} ** 10;
    const videoPath = try std.fs.path.join(allocator, &.{ dir, "animation.fli" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = videoPath,
        .data = &(header ++ frame),
    });

    // An FFmpeg built with the FLIC demuxer reads it as a 32x16 video.
    try std.testing.expectEqualStrings("flic,32,16", try runTool(allocator, &.{ "ffprobe", "-v", "quiet", "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", videoPath }));

    try std.testing.expectError(error.Thrown, tools.getFileInfo(allocator, std.testing.io, log, runner, videoPath, "video/x-fli"));
    const message = utils.errors.lastErrorMessage();
    try std.testing.expect(std.mem.startsWith(u8, message, try std.fmt.allocPrint(allocator, "Failed to get video info for {s}: ", .{videoPath})));
    try std.testing.expect(std.mem.indexOf(u8, message, "Invalid data found when processing input") != null);
}

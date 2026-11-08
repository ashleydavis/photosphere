const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const ziggy = @import("ziggy");
const ICapturedLog = @import("captured-log.zig").ICapturedLog;

const ffmpeg = media_tools.ffmpeg;
const image_magick = media_tools.image_magick;
const magick = image_magick.c;

// The video the tests read, relative to the directory the tests run in: 1280x720 H.264 with AAC sound.
const test_video = "../test/multiple-files/test.mp4";

// The HEIC the tests read: a 2x2 grid of 512 pixel tiles of FFmpeg's testsrc2 pattern, trimmed to 1000x700, made by
// scripts/make-heic-test-image.ts.
const test_heic = "../test/heic/tiled.heic";

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

//
// Runs a program installed on the machine (the system's ffmpeg, which makes the reference pictures), failing the test when it fails.
//
fn runTool(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s} failed:\n{s}\n{s}\n", .{ argv[0], result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
}

//
// Writes, with the system's ffmpeg, a short video whose container says it was made in 1950. FFmpeg's MP4 demuxer warns when it opens
// it ("Detected creation time before 1970, parsing as unix timestamp."), and reads it all the same.
//
fn writeVideoFrom1950(allocator: std.mem.Allocator, path: []const u8) !void {
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x32:rate=10", "-frames:v", "5", "-pix_fmt", "yuv420p", "-metadata", "creation_time=1950-01-01T00:00:00Z", "-y", path });
}

//
// Writes the first half of the test video to the path: a file cut short.
//
fn writeHalfVideo(allocator: std.mem.Allocator, path: []const u8) !void {
    const whole = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, test_video, allocator, .unlimited);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = whole[0 .. whole.len / 2],
    });
}

//
// How far apart two pictures of the same size are, read with ImageMagick: the root mean squared difference of their pixels, from 0
// for the same picture to 1.
//
fn pictureDistance(allocator: std.mem.Allocator, first: []const u8, second: []const u8) !f64 {
    try image_magick.check();
    const exception = magick.AcquireExceptionInfo();
    defer _ = magick.DestroyExceptionInfo(exception);
    const first_image = try readWhole(allocator, first, exception);
    defer _ = magick.DestroyImageList(first_image);
    const second_image = try readWhole(allocator, second, exception);
    defer _ = magick.DestroyImageList(second_image);
    var distance: f64 = undefined;
    if (magick.GetImageDistortion(first_image, second_image, magick.RootMeanSquaredErrorMetric, &distance, exception) != magick.MagickTrue) {
        return error.TestUnexpectedResult;
    }
    return distance;
}

//
// Reads a picture with ImageMagick's C interface, for pictureDistance.
//
fn readWhole(allocator: std.mem.Allocator, path: []const u8, exception: [*c]magick.ExceptionInfo) ![*c]magick.Image {
    const image_info = magick.AcquireImageInfo();
    defer _ = magick.DestroyImageInfo(image_info);
    const path_z = try allocator.dupeZ(u8, path);
    _ = magick.CopyMagickString(&@as(*magick.ImageInfo, image_info).filename, path_z.ptr, image_info.*.filename.len);
    return magick.ReadImage(image_info, exception) orelse error.TestUnexpectedResult;
}

test "version gives FFmpeg's version, and FFmpeg is built under the LGPL" {
    try std.testing.expect(std.ascii.isDigit(ffmpeg.version()[0]));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(ffmpeg.c.avutil_license()), "LGPL version 2.1 or later") != null);
}

test "probeFile reads the duration, bitrate, tags and streams of a video" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const probe = try ffmpeg.probeFile(arena.allocator(), std.testing.io, utils.mute_log.MuteLog.init(), test_video);
    try std.testing.expectEqual(@as(?f64, 7.874533), probe.duration_seconds);
    try std.testing.expectEqual(@as(?i64, 2100080), probe.bit_rate);
    try std.testing.expectEqual(@as(usize, 2), probe.streams.len);
    const video = probe.streams[0];
    try std.testing.expectEqual(ffmpeg.IStreamKind.video, video.kind);
    try std.testing.expectEqualStrings("h264", video.codec_name);
    try std.testing.expectEqual(@as(i32, 1280), video.width);
    try std.testing.expectEqual(@as(i32, 720), video.height);
    try std.testing.expectEqualStrings("yuvj420p", video.pixel_format);
    try std.testing.expectEqual(@as(i32, 30000), video.frame_rate.numerator);
    try std.testing.expectEqual(@as(i32, 1001), video.frame_rate.denominator);
    const audio = probe.streams[1];
    try std.testing.expectEqual(ffmpeg.IStreamKind.audio, audio.kind);
    try std.testing.expectEqualStrings("aac", audio.codec_name);
    try std.testing.expectEqual(@as(i32, 0), audio.width);
    try std.testing.expectEqualStrings("unknown", audio.pixel_format);
    try std.testing.expectEqualStrings("major_brand", probe.tags[0].key);
    try std.testing.expectEqualStrings("isom", probe.tags[0].value);
}

test "extractFrame writes a JPEG of the video's size, of the frame the ffmpeg program takes at that time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    try ffmpeg.extractFrame(allocator, std.testing.io, log, .{
        .input_path = test_video,
        .output_path = picture_path,
        .time_seconds = 3.9372665,
        .quality = 90,
    });
    const info = try image_magick.readImageInfo(allocator, log, picture_path);
    try std.testing.expectEqual(@as(usize, 1280), info.width);
    try std.testing.expectEqual(@as(usize, 720), info.height);
    try std.testing.expectEqualStrings("JPEG", info.format);

    // The frame the system's ffmpeg takes at the same time, and one from the start of the video, which looks different.
    const reference_path = try tempFilePath(allocator, tmp_dir, "reference.png");
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-i", test_video, "-ss", "3.9372665", "-frames:v", "1", "-y", reference_path });
    const start_path = try tempFilePath(allocator, tmp_dir, "start.png");
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-i", test_video, "-frames:v", "1", "-y", start_path });
    const same = try pictureDistance(allocator, picture_path, reference_path);
    const other = try pictureDistance(allocator, picture_path, start_path);
    errdefer std.debug.print("distance to the same frame {d}, to the first frame {d}\n", .{ same, other });
    try std.testing.expect(same < 0.03);
    try std.testing.expect(other > same * 2);
}

test "extractFrame turns the frame upright as the video's display matrix says" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();

    // A 64x32 video whose display matrix turns it a quarter, as a phone held upright records one.
    const plain_path = try tempFilePath(allocator, tmp_dir, "plain.mp4");
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x32:rate=10", "-frames:v", "5", "-pix_fmt", "yuv420p", "-y", plain_path });
    const rotated_path = try tempFilePath(allocator, tmp_dir, "rotated.mp4");
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-display_rotation:v:0", "90", "-i", plain_path, "-c", "copy", "-y", rotated_path });

    const probe = try ffmpeg.probeFile(allocator, std.testing.io, log, rotated_path);
    try std.testing.expectEqual(@as(i32, 64), probe.streams[0].width);

    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.png.jpg");
    try ffmpeg.extractFrame(allocator, std.testing.io, log, .{
        .input_path = rotated_path,
        .output_path = picture_path,
        .time_seconds = 0,
        .quality = 95,
    });
    const info = try image_magick.readImageInfo(allocator, log, picture_path);
    try std.testing.expectEqual(@as(usize, 32), info.width);
    try std.testing.expectEqual(@as(usize, 64), info.height);
    const reference_path = try tempFilePath(allocator, tmp_dir, "reference.png");
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-i", rotated_path, "-frames:v", "1", "-y", reference_path });
    const distance = try pictureDistance(allocator, picture_path, reference_path);
    errdefer std.debug.print("distance {d}\n", .{distance});
    try std.testing.expect(distance < 0.05);
}

test "readPictureSize and decodePicture give the whole picture of a tiled HEIC, its tiles in place and trimmed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    const size = try ffmpeg.readPictureSize(allocator, std.testing.io, log, test_heic);
    try std.testing.expectEqual(@as(i32, 1000), size.width);
    try std.testing.expectEqual(@as(i32, 700), size.height);

    const picture_path = try tempFilePath(allocator, tmp_dir, "decoded.jpg");
    try ffmpeg.decodePicture(allocator, std.testing.io, log, .{
        .input_path = test_heic,
        .output_path = picture_path,
        .quality = 95,
    });
    const info = try image_magick.readImageInfo(allocator, log, picture_path);
    try std.testing.expectEqual(@as(usize, 1000), info.width);
    try std.testing.expectEqual(@as(usize, 700), info.height);

    // The HEIC is FFmpeg's testsrc2 pattern at 1000x700, so the decoded picture is that pattern, which a tile out of place or a grid
    // trimmed wrongly would not be.
    const reference_path = try tempFilePath(allocator, tmp_dir, "reference.png");
    try runTool(allocator, &.{ "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1000x700:rate=1", "-frames:v", "1", "-y", reference_path });
    const distance = try pictureDistance(allocator, picture_path, reference_path);
    errdefer std.debug.print("distance {d}\n", .{distance});
    try std.testing.expect(distance < 0.05);
}

test "calls run one after another, the same call and different ones, without the state of one disturbing the next" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    var round: usize = 0;
    while (round < 12) : (round += 1) {
        const probe = try ffmpeg.probeFile(allocator, std.testing.io, log, test_video);
        try std.testing.expectEqual(@as(i32, 1280), probe.streams[0].width);
        const picture_path = try tempFilePath(allocator, tmp_dir, try std.fmt.allocPrint(allocator, "frame-{d}.jpg", .{round}));
        try ffmpeg.extractFrame(allocator, std.testing.io, log, .{
            .input_path = test_video,
            .output_path = picture_path,
            .time_seconds = @floatFromInt(round % 7),
            .quality = 80,
        });
        const info = try image_magick.readImageInfo(allocator, log, picture_path);
        try std.testing.expectEqual(@as(usize, 1280), info.width);
        try std.testing.expectEqual(@as(usize, 720), info.height);
    }
}

test "a call on a file that is not there fails with FFmpeg's error naming the file, and the next call still works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const expected = try std.fmt.allocPrint(allocator, "FFmpeg could not open {s}: No such file or directory.", .{missing_path});

    try std.testing.expectError(error.Thrown, ffmpeg.probeFile(allocator, std.testing.io, log, missing_path));
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, ffmpeg.extractFrame(allocator, std.testing.io, log, .{
        .input_path = missing_path,
        .output_path = try tempFilePath(allocator, tmp_dir, "frame.jpg"),
        .time_seconds = 0,
        .quality = 90,
    }));
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, ffmpeg.readPictureSize(allocator, std.testing.io, log, missing_path));
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, ffmpeg.decodePicture(allocator, std.testing.io, log, .{
        .input_path = missing_path,
        .output_path = try tempFilePath(allocator, tmp_dir, "picture.jpg"),
        .quality = 90,
    }));
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());

    const probe = try ffmpeg.probeFile(allocator, std.testing.io, log, test_video);
    try std.testing.expectEqual(@as(i32, 1280), probe.streams[0].width);
}

test "a file that is not a video fails with FFmpeg's error, and a time past the end fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    try std.testing.expectError(error.Thrown, ffmpeg.probeFile(allocator, std.testing.io, log, "../test/demo-news.yaml"));
    try std.testing.expectEqualStrings("FFmpeg could not open ../test/demo-news.yaml: Invalid data found when processing input.", utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, ffmpeg.extractFrame(allocator, std.testing.io, log, .{
        .input_path = test_video,
        .output_path = try tempFilePath(allocator, tmp_dir, "late.jpg"),
        .time_seconds = 100,
        .quality = 90,
    }));
    try std.testing.expectEqualStrings("../test/multiple-files/test.mp4 has no frame at or after 100 seconds.", utils.errors.lastErrorMessage());
}

test "the warnings of a call that works go to the log as FFmpeg's output, naming the call and its file, and not to its errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    const old_path = try tempFilePath(allocator, tmp_dir, "old.mp4");
    try writeVideoFrom1950(allocator, old_path);

    errdefer std.debug.print("The log was given as FFmpeg's output:\n{s}\nand as errors:\n{s}\n", .{ captured.stderr.items, captured.errors.items });
    // FFmpeg's demuxer warns about the date, and reads the video all the same.
    const probe = try ffmpeg.probeFile(allocator, std.testing.io, log, old_path);
    try std.testing.expectEqual(@as(i32, 64), probe.streams[0].width);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr.items, try std.fmt.allocPrint(allocator, "ffmpeg: probe {s}: [mov,mp4", .{old_path})) != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr.items, "Detected creation time before 1970, parsing as unix timestamp.") != null);
    try std.testing.expectEqualStrings("", captured.errors.items);

    // A call with nothing to say says nothing.
    captured.stderr.clearRetainingCapacity();
    _ = try ffmpeg.probeFile(allocator, std.testing.io, log, test_video);
    try std.testing.expectEqualStrings("", captured.stderr.items);
}

test "a frame of a file cut short is still written, and a frame past the cut fails with FFmpeg's errors in the failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    const half_path = try tempFilePath(allocator, tmp_dir, "half.mp4");
    try writeHalfVideo(allocator, half_path);
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");

    // The frame is before the cut.
    try ffmpeg.extractFrame(allocator, std.testing.io, log, .{
        .input_path = half_path,
        .output_path = picture_path,
        .time_seconds = 0.5,
        .quality = 90,
    });
    try std.testing.expectEqual(@as(usize, 1280), (try image_magick.readImageInfo(allocator, log, picture_path)).width);

    // The video is read up to the cut, where FFmpeg says the file is cut short and ends it, and has no frame at seven seconds.
    try std.testing.expectError(error.Thrown, ffmpeg.extractFrame(allocator, std.testing.io, log, .{
        .input_path = half_path,
        .output_path = picture_path,
        .time_seconds = 7,
        .quality = 90,
    }));
    const message = utils.errors.lastErrorMessage();
    errdefer std.debug.print("The failure: {s}\n", .{message});
    try std.testing.expect(std.mem.startsWith(u8, message, try std.fmt.allocPrint(allocator, "{s} has no frame at or after 7 seconds.\nFFmpeg said:\n", .{half_path})));
    try std.testing.expect(std.mem.indexOf(u8, message, "partial file") != null);
}

//
// The tests that watch the standard error, which they redirect to a file by its descriptor, so they run where the program has POSIX
// descriptors (not on Windows).
//
const StandardErrorTests = struct {
    test "FFmpeg prints none of its messages to the standard error" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var captured = ICapturedLog.init(allocator);
        const log = captured.ilog();
        const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
        const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
        const old_path = try tempFilePath(allocator, tmp_dir, "old.mp4");
        try writeVideoFrom1950(allocator, old_path);

        const stderr_path = try tempFilePath(allocator, tmp_dir, "stderr.txt");
        const stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{});
        const saved_stderr = std.c.dup(2);
        try std.testing.expect(saved_stderr >= 0);
        try std.testing.expect(std.c.dup2(stderr_file.handle, 2) == 2);
        // Two calls that fail and the warnings of a call that works.
        const failed_frame = ffmpeg.extractFrame(allocator, std.testing.io, log, .{
            .input_path = missing_path,
            .output_path = picture_path,
            .time_seconds = 0,
            .quality = 90,
        });
        const failed_probe = ffmpeg.probeFile(allocator, std.testing.io, log, missing_path);
        const worked_probe = ffmpeg.probeFile(allocator, std.testing.io, log, old_path);
        const restored = std.c.dup2(saved_stderr, 2);
        _ = std.c.close(saved_stderr);
        stderr_file.close(std.testing.io);
        try std.testing.expect(restored == 2);

        try std.testing.expectError(error.Thrown, failed_frame);
        try std.testing.expectError(error.Thrown, failed_probe);
        _ = try worked_probe;
        const printed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .unlimited);
        try std.testing.expectEqualStrings("", printed);
        try std.testing.expect(captured.stderr.items.len > 0);
    }
};

comptime {
    if (builtin.os.tag != .windows) {
        _ = StandardErrorTests;
    }
}

test "rotationDegrees turns FFmpeg's rotation into the angle the ffmpeg program turns by" {
    try std.testing.expectEqual(@as(f64, 270), ffmpeg.rotationDegrees(90));
    try std.testing.expectEqual(@as(f64, 90), ffmpeg.rotationDegrees(-90));
    try std.testing.expectEqual(@as(f64, 180), ffmpeg.rotationDegrees(180));
    try std.testing.expectEqual(@as(f64, 180), ffmpeg.rotationDegrees(-180));
    try std.testing.expectEqual(@as(f64, 0), ffmpeg.rotationDegrees(0));
    try std.testing.expectEqual(@as(f64, 0), ffmpeg.rotationDegrees(-0.4));
    try std.testing.expectEqual(@as(f64, 315), ffmpeg.rotationDegrees(45));
    try std.testing.expect(std.math.isNan(ffmpeg.rotationDegrees(std.math.nan(f64))));
}

test "turnOfRotation turns as the ffmpeg program's transpose, hflip, vflip and rotate filters do" {
    const identity = [9]i32{ 65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30 };
    const mirrored = [9]i32{ -65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30 };
    const upside_down_mirrored = [9]i32{ 65536, 0, 0, 0, -65536, 0, 0, 0, 1 << 30 };
    const quarter_up = [9]i32{ 0, -65536, 0, 65536, 0, 0, 0, 0, 1 << 30 };
    const quarter_down = [9]i32{ 0, 65536, 0, -65536, 0, 0, 0, 0, 1 << 30 };
    const half = [9]i32{ -65536, 0, 0, 0, -65536, 0, 0, 0, 1 << 30 };

    try std.testing.expect(ffmpeg.turnOfRotation(identity, 0).isNone());
    try std.testing.expectEqual(image_magick.ITurn{
        .flip = true,
    }, ffmpeg.turnOfRotation(upside_down_mirrored, 0));
    // A quarter turn: clock, or cclock_flip (a transpose) when the matrix's [3] is positive.
    try std.testing.expectEqual(image_magick.ITurn{
        .rotate_degrees = 90,
    }, ffmpeg.turnOfRotation(quarter_down, 90));
    try std.testing.expectEqual(image_magick.ITurn{
        .transpose = true,
    }, ffmpeg.turnOfRotation(quarter_up, 90));
    // Three quarters: cclock, or clock_flip (a transverse) when the matrix's [3] is negative.
    try std.testing.expectEqual(image_magick.ITurn{
        .rotate_degrees = 270,
    }, ffmpeg.turnOfRotation(quarter_up, 270));
    try std.testing.expectEqual(image_magick.ITurn{
        .transverse = true,
    }, ffmpeg.turnOfRotation(quarter_down, 270));
    // A half turn: hflip for a negative [0] and vflip for a negative [4].
    try std.testing.expectEqual(image_magick.ITurn{
        .flop = true,
        .flip = true,
    }, ffmpeg.turnOfRotation(half, 180));
    try std.testing.expectEqual(image_magick.ITurn{
        .flop = true,
    }, ffmpeg.turnOfRotation(mirrored, 180));
    // Any other angle is a rotation by it, and no angle at all is no turn.
    try std.testing.expectEqual(image_magick.ITurn{
        .rotate_degrees = 45,
    }, ffmpeg.turnOfRotation(identity, 45));
    try std.testing.expect(ffmpeg.turnOfRotation(identity, std.math.nan(f64)).isNone());
}

test "placeTile copies a tile onto the canvas at its offset and leaves out what falls outside" {
    var canvas = [_]u8{0} ** (4 * 3 * 3);
    const tile_bytes = [_]u8{ 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4 };
    const tile: image_magick.IRgbPixels = .{
        .width = 2,
        .height = 2,
        .bytes = &tile_bytes,
    };
    try ffmpeg.placeTile(&canvas, 4, 3, tile, 3, 2);
    // Only the tile's top left pixel lands on the 4x3 canvas, at its bottom right corner.
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1 }, canvas[(2 * 4 + 3) * 3 ..][0..3]);
    var others: usize = 0;
    for (canvas) |byte| {
        others += byte;
    }
    try std.testing.expectEqual(@as(usize, 3), others);
    try ffmpeg.placeTile(&canvas, 4, 3, tile, 0, 0);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2, 2, 2 }, canvas[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 3, 4, 4, 4 }, canvas[4 * 3 ..][0..6]);
    try std.testing.expectError(error.Thrown, ffmpeg.placeTile(&canvas, 4, 3, tile, -1, 0));
}

//
// What one thread of the several-threads test found, which only that thread writes and the test reads once it has ended.
//
const IThreadOutcome = struct {
    // How many rounds the thread's calls all gave their own answer.
    correct_rounds: usize = 0,

    // The first thing that went wrong, or null.
    failure: ?[]const u8 = null,
};

//
// How many threads the several-threads test calls FFmpeg on at once.
//
const thread_count = 6;

//
// What one thread of the several-threads test does, with an allocator, an Io and a log of its own made on its own thread, and with
// no setup: probes the video, writes a frame at a time only this thread asks for, reads and decodes the HEIC, and probes
// a copy of the video from 1950 whose name only this thread uses, whose warning must reach this thread's log and no other's.
//
fn callEveryFunction(directory: []const u8, index: usize, outcome: *IThreadOutcome) void {
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena.deinit();
        callEveryFunctionOnce(arena.allocator(), threaded.io(), directory, index, round) catch |err| {
            // Allocated with the page allocator, because the test thread reads it after this thread's own allocator is gone; it is
            // never freed.
            outcome.failure = std.fmt.allocPrint(std.heap.page_allocator, "thread {d}, round {d}: {s}: {s}", .{ index, round, @errorName(err), utils.errors.lastErrorMessage() }) catch @panic("out of memory");
            return;
        };
        outcome.correct_rounds += 1;
    }
}

//
// One round of callEveryFunction.
//
fn callEveryFunctionOnce(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, index: usize, round: usize) !void {
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    const probe = try ffmpeg.probeFile(allocator, io, log, test_video);
    if (probe.streams[0].width != 1280) {
        return error.TheProbeIsAnotherThreads;
    }
    const picture_path = try std.fmt.allocPrint(allocator, "{s}/frame-{d}-{d}.jpg", .{ directory, index, round });
    try ffmpeg.extractFrame(allocator, io, log, .{
        .input_path = test_video,
        .output_path = picture_path,
        .time_seconds = @floatFromInt(index),
        .quality = 80,
    });
    const frame = try image_magick.readImageInfo(allocator, log, picture_path);
    if (frame.width != 1280 or frame.height != 720) {
        return error.TheFrameIsAnotherThreads;
    }
    const size = try ffmpeg.readPictureSize(allocator, io, log, test_heic);
    if (size.width != 1000 or size.height != 700) {
        return error.TheHeicSizeIsAnotherThreads;
    }
    const decoded_path = try std.fmt.allocPrint(allocator, "{s}/decoded-{d}-{d}.jpg", .{ directory, index, round });
    try ffmpeg.decodePicture(allocator, io, log, .{
        .input_path = test_heic,
        .output_path = decoded_path,
        .quality = 80,
    });
    const decoded = try image_magick.readImageInfo(allocator, log, decoded_path);
    if (decoded.width != 1000 or decoded.height != 700) {
        return error.TheDecodedHeicIsAnotherThreads;
    }
    const old_path = try std.fmt.allocPrint(allocator, "{s}/old-{d}.mp4", .{ directory, index });
    captured.stderr.clearRetainingCapacity();
    _ = try ffmpeg.probeFile(allocator, io, log, old_path);
    if (std.mem.indexOf(u8, captured.stderr.items, old_path) == null or std.mem.indexOf(u8, captured.stderr.items, "creation time before 1970") == null) {
        return error.TheWarningDidNotReachThisThreadsLog;
    }
    for (0..thread_count) |other| {
        const other_name = try std.fmt.allocPrint(allocator, "old-{d}.mp4", .{other});
        if (other != index and std.mem.indexOf(u8, captured.stderr.items, other_name) != null) {
            return error.AnotherThreadsWarningReachedThisThreadsLog;
        }
    }
}

test "every function works first on a thread of its own with no setup, and on several threads at once, each call giving its own answer to its own thread's log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const directory = try tempFilePath(allocator, tmp_dir, "");
    for (0..thread_count) |index| {
        try writeVideoFrom1950(allocator, try std.fmt.allocPrint(allocator, "{s}/old-{d}.mp4", .{ directory, index }));
    }
    var outcomes: [thread_count]IThreadOutcome = @splat(.{});
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &outcomes, 0..) |*thread, *outcome, index| {
        thread.* = try std.Thread.spawn(.{}, callEveryFunction, .{ directory, index, outcome });
    }
    for (threads) |thread| {
        thread.join();
    }
    for (outcomes) |outcome| {
        if (outcome.failure) |failure| {
            std.debug.print("A thread failed: {s}\n", .{failure});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(@as(usize, 3), outcome.correct_rounds);
    }
}

//
// A signal handler that does nothing, set before a call so the test can see whether it is still set after.
//
fn markerHandler(signal: std.posix.SIG) callconv(.c) void {
    _ = signal;
}

//
// The tests of signal handling, which exist where the program has signals (not on Windows).
//
const SignalTests = struct {
    // The `ffmpeg` program sets its own handler on SIGINT, SIGTERM and SIGXCPU and ignores SIGPIPE, for the whole process, and
    // ImageMagick sets handlers when it is asked to. The libraries as they are called here set none, so the program's own handling is
    // never replaced.
    test "FFmpeg and ImageMagick leave the handling of every signal as it was" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const log = utils.mute_log.MuteLog.init();
        const signals = [_]std.posix.SIG{ .INT, .TERM, .XCPU, .PIPE, .HUP, .QUIT };
        var previous: [signals.len]std.posix.Sigaction = undefined;
        const marker: std.posix.Sigaction = .{
            .handler = .{
                .handler = markerHandler,
            },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for (signals, 0..) |signal, index| {
            std.posix.sigaction(signal, &marker, &previous[index]);
        }
        defer for (signals, 0..) |signal, index| {
            std.posix.sigaction(signal, &previous[index], null);
        };

        const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
        try ffmpeg.extractFrame(allocator, std.testing.io, log, .{
            .input_path = test_video,
            .output_path = picture_path,
            .time_seconds = 0,
            .quality = 90,
        });
        _ = try image_magick.readImageInfo(allocator, log, picture_path);

        for (signals) |signal| {
            var after: std.posix.Sigaction = undefined;
            std.posix.sigaction(signal, null, &after);
            if (after.handler.handler != marker.handler.handler) {
                std.debug.print("The handling of {s} was not put back.\n", .{@tagName(signal)});
                return error.TestUnexpectedResult;
            }
        }
    }
};

comptime {
    if (builtin.os.tag != .windows) {
        _ = SignalTests;
    }
}

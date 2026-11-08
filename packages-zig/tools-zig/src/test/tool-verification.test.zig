const std = @import("std");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const MediaTools = media_tools.MediaTools;
const Image = tools.Image;
const Video = tools.Video;

//
// Runs a real ImageMagick command that fails (identify of a file that does not exist in the test's directory), so a status made
// from its error is the status of a tool that did not run. The tools must have been started.
//
fn failRealCommand(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir) !void {
    const log = MuteLog.init();
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    const missing = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, "missing.png" });
    try std.testing.expectError(error.Thrown, media_tools.tool_run.runChecked(allocator, std.testing.io, log, .magick, &.{ "identify", missing }));
}

test "toolRan reports unknown for ffprobe and ffmpeg when their output has no version in it" {
    const ffprobeStatus = Video.toolRan("ffprobe", "Something else");
    try std.testing.expect(ffprobeStatus.available);
    try std.testing.expectEqualStrings("unknown", ffprobeStatus.version.?);
    try std.testing.expect(ffprobeStatus.@"error" == null);

    const ffmpegStatus = Video.toolRan("ffmpeg", "Something else");
    try std.testing.expect(ffmpegStatus.available);
    try std.testing.expectEqualStrings("unknown", ffmpegStatus.version.?);
    try std.testing.expect(ffmpegStatus.@"error" == null);
}

test "toolsStatus reports every tool with its version when ImageMagick, ffprobe and ffmpeg ran" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const status = try tools.toolsStatus(
        arena.allocator(),
        Image.imageMagickRan("Version: ImageMagick 7.1.1-29 Q16-HDRI x86_64 https://imagemagick.org"),
        Video.toolRan("ffprobe", "ffprobe version 6.1.1-3ubuntu5 Copyright (c) 2007-2023 the FFmpeg developers"),
        Video.toolRan("ffmpeg", "ffmpeg version n7.0 Copyright (c) 2000-2024 the FFmpeg developers"),
    );

    try std.testing.expect(status.allAvailable);
    try std.testing.expectEqual(@as(usize, 0), status.missingTools.len);
    try std.testing.expectEqualStrings("7.1.1-29", status.magick.version.?);
    try std.testing.expectEqualStrings("6.1.1-3ubuntu5", status.ffprobe.version.?);
    try std.testing.expectEqualStrings("n7.0", status.ffmpeg.version.?);
}

test "imageMagickRan reports unknown when the version cannot be found" {
    const status = Image.imageMagickRan("Something else");

    try std.testing.expect(status.available);
    try std.testing.expectEqualStrings("unknown", status.version.?);
}

test "toolsStatus lists every missing tool when no tool ran" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();

    try failRealCommand(allocator, tmp_dir);
    const magick = try Image.imageMagickFailed(allocator, error.Thrown);
    try failRealCommand(allocator, tmp_dir);
    const ffprobe = try Video.toolFailed(allocator, "ffprobe", error.Thrown);
    try failRealCommand(allocator, tmp_dir);
    const ffmpeg = try Video.toolFailed(allocator, "ffmpeg", error.Thrown);
    const status = try tools.toolsStatus(allocator, magick, ffprobe, ffmpeg);

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 3), status.missingTools.len);
    try std.testing.expectEqualStrings("ImageMagick", status.missingTools[0]);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[1]);
    try std.testing.expectEqualStrings("ffmpeg", status.missingTools[2]);

    // Each error says the built-in tool did not run, followed by the error of the command, and gives no install advice.
    try std.testing.expect(std.mem.startsWith(u8, status.magick.@"error".?, "The ImageMagick built into the program did not run: "));
    try std.testing.expect(std.mem.startsWith(u8, status.ffprobe.@"error".?, "The ffprobe built into the program did not run: "));
    try std.testing.expect(std.mem.startsWith(u8, status.ffmpeg.@"error".?, "The ffmpeg built into the program did not run: "));
    for ([_][]const u8{ status.magick.@"error".?, status.ffprobe.@"error".?, status.ffmpeg.@"error".? }) |message| {
        try std.testing.expect(std.mem.indexOf(u8, message, "install") == null);
    }
}

test "toolsStatus lists only the missing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();

    try failRealCommand(allocator, tmp_dir);
    const ffprobe = try Video.toolFailed(allocator, "ffprobe", error.Thrown);
    const status = try tools.toolsStatus(allocator, Image.imageMagickRan("Version: ImageMagick 7.1.1-29"), ffprobe, Video.toolRan("ffmpeg", "ffmpeg version 7.0"));

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 1), status.missingTools.len);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[0]);
    try std.testing.expect(status.magick.available);
    try std.testing.expect(status.ffmpeg.available);
}

test "verifyTools reports every tool built into the program available" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();

    const status = try tools.verifyTools(allocator, io, log);

    try std.testing.expect(status.allAvailable);
    try std.testing.expectEqual(@as(usize, 0), status.missingTools.len);
    try std.testing.expect(std.mem.startsWith(u8, status.magick.version.?, "7."));
    try std.testing.expect(status.magick.@"error" == null);

    // The versions of ffprobe and ffmpeg are read after "ffprobe version " and "ffmpeg version " in their `-version` output,
    // and are "unknown" when that text is not there.
    try std.testing.expect(!std.mem.eql(u8, status.ffprobe.version.?, "unknown"));
    try std.testing.expect(status.ffprobe.@"error" == null);
    try std.testing.expect(!std.mem.eql(u8, status.ffmpeg.version.?, "unknown"));
    try std.testing.expect(status.ffmpeg.@"error" == null);
}

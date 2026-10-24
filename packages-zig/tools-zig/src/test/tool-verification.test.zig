const std = @import("std");
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const fake_tool_runner = @import("fake-tool-runner.zig");
const MediaTools = media_tools.MediaTools;
const FakeToolRunner = fake_tool_runner.FakeToolRunner;

test "verifyFfprobe and verifyFfmpeg report unknown when their output has no version in it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "ffprobe",
            .output = "Something else",
        },
        .{
            .name = "ffmpeg",
            .output = "Something else",
        },
    });

    const ffprobeStatus = try tools.Video.verifyFfprobe(allocator, io, fakeTools.runner());
    try std.testing.expect(ffprobeStatus.available);
    try std.testing.expectEqualStrings("unknown", ffprobeStatus.version.?);
    try std.testing.expect(ffprobeStatus.@"error" == null);

    const ffmpegStatus = try tools.Video.verifyFfmpeg(allocator, io, fakeTools.runner());
    try std.testing.expect(ffmpegStatus.available);
    try std.testing.expectEqualStrings("unknown", ffmpegStatus.version.?);
    try std.testing.expect(ffmpegStatus.@"error" == null);
}

test "verifyTools reports every tool with its version when ImageMagick, ffprobe and ffmpeg run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "Version: ImageMagick 7.1.1-29 Q16-HDRI x86_64 https://imagemagick.org",
        },
        .{
            .name = "ffprobe",
            .output = "ffprobe version 6.1.1-3ubuntu5 Copyright (c) 2007-2023 the FFmpeg developers",
        },
        .{
            .name = "ffmpeg",
            .output = "ffmpeg version n7.0 Copyright (c) 2000-2024 the FFmpeg developers",
        },
    });

    const status = try tools.verifyTools(allocator, io, fakeTools.runner());

    try std.testing.expect(status.allAvailable);
    try std.testing.expectEqual(@as(usize, 0), status.missingTools.len);
    try std.testing.expectEqualStrings("7.1.1-29", status.magick.version.?);
    try std.testing.expectEqualStrings("6.1.1-3ubuntu5", status.ffprobe.version.?);
    try std.testing.expectEqualStrings("n7.0", status.ffmpeg.version.?);
}

test "verifyImageMagick reports unknown when the version cannot be found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "Something else",
        },
    });

    const status = try tools.Image.verifyImageMagick(allocator, io, fakeTools.runner());

    try std.testing.expect(status.available);
    try std.testing.expectEqualStrings("unknown", status.version.?);
}

test "verifyTools lists every missing tool when no tool runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{});

    const status = try tools.verifyTools(allocator, io, fakeTools.runner());

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

test "verifyTools lists only the missing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "Version: ImageMagick 7.1.1-29",
        },
        .{
            .name = "ffmpeg",
            .output = "ffmpeg version 7.0",
        },
    });

    const status = try tools.verifyTools(allocator, io, fakeTools.runner());

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 1), status.missingTools.len);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[0]);
    try std.testing.expect(status.magick.available);
    try std.testing.expect(status.ffmpeg.available);
}

test "verifyTools reports every tool built into the program available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();

    const status = try tools.verifyTools(allocator, io, mediaTools.runner());

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

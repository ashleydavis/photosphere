const std = @import("std");
const tools = @import("tools-zig");

test "verifyFfprobe and verifyFfmpeg agree with the shell about availability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const ffprobeStatus = tools.Video.verifyFfprobe(allocator, io);
    const ffmpegStatus = tools.Video.verifyFfmpeg(allocator, io);
    if (ffprobeStatus.available) {
        try std.testing.expect(ffprobeStatus.version != null);
        try std.testing.expect(ffprobeStatus.@"error" == null);
    }
    else {
        try std.testing.expectEqualStrings("ffprobe not found. Make sure ffmpeg is installed.", ffprobeStatus.@"error".?);
    }
    if (ffmpegStatus.available) {
        try std.testing.expect(ffmpegStatus.version != null);
    }
    else {
        try std.testing.expectEqualStrings("ffmpeg not found. Make sure ffmpeg is installed.", ffmpegStatus.@"error".?);
    }
}

const std = @import("std");
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const MediaTools = media_tools.MediaTools;

test "verifyFfprobe and verifyFfmpeg find the ffprobe and ffmpeg built into the program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const ffprobeStatus = try tools.Video.verifyFfprobe(allocator, io, mediaTools.runner());
    const ffmpegStatus = try tools.Video.verifyFfmpeg(allocator, io, mediaTools.runner());
    try std.testing.expect(ffprobeStatus.available);
    try std.testing.expect(ffprobeStatus.version != null);
    try std.testing.expect(ffprobeStatus.@"error" == null);
    try std.testing.expect(ffmpegStatus.available);
    try std.testing.expect(ffmpegStatus.version != null);
    try std.testing.expect(ffmpegStatus.@"error" == null);
}

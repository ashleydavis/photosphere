const std = @import("std");
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");

test "verifyFfprobe and verifyFfmpeg find the FFmpeg built into the program" {
    const ffprobeStatus = tools.Video.verifyFfprobe();
    const ffmpegStatus = tools.Video.verifyFfmpeg();
    try std.testing.expect(ffprobeStatus.available);
    try std.testing.expectEqualStrings(media_tools.ffmpeg.version(), ffprobeStatus.version.?);
    try std.testing.expect(ffprobeStatus.@"error" == null);
    try std.testing.expect(ffmpegStatus.available);
    try std.testing.expectEqualStrings(media_tools.ffmpeg.version(), ffmpegStatus.version.?);
    try std.testing.expect(ffmpegStatus.@"error" == null);
}

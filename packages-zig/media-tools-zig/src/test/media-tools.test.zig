const std = @import("std");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");

const MediaTools = media_tools.MediaTools;

test "the runner handles magick, ffmpeg and ffprobe and no other tool" {
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const runner = tools.runner();
    try std.testing.expect(runner.handles(runner.context, "magick"));
    try std.testing.expect(runner.handles(runner.context, "ffmpeg"));
    try std.testing.expect(runner.handles(runner.context, "ffprobe"));
    try std.testing.expect(!runner.handles(runner.context, "convert"));
}

test "the runner runs magick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const runner = tools.runner();
    const result = try runner.run(runner.context, arena.allocator(), "magick", &.{"-version"});
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Version: ImageMagick 7.") != null);
}

test "the runner fails for a tool that is not built in, naming it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const runner = tools.runner();
    try std.testing.expectError(error.Thrown, runner.run(runner.context, arena.allocator(), "convert", &.{"-version"}));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "convert is not built into the program.") != null);
}

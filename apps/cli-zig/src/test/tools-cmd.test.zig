const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const ToolOutput = node_utils.in_process_tools.ToolOutput;

test "getBuiltInToolVersions reports the versions the built-in ImageMagick and FFmpeg give" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();

    const versions = try cli.tools_cmd.getBuiltInToolVersions(allocator, std.testing.io, log, mediaTools.runner());

    // The versions are the ones the built-in libraries report, read here from the libraries themselves.
    const magickVersionText = (try media_tools.ImageMagick.runMagick(std.testing.io, log, allocator, &.{"-version"})).output;
    try std.testing.expect(std.mem.indexOf(u8, magickVersionText, try std.fmt.allocPrint(allocator, "Version: ImageMagick {s} ", .{versions.magick})) != null);
    try std.testing.expect(std.mem.startsWith(u8, (try media_tools.ffmpeg.versionOutput(allocator, "ffmpeg")).output, try std.fmt.allocPrint(allocator, "ffmpeg version {s}\n", .{versions.ffmpeg})));
    try std.testing.expect(std.mem.startsWith(u8, (try media_tools.ffmpeg.versionOutput(allocator, "ffprobe")).output, try std.fmt.allocPrint(allocator, "ffprobe version {s}\n", .{versions.ffprobe})));
}

//
// A runner that takes every tool and fails every command, as a built-in ImageMagick that does not run would.
//
fn failingRun(context: ?*anyopaque, io: std.Io, _: ILog, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!ToolOutput {
    _ = context;
    _ = io;
    _ = allocator;
    _ = arguments;
    return utils.errors.throwError("{s} is broken in this test", .{tool});
}

test "getBuiltInToolVersions throws with the tool's error when the built-in ImageMagick does not run" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failingRunner: InProcessRunner = .{
        .context = null,
        .run = failingRun,
    };

    const result = cli.tools_cmd.getBuiltInToolVersions(arena.allocator(), std.testing.io, log, failingRunner);
    try std.testing.expectError(error.Thrown, result);
    const message = utils.errors.errorMessage(error.Thrown);
    try std.testing.expect(std.mem.indexOf(u8, message, "The ImageMagick built into the program did not run") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "magick is broken in this test") != null);
}

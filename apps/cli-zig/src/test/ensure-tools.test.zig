const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const ToolOutput = node_utils.in_process_tools.ToolOutput;

test "ensureMediaProcessingTools returns when the built-in tools run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();

    try cli.ensure_tools.ensureMediaProcessingTools(arena.allocator(), std.testing.io, mediaTools.runner());
}

//
// A runner that takes every tool and fails every command, as a built-in ImageMagick that does not run would.
//
fn failingRun(context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!ToolOutput {
    _ = context;
    _ = io;
    _ = allocator;
    _ = arguments;
    return utils.errors.throwError("{s} is broken in this test", .{tool});
}

//
// Says the failing runner takes the tool, so no command is started as a program.
//
fn handlesEveryTool(context: ?*anyopaque, tool: []const u8) bool {
    _ = context;
    _ = tool;
    return true;
}

test "ensureMediaProcessingTools throws with the tool's error when the built-in ImageMagick does not run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failingRunner: InProcessRunner = .{
        .context = null,
        .handles = handlesEveryTool,
        .run = failingRun,
    };

    const result = cli.ensure_tools.ensureMediaProcessingTools(arena.allocator(), std.testing.io, failingRunner);
    try std.testing.expectError(error.Thrown, result);
    const message = utils.errors.errorMessage(error.Thrown);
    try std.testing.expect(std.mem.indexOf(u8, message, "The ImageMagick built into the program did not run") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "magick is broken in this test") != null);
}

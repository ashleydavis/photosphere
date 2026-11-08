const std = @import("std");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const ziggy = @import("ziggy");

const MediaTools = media_tools.MediaTools;
const tool_run = media_tools.tool_run;

test "magick runs once the tools are started" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    defer tools.deinit();
    const output = try tool_run.runChecked(arena.allocator(), std.testing.io, log, .magick, &.{"-version"});
    try std.testing.expect(std.mem.indexOf(u8, output, "Version: ImageMagick 7.") != null);
}

//
// What a thread of the several-threads test did: whether it ran magick and ffprobe.
//
const ThreadOutcome = struct {
    // Whether `magick -version` gave ImageMagick's version.
    magick_ran: bool = false,
    // Whether `ffprobe -version` gave FFprobe's version.
    ffprobe_ran: bool = false,
};

//
// A thread of the several-threads test: runs magick and ffprobe on its own thread, with its own Io, allocator and log.
//
fn runOnOwnThread(outcome: *ThreadOutcome) void {
    const log = utils.mute_log.MuteLog.init();
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena.deinit();
    const magick = tool_run.runChecked(arena.allocator(), threaded.io(), log, .magick, &.{"-version"}) catch return;
    outcome.magick_ran = std.mem.indexOf(u8, magick, "Version: ImageMagick 7.") != null;
    const ffprobe = tool_run.runChecked(arena.allocator(), threaded.io(), log, .ffprobe, &.{"-version"}) catch return;
    outcome.ffprobe_ran = std.mem.startsWith(u8, ffprobe, "ffprobe version ");
}

test "each thread runs the tools while another thread runs them, once the main thread has started them" {
    var tools = try MediaTools.init();
    defer tools.deinit();
    var first: ThreadOutcome = .{};
    var second: ThreadOutcome = .{};
    const first_thread = try std.Thread.spawn(.{}, runOnOwnThread, .{&first});
    const second_thread = try std.Thread.spawn(.{}, runOnOwnThread, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.magick_ran);
    try std.testing.expect(first.ffprobe_ran);
    try std.testing.expect(second.magick_ran);
    try std.testing.expect(second.ffprobe_ran);
}

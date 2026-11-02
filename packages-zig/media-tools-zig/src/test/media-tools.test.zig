const std = @import("std");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const ziggy = @import("ziggy");

const MediaTools = media_tools.MediaTools;

test "the runner handles magick, ffmpeg and ffprobe and no other tool" {
    var tools = try MediaTools.init();
    defer tools.deinit();
    const runner = tools.runner();
    try std.testing.expect(runner.handles(runner.context, "magick"));
    try std.testing.expect(runner.handles(runner.context, "ffmpeg"));
    try std.testing.expect(runner.handles(runner.context, "ffprobe"));
    try std.testing.expect(!runner.handles(runner.context, "convert"));
}

test "the runner runs magick" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    defer tools.deinit();
    const runner = tools.runner();
    const result = try runner.run(runner.context, std.testing.io, log, arena.allocator(), "magick", &.{"-version"});
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Version: ImageMagick 7.") != null);
}

//
// What a thread of the per-thread runner test did: whether its runner ran magick and ffprobe, and the address of its runner.
//
const ThreadOutcome = struct {
    // Whether `magick -version` gave ImageMagick's version.
    magick_ran: bool = false,
    // Whether `ffprobe -version` gave FFprobe's version.
    ffprobe_ran: bool = false,
    // The address of the state of the runner the thread made, which no other thread's is.
    runner_state: usize = 0,
};

//
// A thread of the per-thread runner test: makes tools of its own, on its own thread with its own Io, and runs magick and ffprobe with
// their runner.
//
fn runWithOwnRunner(outcome: *ThreadOutcome) void {
    // The thread's own log, which writes to the console.
    const log = utils.mute_log.MuteLog.init();
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena.deinit();
    var tools = media_tools.ThreadTools.init();
    const runner = tools.runner();
    outcome.runner_state = @intFromPtr(runner.context.?);
    const magick = runner.run(runner.context, threaded.io(), log, arena.allocator(), "magick", &.{"-version"}) catch return;
    outcome.magick_ran = magick.exit_code == 0 and std.mem.indexOf(u8, magick.output, "Version: ImageMagick 7.") != null;
    const ffprobe = runner.run(runner.context, threaded.io(), log, arena.allocator(), "ffprobe", &.{"-version"}) catch return;
    outcome.ffprobe_ran = ffprobe.exit_code == 0 and std.mem.startsWith(u8, ffprobe.output, "ffprobe version ");
}

test "each thread makes tools of its own, and runs them while another thread runs its own" {
    var tools = try MediaTools.init();
    defer tools.deinit();
    var first: ThreadOutcome = .{};
    var second: ThreadOutcome = .{};
    const first_thread = try std.Thread.spawn(.{}, runWithOwnRunner, .{&first});
    const second_thread = try std.Thread.spawn(.{}, runWithOwnRunner, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.magick_ran);
    try std.testing.expect(first.ffprobe_ran);
    try std.testing.expect(second.magick_ran);
    try std.testing.expect(second.ffprobe_ran);
    // Each thread's runner is its own, not the main thread's.
    const main_runner_state = @intFromPtr(tools.runner().context.?);
    try std.testing.expect(first.runner_state != 0 and first.runner_state != main_runner_state);
    try std.testing.expect(second.runner_state != 0 and second.runner_state != main_runner_state);
}

test "the runner fails for a tool that is not built in, naming it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    defer tools.deinit();
    const runner = tools.runner();
    try std.testing.expectError(error.Thrown, runner.run(runner.context, std.testing.io, log, arena.allocator(), "convert", &.{"-version"}));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "convert is not built into the program.") != null);
}

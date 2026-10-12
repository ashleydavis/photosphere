const std = @import("std");
const builtin = @import("builtin");
const media_tools = @import("media-tools-zig");

const MediaTools = media_tools.MediaTools;

// The video the tests read, relative to the directory the tests run in.
const test_video = "../test/multiple-files/test.mp4";

// FFmpeg's log, which the tests that make a command fail silence so the standard error stays clean.
extern fn av_log_set_callback(callback: *const fn (?*anyopaque, c_int, [*c]const u8, ?*anyopaque) callconv(.c) void) void;
extern fn av_log_default_callback(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) void;

//
// A log callback that prints nothing.
//
fn silentLog(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void {
    _ = avcl;
    _ = level;
    _ = fmt;
    _ = vl;
}

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

//
// What ffprobe reports of a video: the width and height of its first video stream and the duration of the file, as text.
//
const IProbed = struct {
    width: i64,
    height: i64,
    duration: []const u8,
};

//
// Probes a video with the arguments the app uses, and reads the report.
//
fn probe(allocator: std.mem.Allocator, tools: *MediaTools, path: []const u8) !IProbed {
    const result = try tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    const report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, result.output, .{});
    for (report.object.get("streams").?.array.items) |stream| {
        const codec_type = stream.object.get("codec_type").?.string;
        if (std.mem.eql(u8, codec_type, "video")) {
            return .{
                .width = stream.object.get("width").?.integer,
                .height = stream.object.get("height").?.integer,
                .duration = report.object.get("format").?.object.get("duration").?.string,
            };
        }
    }
    return error.NoVideoStream;
}

test "ffprobe -version and ffmpeg -version give the version in the line the app reads it from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    const ffprobe = try tools.ffmpeg.runFfprobe(arena.allocator(), &.{"-version"});
    try std.testing.expectEqual(@as(i32, 0), ffprobe.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, ffprobe.output, "ffprobe version "));
    try std.testing.expect(std.ascii.isDigit(ffprobe.output["ffprobe version ".len]));
    const ffmpeg = try tools.ffmpeg.runFfmpeg(arena.allocator(), &.{"-version"});
    try std.testing.expect(std.mem.startsWith(u8, ffmpeg.output, "ffmpeg version "));
    try std.testing.expect(std.mem.indexOf(u8, ffmpeg.output, "license: LGPL version 2.1 or later") != null);
}

test "ffprobe reports the streams and the format of a video as JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    const probed = try probe(arena.allocator(), &tools, test_video);
    try std.testing.expect(probed.width > 0);
    try std.testing.expect(probed.height > 0);
    try std.testing.expect(try std.fmt.parseFloat(f64, probed.duration) > 0);
}

test "ffmpeg writes a JPEG of a frame of a video that ImageMagick reads at the video's size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    const probed = try probe(allocator, &tools, test_video);
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const result = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-q:v", "2", "-y", picture_path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    const size = try tools.image_magick.runMagick(allocator, &.{ picture_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{d} {d}", .{ probed.width, probed.height }), size.output);
}

test "ffmpeg scales the frame it writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    const picture_path = try tempFilePath(allocator, tmp_dir, "small.jpg");
    const result = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-vf", "scale=64:48", "-q:v", "5", "-y", picture_path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    const size = try tools.image_magick.runMagick(allocator, &.{ picture_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings("64 48", size.output);
}

test "commands run one after another, the same command and different ones, without the state of one disturbing the next" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    const first = try probe(allocator, &tools, test_video);
    var round: usize = 0;
    while (round < 12) : (round += 1) {
        const again = try probe(allocator, &tools, test_video);
        try std.testing.expectEqual(first.width, again.width);
        try std.testing.expectEqual(first.height, again.height);
        const picture_path = try tempFilePath(allocator, tmp_dir, try std.fmt.allocPrint(allocator, "frame-{d}.jpg", .{round}));
        const result = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-q:v", "2", "-y", picture_path });
        try std.testing.expectEqual(@as(i32, 0), result.exit_code);
        const size = try tools.image_magick.runMagick(allocator, &.{ picture_path, "-format", "%w %h", "info:" });
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{d} {d}", .{ first.width, first.height }), size.output);
    }
}

test "a command that fails ends with a non-zero exit code and the next command still works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    av_log_set_callback(silentLog);
    defer av_log_set_callback(@ptrCast(&av_log_default_callback));
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const ffmpeg = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
    try std.testing.expect(ffmpeg.exit_code != 0);
    const ffprobe = try tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", missing_path });
    try std.testing.expect(ffprobe.exit_code != 0);
    const probed = try probe(allocator, &tools, test_video);
    try std.testing.expect(probed.width > 0);
}

test "buildArgv puts the program, the leading options and the arguments in order, ending with a null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try media_tools.ffmpeg.buildArgv(arena.allocator(), "ffmpeg", &.{ "-nostdin", "-loglevel", "error" }, &.{ "-i", "a b.mp4" });
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("ffmpeg", std.mem.span(argv[0]));
    try std.testing.expectEqualStrings("-nostdin", std.mem.span(argv[1]));
    try std.testing.expectEqualStrings("error", std.mem.span(argv[3]));
    try std.testing.expectEqualStrings("-i", std.mem.span(argv[4]));
    try std.testing.expectEqualStrings("a b.mp4", std.mem.span(argv[5]));
    try std.testing.expect(argv[6] == null);
}

//
// What one thread of the concurrency test runs.
//
const IWorker = struct {
    // The tools all the threads run commands on.
    tools: *MediaTools,

    // How many times the video's size was read correctly.
    correct: usize,

    // The width the video has.
    width: i64,

    //
    // Probes the video over and over, as tasks that hash files do at the same time.
    //
    fn run(worker: *IWorker) void {
        var round: usize = 0;
        while (round < 5) : (round += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const probed = probe(arena.allocator(), worker.tools, test_video) catch {
                return;
            };
            if (probed.width == worker.width) {
                worker.correct += 1;
            }
        }
    }
};

test "commands run on several threads at once all give their own answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    const expected = try probe(arena.allocator(), &tools, test_video);
    var workers: [6]IWorker = undefined;
    var threads: [6]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{
            .tools = &tools,
            .correct = 0,
            .width = expected.width,
        };
        thread.* = try std.Thread.spawn(.{}, IWorker.run, .{worker});
    }
    for (threads) |thread| {
        thread.join();
    }
    for (workers) |worker| {
        try std.testing.expectEqual(@as(usize, 5), worker.correct);
    }
}

//
// A signal handler that does nothing, set before a run so the test can see whether it is still set after.
//
fn markerHandler(signal: std.posix.SIG) callconv(.c) void {
    _ = signal;
}

//
// The tests of the signals ffmpeg takes over, which exist where the program has signals to take over (not on Windows).
//
const SignalTests = struct {
    // ffmpeg's term_init sets its own handler on SIGINT, SIGTERM and SIGXCPU and ignores SIGPIPE, which would leave the program's
    // own handling replaced after every command.
    test "ffmpeg leaves the handling of every signal it takes over as it was before the run" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var tools = MediaTools.init(std.testing.io);
        defer tools.deinit();
        const signals = [_]std.posix.SIG{ .INT, .TERM, .XCPU, .PIPE };
        var previous: [signals.len]std.posix.Sigaction = undefined;
        const marker: std.posix.Sigaction = .{
            .handler = .{
                .handler = markerHandler,
            },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for (signals, 0..) |signal, index| {
            std.posix.sigaction(signal, &marker, &previous[index]);
        }
        defer for (signals, 0..) |signal, index| {
            std.posix.sigaction(signal, &previous[index], null);
        };

        const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
        const result = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-q:v", "2", "-y", picture_path });
        try std.testing.expectEqual(@as(i32, 0), result.exit_code);

        for (signals) |signal| {
            var after: std.posix.Sigaction = undefined;
            std.posix.sigaction(signal, null, &after);
            if (after.handler.handler != marker.handler.handler) {
                std.debug.print("The handling of {s} was not put back.\n", .{@tagName(signal)});
                return error.TestUnexpectedResult;
            }
        }
    }
};

comptime {
    if (builtin.os.tag != .windows) {
        _ = SignalTests;
    }
}

// ffprobe that stops at an option it does not know never opens its report, which is a failed command with nothing printed rather
// than an error of the runner's.
test "ffprobe that fails before it writes its report gives a non-zero exit code and no output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = MediaTools.init(std.testing.io);
    defer tools.deinit();
    av_log_set_callback(silentLog);
    defer av_log_set_callback(@ptrCast(&av_log_default_callback));
    const result = try tools.ffmpeg.runFfprobe(arena.allocator(), &.{ "-no-such-option", test_video });
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expectEqualStrings("", result.output);
}

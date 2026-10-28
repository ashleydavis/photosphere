const std = @import("std");
const inherited_environment = @import("inherited-environment.zig");
const ILog = @import("utils-zig").log.ILog;
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const ziggy = @import("ziggy");

const MediaTools = media_tools.MediaTools;
const Ffmpeg = media_tools.Ffmpeg;
const ImageMagick = media_tools.ImageMagick;

// The video the tests read, relative to the directory the tests run in.
const test_video = "../test/multiple-files/test.mp4";

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
fn probe(log: ILog, allocator: std.mem.Allocator, path: []const u8) !IProbed {
    const result = try Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path });
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
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const ffprobe = try Ffmpeg.runFfprobe(std.testing.io, log, arena.allocator(), &.{"-version"});
    try std.testing.expectEqual(@as(i32, 0), ffprobe.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, ffprobe.output, "ffprobe version "));
    try std.testing.expect(std.ascii.isDigit(ffprobe.output["ffprobe version ".len]));
    const ffmpeg = try Ffmpeg.runFfmpeg(std.testing.io, log, arena.allocator(), &.{"-version"});
    try std.testing.expect(std.mem.startsWith(u8, ffmpeg.output, "ffmpeg version "));
    try std.testing.expect(std.mem.indexOf(u8, ffmpeg.output, "license: LGPL version 2.1 or later") != null);
}

test "ffprobe reports the streams and the format of a video as JSON" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const probed = try probe(log, arena.allocator(), test_video);
    try std.testing.expect(probed.width > 0);
    try std.testing.expect(probed.height > 0);
    try std.testing.expect(try std.fmt.parseFloat(f64, probed.duration) > 0);
}

test "ffmpeg writes a JPEG of a frame of a video that ImageMagick reads at the video's size" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const probed = try probe(log, allocator, test_video);
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const result = try Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-q:v", "2", "-y", picture_path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    const size = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ picture_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{d} {d}", .{ probed.width, probed.height }), size.output);
}

test "ffmpeg scales the frame it writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const picture_path = try tempFilePath(allocator, tmp_dir, "small.jpg");
    const result = try Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-vf", "scale=64:48", "-q:v", "5", "-y", picture_path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    const size = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ picture_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings("64 48", size.output);
}

test "commands run one after another, the same command and different ones, without the state of one disturbing the next" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const first = try probe(log, allocator, test_video);
    var round: usize = 0;
    while (round < 12) : (round += 1) {
        const again = try probe(log, allocator, test_video);
        try std.testing.expectEqual(first.width, again.width);
        try std.testing.expectEqual(first.height, again.height);
        const picture_path = try tempFilePath(allocator, tmp_dir, try std.fmt.allocPrint(allocator, "frame-{d}.jpg", .{round}));
        const result = try Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-q:v", "2", "-y", picture_path });
        try std.testing.expectEqual(@as(i32, 0), result.exit_code);
        const size = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ picture_path, "-format", "%w %h", "info:" });
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{d} {d}", .{ first.width, first.height }), size.output);
    }
}

test "a command that fails ends with a non-zero exit code and the next command still works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    // FFmpeg's errors go to the log, which keeps them here so the test prints nothing.
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const ffmpeg = try Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
    try std.testing.expect(ffmpeg.exit_code != 0);
    const ffprobe = try Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", missing_path });
    try std.testing.expect(ffprobe.exit_code != 0);
    const probed = try probe(log, allocator, test_video);
    try std.testing.expect(probed.width > 0);
}

//
// A log that keeps the errors and the standard error of the tools it is given, and ignores everything else. It is given to a run,
// which every message of the run reaches, from whichever of the run's threads logged it.
//
const ICapturedLog = struct {
    // Every error the log was given, each on a line of its own.
    errors: std.ArrayList(u8),

    // Every tool name and standard error the log was given, one after another.
    stderr: std.ArrayList(u8),

    // The allocator the text is kept with.
    allocator: std.mem.Allocator,

    //
    // Keeps an error.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        const self: *ICapturedLog = @ptrCast(@alignCast(ptr));
        self.errors.print(self.allocator, "{s}\n", .{message}) catch @panic("out of memory keeping an error");
    }

    //
    // Keeps the standard error of a tool.
    //
    fn tool(ptr: *anyopaque, tool_name: []const u8, data: utils.log.IToolOutput) void {
        const self: *ICapturedLog = @ptrCast(@alignCast(ptr));
        if (data.stderr) |stderr| {
            self.stderr.print(self.allocator, "{s}: {s}", .{ tool_name, stderr }) catch @panic("out of memory keeping a tool's output");
        }
    }

    //
    // Ignores a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Ignores an error with its cause.
    //
    fn ignoreException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        _ = message;
        _ = @intFromError(err);
    }

    //
    // Verbose logging is off.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    //
    // The log has no file.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return utils.log.noLogDetails;
    }

    //
    // This log writes no file.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }

    // The ILog functions of the log.
    const vtable: utils.log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = ignoreMessage,
        .@"error" = logError,
        .exception = ignoreException,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = tool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };

    //
    // Makes the log, which keeps nothing yet.
    //
    fn init(allocator: std.mem.Allocator) ICapturedLog {
        return .{
            .errors = .empty,
            .stderr = .empty,
            .allocator = allocator,
        };
    }

    //
    // The ILog interface of this log, for the runs it is given to.
    //
    fn ilog(self: *ICapturedLog) utils.log.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "a failed ffmpeg run sends FFmpeg's errors, naming the file, to the log's errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const result = try Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, captured.errors.items, "Error opening input: No such file or directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.errors.items, missing_path) != null);
}

test "a failed ffprobe hands back FFmpeg's error in its output, and a probe that works hands back no error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const failed = try Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", missing_path });
    try std.testing.expect(failed.exit_code != 0);
    const report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, failed.output, .{});
    const report_error = report.object.get("error") orelse return error.TheReportHasNoError;
    try std.testing.expectEqualStrings("No such file or directory", report_error.object.get("string").?.string);
    const worked = try Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", test_video });
    try std.testing.expectEqual(@as(i32, 0), worked.exit_code);
    const worked_report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, worked.output, .{});
    try std.testing.expect(worked_report.object.get("error") == null);
    try std.testing.expect(worked_report.object.get("format") != null);
}

test "the messages of an ffprobe run that worked go to the log as the tool's standard error, and not into its report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();

    // At the info level ffprobe describes the file it opened ("Input #0, ...") through FFmpeg's log.
    const result = try Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "info", "-hide_banner", "-print_format", "json", "-show_format", test_video });
    // On Windows every in-process ffmpeg and ffprobe run in these tests exited 1 while psi read videos there, and the failure said
    // only "expected 0, found 1", so what FFmpeg said about it is printed with the failure.
    if (result.exit_code != 0) {
        std.debug.print("ffprobe exited with {d}. Its messages:\n{s}\nIts errors:\n{s}\n", .{ result.exit_code, captured.stderr.items, captured.errors.items });
    }
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr.items, "ffprobe: Input #0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Input #0") == null);
    const report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, result.output, .{});
    try std.testing.expect(report.object.get("format") != null);
    try std.testing.expectEqualStrings("", captured.errors.items);
}

//
// The tests that watch the standard error, which they redirect to a file by its descriptor, so they run where the program has POSIX
// descriptors (not on Windows).
//
const StandardErrorTests = struct {
    test "FFmpeg prints none of its messages to the standard error" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var captured = ICapturedLog.init(allocator);
        const log = captured.ilog();
        var tools = try MediaTools.init();
        const environment = try inherited_environment.inherit(std.testing.allocator);
        defer inherited_environment.restore(std.testing.allocator, environment);
        defer tools.deinit();
        const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
        const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");

        const stderr_path = try tempFilePath(allocator, tmp_dir, "stderr.txt");
        const stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{});
        const saved_stderr = std.c.dup(2);
        try std.testing.expect(saved_stderr >= 0);
        try std.testing.expect(std.c.dup2(stderr_file.handle, 2) == 2);
        // An error from `ffmpeg`, an error from `ffprobe` and the messages of an `ffprobe` that worked.
        const failed_ffmpeg = Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
        const failed_ffprobe = Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "error", "-print_format", "json", "-show_format", missing_path });
        const worked_ffprobe = Ffmpeg.runFfprobe(std.testing.io, log, allocator, &.{ "-v", "info", "-print_format", "json", "-show_format", test_video });
        const restored = std.c.dup2(saved_stderr, 2);
        _ = std.c.close(saved_stderr);
        stderr_file.close(std.testing.io);
        try std.testing.expect(restored == 2);

        try std.testing.expect((try failed_ffmpeg).exit_code != 0);
        try std.testing.expect((try failed_ffprobe).exit_code != 0);
        try std.testing.expectEqual(@as(i32, 0), (try worked_ffprobe).exit_code);
        const printed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .unlimited);
        try std.testing.expectEqualStrings("", printed);
        try std.testing.expect(captured.errors.items.len > 0);
        try std.testing.expect(captured.stderr.items.len > 0);
    }
};

comptime {
    if (builtin.os.tag != .windows) {
        _ = StandardErrorTests;
    }
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
// What one thread of the several-threads test found, which only that thread writes and the test reads once it has ended.
//
const IThreadOutcome = struct {
    // How many rounds the thread's runs all gave the answer of its own arguments.
    correct_rounds: usize = 0,

    // The first thing that went wrong, or null.
    failure: ?[]const u8 = null,
};

//
// How many threads the several-threads test runs commands on at once.
//
const thread_count = 6;

//
// What one thread of the several-threads test does: with a runner and a log of its own, made on its own thread, it probes the video,
// has ffmpeg write a frame scaled to a size only this thread asks for, reads the frame's size with ImageMagick, and runs an ffmpeg
// that fails on a file named after the thread, whose error must reach this thread's log and no other's.
//
fn runCommandsOfOwn(directory: []const u8, index: usize, expected_width: i64, outcome: *IThreadOutcome) void {
    var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();
    var tools = media_tools.ThreadTools.init();
    const runner = tools.runner();
    const width = 16 * (index + 1);
    const height = 12 * (index + 1);
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const probed = runner.run(runner.context, threaded.io(), log, allocator, "ffprobe", &.{ "-v", "quiet", "-print_format", "json", "-show_streams", test_video }) catch {
            outcome.failure = "ffprobe failed to run";
            return;
        };
        const report = std.json.parseFromSliceLeaky(std.json.Value, allocator, probed.output, .{}) catch {
            outcome.failure = "ffprobe's report is not JSON";
            return;
        };
        var probed_width: i64 = 0;
        for (report.object.get("streams").?.array.items) |stream| {
            if (std.mem.eql(u8, stream.object.get("codec_type").?.string, "video")) {
                probed_width = stream.object.get("width").?.integer;
            }
        }
        const picture_path = std.fmt.allocPrint(allocator, "{s}/frame-{d}-{d}.jpg", .{ directory, index, round }) catch @panic("out of memory");
        const scale = std.fmt.allocPrint(allocator, "scale={d}:{d}", .{ width, height }) catch @panic("out of memory");
        const written = runner.run(runner.context, threaded.io(), log, allocator, "ffmpeg", &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-vf", scale, "-q:v", "5", "-y", picture_path }) catch {
            outcome.failure = "ffmpeg failed to run";
            return;
        };
        const size = runner.run(runner.context, threaded.io(), log, allocator, "magick", &.{ picture_path, "-format", "%w %h", "info:" }) catch {
            outcome.failure = "magick failed to run";
            return;
        };
        const missing_path = std.fmt.allocPrint(allocator, "{s}/missing-{d}.mp4", .{ directory, index }) catch @panic("out of memory");
        const failed = runner.run(runner.context, threaded.io(), log, allocator, "ffmpeg", &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path }) catch {
            outcome.failure = "the failing ffmpeg failed to run";
            return;
        };
        const expected_size = std.fmt.allocPrint(allocator, "{d} {d}", .{ width, height }) catch @panic("out of memory");
        if (probed.exit_code != 0 or probed_width != expected_width) {
            outcome.failure = "ffprobe gave the wrong width";
            return;
        }
        if (written.exit_code != 0 or !std.mem.eql(u8, size.output, expected_size)) {
            outcome.failure = "the frame ffmpeg wrote is not the size this thread asked for";
            return;
        }
        if (failed.exit_code == 0 or std.mem.indexOf(u8, captured.errors.items, missing_path) == null) {
            outcome.failure = "the failing ffmpeg's error did not reach this thread's log";
            return;
        }
        var other: usize = 0;
        while (other < thread_count) : (other += 1) {
            const other_missing = std.fmt.allocPrint(allocator, "missing-{d}.mp4", .{other}) catch @panic("out of memory");
            if (other != index and std.mem.indexOf(u8, captured.errors.items, other_missing) != null) {
                outcome.failure = "another thread's error reached this thread's log";
                return;
            }
        }
        outcome.correct_rounds += 1;
    }
}

test "ffmpeg and ffprobe run on several threads at once, each run giving the answer of its own arguments to its own thread's log" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const expected = try probe(log, allocator, test_video);
    const directory = try tempFilePath(allocator, tmp_dir, "");
    var outcomes: [thread_count]IThreadOutcome = @splat(.{});
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &outcomes, 0..) |*thread, *outcome, index| {
        thread.* = try std.Thread.spawn(.{}, runCommandsOfOwn, .{ directory, index, expected.width, outcome });
    }
    for (threads) |thread| {
        thread.join();
    }
    for (outcomes) |outcome| {
        if (outcome.failure) |failure| {
            std.debug.print("A thread failed: {s}\n", .{failure});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(@as(usize, 3), outcome.correct_rounds);
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
    // Upstream ffmpeg's term_init sets its own handler on SIGINT, SIGTERM and SIGXCPU and ignores SIGPIPE, for the whole process. The
    // patched one (third-party/ffmpeg/fftools-per-run-state.patch) sets none, so the program's own handling is never replaced.
    test "ffmpeg leaves the handling of every signal it takes over as it was before the run" {
        const log = utils.mute_log.MuteLog.init();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var tools = try MediaTools.init();
        const environment = try inherited_environment.inherit(std.testing.allocator);
        defer inherited_environment.restore(std.testing.allocator, environment);
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
        const result = try Ffmpeg.runFfmpeg(std.testing.io, log, allocator, &.{ "-i", test_video, "-ss", "0", "-vframes", "1", "-q:v", "2", "-y", picture_path });
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
    // FFmpeg's errors go to the log, which keeps them here so the test prints nothing.
    var captured = ICapturedLog.init(arena.allocator());
    const log = captured.ilog();
    var tools = try MediaTools.init();
    const environment = try inherited_environment.inherit(std.testing.allocator);
    defer inherited_environment.restore(std.testing.allocator, environment);
    defer tools.deinit();
    const result = try Ffmpeg.runFfprobe(std.testing.io, log, arena.allocator(), &.{ "-no-such-option", test_video });
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expectEqualStrings("", result.output);
}

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");

const MediaTools = media_tools.MediaTools;

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
    var tools = try MediaTools.init(std.testing.io);
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
    var tools = try MediaTools.init(std.testing.io);
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
    var tools = try MediaTools.init(std.testing.io);
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
    var tools = try MediaTools.init(std.testing.io);
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
    var tools = try MediaTools.init(std.testing.io);
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
    // FFmpeg's errors go to the log, which keeps them here so the test prints nothing.
    var captured = ICapturedLog.init(allocator);
    const previous_log = captured.install();
    defer utils.log.setLog(previous_log);
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const ffmpeg = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
    try std.testing.expect(ffmpeg.exit_code != 0);
    const ffprobe = try tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", missing_path });
    try std.testing.expect(ffprobe.exit_code != 0);
    const probed = try probe(allocator, &tools, test_video);
    try std.testing.expect(probed.width > 0);
}

//
// A log that keeps the errors and the standard error of the tools it is given, and ignores everything else. FFmpeg logs from the
// threads of a run as well as from the thread that started it, so what it keeps is guarded by a mutex.
//
const ICapturedLog = struct {
    // Every error the log was given, each on a line of its own.
    errors: std.ArrayList(u8),

    // Every tool name and standard error the log was given, one after another.
    stderr: std.ArrayList(u8),

    // The allocator the text is kept with.
    allocator: std.mem.Allocator,

    // Lets one thread at a time add to the text.
    mutex: std.Io.Mutex,

    //
    // Keeps an error.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        const self: *ICapturedLog = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.errors.print(self.allocator, "{s}\n", .{message}) catch @panic("out of memory keeping an error");
    }

    //
    // Keeps the standard error of a tool.
    //
    fn tool(ptr: *anyopaque, tool_name: []const u8, data: utils.log.IToolOutput) void {
        const self: *ICapturedLog = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
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
    };

    //
    // Makes the log, which keeps nothing yet.
    //
    fn init(allocator: std.mem.Allocator) ICapturedLog {
        return .{
            .errors = .empty,
            .stderr = .empty,
            .allocator = allocator,
            .mutex = .init,
        };
    }

    //
    // Makes this the program's log, and returns the log that was in place, for the test to put back.
    //
    fn install(self: *ICapturedLog) utils.log.ILog {
        const previous = utils.log.log;
        utils.log.setLog(.{
            .ptr = self,
            .vtable = &vtable,
        });
        return previous;
    }
};

test "a failed ffmpeg run sends FFmpeg's errors, naming the file, to the log's errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const previous_log = captured.install();
    defer utils.log.setLog(previous_log);
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");
    const result = try tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
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
    const previous_log = captured.install();
    defer utils.log.setLog(previous_log);
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
    const failed = try tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", missing_path });
    try std.testing.expect(failed.exit_code != 0);
    const report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, failed.output, .{});
    const report_error = report.object.get("error") orelse return error.TheReportHasNoError;
    try std.testing.expectEqualStrings("No such file or directory", report_error.object.get("string").?.string);
    const worked = try tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", test_video });
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
    const previous_log = captured.install();
    defer utils.log.setLog(previous_log);
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();

    // At the info level ffprobe describes the file it opened ("Input #0, ...") through FFmpeg's log.
    const result = try tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "info", "-hide_banner", "-print_format", "json", "-show_format", test_video });
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
        const previous_log = captured.install();
        defer utils.log.setLog(previous_log);
        var tools = try MediaTools.init(std.testing.io);
        defer tools.deinit();
        const missing_path = try tempFilePath(allocator, tmp_dir, "missing.mp4");
        const picture_path = try tempFilePath(allocator, tmp_dir, "frame.jpg");

        const stderr_path = try tempFilePath(allocator, tmp_dir, "stderr.txt");
        const stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{});
        const saved_stderr = std.c.dup(2);
        try std.testing.expect(saved_stderr >= 0);
        try std.testing.expect(std.c.dup2(stderr_file.handle, 2) == 2);
        // An error from `ffmpeg`, an error from `ffprobe` and the messages of an `ffprobe` that worked.
        const failed_ffmpeg = tools.ffmpeg.runFfmpeg(allocator, &.{ "-i", missing_path, "-vframes", "1", "-y", picture_path });
        const failed_ffprobe = tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "error", "-print_format", "json", "-show_format", missing_path });
        const worked_ffprobe = tools.ffmpeg.runFfprobe(allocator, &.{ "-v", "info", "-print_format", "json", "-show_format", test_video });
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
    var tools = try MediaTools.init(std.testing.io);
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
        var tools = try MediaTools.init(std.testing.io);
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
    // FFmpeg's errors go to the log, which keeps them here so the test prints nothing.
    var captured = ICapturedLog.init(arena.allocator());
    const previous_log = captured.install();
    defer utils.log.setLog(previous_log);
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();
    const result = try tools.ffmpeg.runFfprobe(arena.allocator(), &.{ "-no-such-option", test_video });
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expectEqualStrings("", result.output);
}

// The arguments of an `ffmpeg` run that never ends on its own: the video is read over and over and encoded to the `null` muxer.
// The video is encoded with `mjpeg`, the one encoder the build has, and the audio is dropped, because the `null` muxer's default
// encoders are not built.
const endless_arguments = [_][]const u8{ "-stream_loop", "-1", "-i", test_video, "-an", "-c:v", "mjpeg", "-f", "null", "-" };

// The same run, ended after one second of output, which shows the input starts.
const one_second_arguments = [_][]const u8{ "-stream_loop", "-1", "-i", test_video, "-an", "-c:v", "mjpeg", "-t", "1", "-f", "null", "-" };

//
// An endless `ffmpeg` run on a thread of its own, and what the test waiting on it needs to know.
//
const IEndlessRun = struct {
    // The tools the run goes on.
    tools: *MediaTools,

    // The id of the thread the run goes on, written by that thread before the run starts.
    thread_id: std.atomic.Value(std.Thread.Id),

    // Set by the run's thread when the run has returned.
    finished: std.Io.Event,

    // The exit code the run returned, read once `finished` is set.
    exit_code: i32,

    // Whether runFfmpeg itself failed rather than returning an exit code, read once `finished` is set.
    failed: bool,

    //
    // Runs the endless `ffmpeg` and records how it ended.
    //
    fn run(endless: *IEndlessRun) void {
        endless.thread_id.store(std.Thread.getCurrentId(), .release);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (endless.tools.ffmpeg.runFfmpeg(arena.allocator(), &endless_arguments)) |result| {
            endless.exit_code = result.exit_code;
        }
        else |err| {
            std.debug.print("The endless ffmpeg run failed: {s}\n", .{@errorName(err)});
            endless.failed = true;
        }
        endless.finished.set(std.testing.io);
    }
};

//
// Ends the whole test program with a message. A stop test that runs out of time cannot just fail: the endless run still holds
// the FFmpeg mutex and FFmpeg's process-wide state, so every later test that runs `ffmpeg` in this program would hang or run over it.
//
fn endTestProgram(message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

//
// Waits up to the number of seconds for the event, and says whether it was set.
//
fn waitForEvent(event: *std.Io.Event, seconds: i64) !bool {
    const io = std.testing.io;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromSeconds(seconds),
        .clock = .awake,
    });
    while (true) {
        event.waitTimeout(io, .{
            .deadline = deadline,
        }) catch |err| switch (err) {
            // A wait can wake before its deadline without the event being set, so the deadline decides.
            error.Timeout => {
                if (deadline.durationFromNow(io).raw.nanoseconds <= 0) {
                    return false;
                }
                continue;
            },
            else => return err,
        };
        return true;
    }
}

//
// Waits up to the number of seconds until the `ffmpeg` run is going on the thread, and says whether it was.
//
fn waitForRunningThread(tools: *MediaTools, endless: *IEndlessRun, seconds: i64) !bool {
    const io = std.testing.io;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromSeconds(seconds),
        .clock = .awake,
    });
    while (deadline.durationFromNow(io).raw.nanoseconds > 0) {
        const running = running: {
            tools.ffmpeg.stop_mutex.lockUncancelable(io);
            defer tools.ffmpeg.stop_mutex.unlock(io);
            break :running tools.ffmpeg.running_thread;
        };
        if (running) |running_id| {
            if (running_id == endless.thread_id.load(.acquire)) {
                return true;
            }
        }
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return false;
}

test "an endless ffmpeg run stopped from another thread ends, and a stop for another thread or after the run does nothing to the next run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tools = try MediaTools.init(std.testing.io);
    defer tools.deinit();

    // The input starts: the same run, ended after one second, succeeds. So a non-zero exit code below comes from the stop.
    const one_second = try tools.ffmpeg.runFfmpeg(allocator, &one_second_arguments);
    try std.testing.expectEqual(@as(i32, 0), one_second.exit_code);

    var endless: IEndlessRun = .{
        .tools = &tools,
        .thread_id = .init(0),
        .finished = .unset,
        .exit_code = 0,
        .failed = false,
    };
    const thread = try std.Thread.spawn(.{}, IEndlessRun.run, .{&endless});
    if (!try waitForRunningThread(&tools, &endless, 60)) {
        endTestProgram("The endless ffmpeg run did not start within 60 seconds: running_thread never held its thread.");
    }
    const run_thread_id = endless.thread_id.load(.acquire);

    // A stop for a thread the run is not on leaves it running.
    tools.ffmpeg.stopIfRunningOn(std.Thread.getCurrentId());
    if (try waitForEvent(&endless.finished, 1)) {
        std.debug.print("The endless ffmpeg run ended after a stop for another thread, with exit code {d}.\n", .{endless.exit_code});
        thread.join();
        return error.TestUnexpectedResult;
    }

    tools.ffmpeg.stopIfRunningOn(run_thread_id);
    if (!try waitForEvent(&endless.finished, 60)) {
        endTestProgram("The endless ffmpeg run did not end within 60 seconds of stopIfRunningOn.");
    }
    thread.join();
    try std.testing.expect(!endless.failed);
    try std.testing.expect(endless.exit_code != 0);

    // A stop after the run has ended, for its thread or this one, does not stop the next run.
    tools.ffmpeg.stopIfRunningOn(run_thread_id);
    tools.ffmpeg.stopIfRunningOn(std.Thread.getCurrentId());
    const next = try tools.ffmpeg.runFfmpeg(allocator, &one_second_arguments);
    try std.testing.expectEqual(@as(i32, 0), next.exit_code);
}

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const MessageQueue = @import("ziggy").message_queue.MessageQueue;

const in_process_tools = node_utils.in_process_tools;

//
// FFmpeg, built into the program and run in its process: the `ffmpeg` and `ffprobe` command line programs (see third-party/ffmpeg),
// called with the arguments of a command line, on the thread that runs the command.
//
// Each command is a run of its own (`ffmpeg_run` and `ffprobe_run` in third-party/ffmpeg): the programs' patched source
// (third-party/ffmpeg/fftools-per-run-state.patch) keeps everything the programs kept for the whole process in the state of the run,
// which the run's own threads share and no other run sees, so commands on several threads run at once. The programs install no signal
// handlers of their own.
//
// `ffprobe` writes its report to a file the runner names, and the runner hands the report back.
//
// Everything else the programs say goes through FFmpeg's log (av_log). The log has one callback for the whole process
// (av_log_callback in libavutil/log.c), set once by `Started` before any thread runs a command. The callback is called on whichever
// thread logs, which for a run is the thread that runs the command or one of the threads the run starts, so it finds the run through
// the run itself: each run is given a queue of its own, the callback posts each message of the run to it, and the thread that runs the
// command reads the queue when the run has ended and sends each message to its own log: an error to the log's errors, and anything
// else to the log as the program's standard error (`log.tool`), where execLogged puts the standard error of a program that worked.
// A message logged on a thread of no run (a thread of FFmpeg's libraries' own) goes to that thread's log when it is an error.
//
// A failed `ffprobe` hands back its error in its report, because the runner asks for it with `-show_error`. A failed `ffmpeg` hands
// back no text: its errors are in the log.
//

// The entry points of the two programs (third-party/ffmpeg/ffmpeg-main.c and ffprobe-main.c): each runs the program as a run of its
// own on the calling thread, putting its exit code in `exit_code`, and returns 0, or a negative AVERROR when the run could not be started.
extern fn ffmpeg_run(argc: c_int, argv: [*c][*c]u8, log_context: ?*anyopaque, exit_code: *c_int) c_int;
extern fn ffprobe_run(argc: c_int, argv: [*c][*c]u8, log_context: ?*anyopaque, exit_code: *c_int) c_int;

// The calling thread's run's queue of log messages, or null on a thread of no run; the log level the run set; and the run's own log
// callback, which an option of the program may set (third-party/ffmpeg/ffmpeg-main.c).
extern fn fftools_current_log_context() ?*anyopaque;
extern fn fftools_current_log_level() c_int;
extern fn fftools_forward_log(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) c_int;

// libavutil's version, configuration and license text (libavutil/avutil.h).
extern fn av_version_info() [*:0]const u8;
extern fn avutil_configuration() [*:0]const u8;
extern fn avutil_license() [*:0]const u8;

// FFmpeg's log (libavutil/log.h). A `va_list` is passed as a pointer on every target the program is built for: it is a pointer
// type on Windows, macOS and 32-bit x86, an array that decays to a pointer on x86-64 System V, and on AArch64 Linux and Android a
// structure larger than 16 bytes, which the calling convention passes by its address.
extern fn av_log_set_callback(callback: *const fn (?*anyopaque, c_int, [*c]const u8, ?*anyopaque) callconv(.c) void) void;
extern fn av_log_default_callback(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void;
extern fn av_log_format_line2(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque, line: [*]u8, line_size: c_int, print_prefix: *c_int) c_int;

// The level of FFmpeg's errors (AV_LOG_ERROR in libavutil/log.h). A message at this level or below (fatal, panic) is an error.
const av_log_error = 16;

//
// FFmpeg started for the whole program: its log sent to the log of the run, or of the thread, a message belongs to. The log callback
// is one for the whole process (libavutil/log.h), so the program's main thread starts this before any thread runs a command and stops
// it after the last has ended.
//
pub const Started = struct {
    //
    // Sends FFmpeg's log to the runs' logs in place of the standard error.
    //
    pub fn start() Started {
        av_log_set_callback(logMessage);
        return .{};
    }

    //
    // Puts back FFmpeg's own log callback, which prints to the standard error, once no thread runs a command. FFmpeg has no way to
    // read the callback that was set before start (libavutil/log.h has a setter and no getter), so this puts back the one FFmpeg
    // starts with (libavutil/log.c).
    //
    pub fn stop(self: *Started) void {
        _ = self;
        av_log_set_callback(av_log_default_callback);
    }
};

//
// Running FFmpeg's `ffmpeg` and `ffprobe`, on any thread once FFmpeg has been started (see `Started`), with the Io and allocator of
// the thread that runs them.
//
pub const Ffmpeg = struct {
    //
    // Runs `ffmpeg` with the arguments, which do not include the program's name, and returns its exit code. It is told not to read
    // the keyboard, not to print the banner or progress and to say only errors, because the program is not at a terminal. The
    // output is empty: what `ffmpeg` says goes to the log (see the top of this file).
    //
    pub fn runFfmpeg(io: std.Io, log: ILog, allocator: std.mem.Allocator, arguments: []const []const u8) !in_process_tools.ToolOutput {
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "-version")) {
            return try versionOutput(allocator, "ffmpeg");
        }
        const argv = try buildArgv(allocator, "ffmpeg", &.{ "-nostdin", "-hide_banner", "-nostats", "-loglevel", "error" }, arguments);
        var log_queue = MessageQueue.init();
        defer log_queue.deinit();
        var exit_code: c_int = undefined;
        const started = ffmpeg_run(@intCast(argv.len - 1), argv.ptr, &log_queue, &exit_code);
        logRun(io, allocator, log, "ffmpeg", &log_queue);
        if (started < 0) {
            return utils.errors.throwError("ffmpeg could not be started: FFmpeg error {d}.", .{started});
        }
        return .{
            .exit_code = exit_code,
            .output = "",
        };
    }

    //
    // Runs `ffprobe` with the arguments, which do not include the program's name, and returns its exit code and the report it
    // wrote, which ffprobe is told to write to a file of the runner's naming. ffprobe is told to put the error in the report when
    // it cannot read the file (`-show_error`), so a failed probe hands back its error; a probe that works writes no error.
    //
    pub fn runFfprobe(io: std.Io, log: ILog, allocator: std.mem.Allocator, arguments: []const []const u8) !in_process_tools.ToolOutput {
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "-version")) {
            return try versionOutput(allocator, "ffprobe");
        }
        var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
        const report_name = try uuid_generator.generate(allocator, io);
        const report_path = try std.fs.path.join(allocator, &.{ try node_utils.fs.osTmpDir(allocator), try std.fmt.allocPrint(allocator, "ffprobe-{s}.txt", .{report_name}) });
        defer std.Io.Dir.cwd().deleteFile(io, report_path) catch |err| {
            // The report is not there when ffprobe failed before it wrote anything.
            if (err != error.FileNotFound) {
                log.exception("Could not delete the report ffprobe wrote", err);
            }
        };
        const argv = try buildArgv(allocator, "ffprobe", &.{ "-o", report_path, "-show_error" }, arguments);
        var log_queue = MessageQueue.init();
        defer log_queue.deinit();
        var exit_code: c_int = undefined;
        const started = ffprobe_run(@intCast(argv.len - 1), argv.ptr, &log_queue, &exit_code);
        logRun(io, allocator, log, "ffprobe", &log_queue);
        if (started < 0) {
            return utils.errors.throwError("ffprobe could not be started: FFmpeg error {d}.", .{started});
        }
        const report = std.Io.Dir.cwd().readFileAlloc(io, report_path, allocator, .unlimited) catch |err| {
            if (err == error.FileNotFound) {
                return .{
                    .exit_code = exit_code,
                    .output = "",
                };
            }
            return utils.errors.throwError("The report ffprobe wrote to {s} could not be read: {s}", .{ report_path, @errorName(err) });
        };
        return .{
            .exit_code = exit_code,
            .output = report,
        };
    }

    //
    // Sends the messages a run posted to its log queue to the log given, in the order they were posted, once the run has
    // ended and its threads with it. Each message is numbered with its level.
    //
    fn logRun(io: std.Io, allocator: std.mem.Allocator, log: ILog, program: []const u8, log_queue: *MessageQueue) void {
        while (log_queue.tryTake(io, allocator)) |message| {
            defer allocator.free(message.text);
            writeToLog(log, program, @bitCast(message.from), message.text);
        }
    }
};

//
// The longest line of FFmpeg's log logMessage writes out, and the buffer a message is made in: the line and what logMessage adds.
//
const line_size = 4096;
const message_buffer_size = line_size + " [cut short]".len;

//
// Writes one message of FFmpeg's log to the log given: an error to the log's errors, and anything else to the log as the
// program's standard error.
//
fn writeToLog(log: ILog, program: []const u8, level: c_int, text: []const u8) void {
    if (level <= av_log_error) {
        log.@"error"(text);
        return;
    }
    // The line is made in a buffer on the calling thread's stack, because this runs on whichever thread logs, and a message is never
    // longer than the line logMessage writes it into, with what it adds.
    var buffer: [message_buffer_size + 1]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}\n", .{text}) catch @panic("a message of FFmpeg is longer than its line");
    log.tool(program, .{
        .stdout = null,
        .stderr = line,
    });
}

//
// FFmpeg's log callback, called on whichever thread logs. A message of a run goes to the log callback an option of the run set, or
// else, when it is at or under the level the run asked for (`-loglevel`), to the run's log queue, written as FFmpeg writes it to the
// standard error, with the context it is about in front (`[in#0 @ 0x...] Error opening input: ...`). A message on a thread of no run, which FFmpeg
// calls this with no way to pass a log, goes to the console when it is an error. A message longer than the line it is written into is cut
// short, and says so.
//
fn logMessage(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void {
    const console_log = utils.log.ConsoleLog.init();
    if (fftools_forward_log(avcl, level, fmt, vl) != 0) {
        return;
    }
    const log_queue: ?*MessageQueue = @ptrCast(@alignCast(fftools_current_log_context()));
    // As av_log_default_callback (libavutil/log.c) does, the colour FFmpeg may give a message in the bits above the level is
    // dropped before the level is compared.
    const plain_level = if (level >= 0) level & 0xff else level;
    const wanted_level = if (log_queue != null) fftools_current_log_level() else av_log_error;
    if (plain_level > wanted_level) {
        return;
    }
    var line: [line_size]u8 = undefined;
    var print_prefix: c_int = 1;
    const length = av_log_format_line2(avcl, level, fmt, vl, &line, line.len, &print_prefix);
    if (length < 0) {
        console_log.@"error"("A message of FFmpeg's log could not be written out.");
        return;
    }
    const written: usize = @min(@as(usize, @intCast(length)), line.len - 1);
    const text = std.mem.trimEnd(u8, line[0..written], "\r\n");
    if (text.len == 0) {
        return;
    }
    // The message is made in a buffer on the calling thread's stack, because this runs on whichever thread logs.
    var message_buffer: [message_buffer_size]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, "{s}{s}", .{ text, if (written < length) " [cut short]" else "" }) catch @panic("a message of FFmpeg is longer than its buffer");
    const queue = log_queue orelse {
        writeToLog(console_log, "ffmpeg", plain_level, message);
        return;
    };
    // The thread may be one of the run's own, which has no Io, so it posts with an Io of its own, which allocates nothing for a post,
    // so its allocator is a buffer on the stack.
    var io_buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&io_buffer);
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = fixed.allocator();
    defer threaded.deinit();
    queue.post(threaded.io(), @bitCast(plain_level), message) catch @panic("out of memory logging a message of FFmpeg");
}

//
// What `<program> -version` prints: the line the version is read from (`ffmpeg version 9.0.2`), then FFmpeg's configuration and
// license. The programs would print theirs through FFmpeg's log, which the runner sends to the program's log (see the top of this
// file), so it is put together here.
//
pub fn versionOutput(allocator: std.mem.Allocator, program: []const u8) !in_process_tools.ToolOutput {
    return .{
        .exit_code = 0,
        .output = try std.fmt.allocPrint(allocator, "{s} version {s}\nconfiguration: {s}\nlicense: {s}\n", .{
            program,
            av_version_info(),
            avutil_configuration(),
            avutil_license(),
        }),
    };
}

//
// The argument list of a command: the program's name, the options put in front, then the arguments, as the C strings the program's
// `main` takes, with a null after the last.
//
pub fn buildArgv(allocator: std.mem.Allocator, program: []const u8, leading: []const []const u8, arguments: []const []const u8) ![][*c]u8 {
    const argv = try allocator.alloc([*c]u8, 1 + leading.len + arguments.len + 1);
    var index: usize = 0;
    argv[index] = (try allocator.dupeZ(u8, program)).ptr;
    index += 1;
    for (leading) |argument| {
        argv[index] = (try allocator.dupeZ(u8, argument)).ptr;
        index += 1;
    }
    for (arguments) |argument| {
        argv[index] = (try allocator.dupeZ(u8, argument)).ptr;
        index += 1;
    }
    argv[index] = null;
    return argv;
}


const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

const in_process_tools = node_utils.in_process_tools;

//
// FFmpeg, built into the program and run in its process: the `ffmpeg` and `ffprobe` command line programs, whose `main` functions
// are compiled under the names `ffmpeg_main` and `ffprobe_main` (see third-party/ffmpeg), called with the arguments
// of a command line.
//
// The programs keep their state in variables of the whole program, so one command runs at a time (the mutex), and the counts the
// programs leave behind after a run are put back to zero so the next run starts with none. The programs also take over the
// program's handling of some signals (SIGINT, SIGTERM, SIGXCPU and SIGPIPE) when they start, so the handling that was in place is
// put back after each run.
//
// `ffprobe` writes its report to a file the runner names, and the runner hands the report back.
//
// Everything else the programs say goes through FFmpeg's log (av_log), which is never printed to the process's standard error. The
// log has one callback for the whole program (av_log_callback in libavutil/log.c), and av_vlog calls it with only the context a
// message is about (NULL for most of what fftools says), its level, its format and its arguments: there is no pointer of the
// caller's in it, so the callback cannot find which run, or which Ffmpeg, a message belongs to without a variable of the whole
// program. So the callback sends each message to the log: an error to the log's errors, and anything else to the log as the
// program's standard error (`log.tool`), where execLogged puts the standard error of a program that worked. A run sets the
// callback for its own program before it starts, because fftools' help and version options set one of their own
// (fftools/opt_common.c and fftools/ffprobe.c).
//
// A failed `ffprobe` hands back its error in its report, because the runner asks for it with `-show_error`. A failed `ffmpeg` hands
// back no text: its errors are in the log.
//

// The entry points of the two programs (fftools/ffmpeg.c and fftools/ffprobe.c with `main` renamed).
extern fn ffmpeg_main(argc: c_int, argv: [*c][*c]u8) c_int;
extern fn ffprobe_main(argc: c_int, argv: [*c][*c]u8) c_int;

// libavutil's version, configuration and license text (libavutil/avutil.h).
extern fn av_version_info() [*:0]const u8;
extern fn avutil_configuration() [*:0]const u8;
extern fn avutil_license() [*:0]const u8;

// The counts ffmpeg's cleanup leaves behind (fftools/ffmpeg.h declares them): the arrays they count are freed and set to null, and a
// later run would add to the arrays as if they still held what the counts say.
extern var nb_input_files: c_int;
extern var nb_output_files: c_int;
extern var nb_filtergraphs: c_int;
extern var nb_decoders: c_int;
extern var nb_output_dumped: c_uint;

// FFmpeg's log (libavutil/log.h). A `va_list` is passed as a pointer on every target the program is built for: it is a pointer
// type on Windows, macOS and 32-bit x86, an array that decays to a pointer on x86-64 System V, and on AArch64 Linux and Android a
// structure larger than 16 bytes, which the calling convention passes by its address.
extern fn av_log_set_callback(callback: *const fn (?*anyopaque, c_int, [*c]const u8, ?*anyopaque) callconv(.c) void) void;
extern fn av_log_default_callback(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void;
extern fn av_log_format_line2(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque, line: [*]u8, line_size: c_int, print_prefix: *c_int) c_int;
extern fn av_log_get_level() c_int;

// The level of FFmpeg's errors (AV_LOG_ERROR in libavutil/log.h). A message at this level or below (fatal, panic) is an error.
const av_log_error = 16;

// Asks a running ffmpeg_main to stop as one SIGTERM would, and clears that request after a run (third-party/ffmpeg/ffmpeg-main.c).
extern fn ffmpeg_request_stop() void;
extern fn ffmpeg_reset_stop() void;

//
// Running FFmpeg's `ffmpeg` and `ffprobe`.
//
pub const Ffmpeg = struct {
    // Makes the names of the files ffprobe writes to, and takes the mutex.
    io: std.Io,

    // Lets one command run at a time.
    mutex: std.Io.Mutex,

    // Guards `running_thread` and the stop request, so a stop asked for a run can never land after that run has ended and stop
    // the next one.
    stop_mutex: std.Io.Mutex,

    // The thread an `ffmpeg` run is going on, or null when none is.
    running_thread: ?std.Thread.Id,

    //
    // Makes the runner, and sends FFmpeg's log to the program's log in place of the standard error. Nothing is started until a
    // command runs.
    //
    pub fn init(io: std.Io) Ffmpeg {
        av_log_set_callback(logFfmpegMessage);
        return .{
            .io = io,
            .mutex = .init,
            .stop_mutex = .init,
            .running_thread = null,
        };
    }

    //
    // Puts back FFmpeg's own log callback, which prints to the standard error. FFmpeg has no way to read the callback that was set
    // before init (libavutil/log.h has a setter and no getter), so this puts back the one FFmpeg starts with (libavutil/log.c).
    //
    pub fn deinit(self: *Ffmpeg) void {
        _ = self;
        av_log_set_callback(av_log_default_callback);
    }

    //
    // Asks the `ffmpeg` run going on the thread to stop, as Ctrl+C would, so the run returns a non-zero exit code. Does nothing
    // when no run is going on that thread. `ffprobe` cannot be stopped.
    //
    pub fn stopIfRunningOn(self: *Ffmpeg, thread_id: std.Thread.Id) void {
        self.stop_mutex.lockUncancelable(self.io);
        defer self.stop_mutex.unlock(self.io);
        if (self.running_thread) |running| {
            if (running == thread_id) {
                ffmpeg_request_stop();
            }
        }
    }

    //
    // Runs `ffmpeg` with the arguments, which do not include the program's name, and returns its exit code. It is told not to read
    // the keyboard, not to print the banner or progress and to say only errors, because the program is not at a terminal. The
    // output is empty: what `ffmpeg` says goes to the log (see the top of this file).
    //
    pub fn runFfmpeg(self: *Ffmpeg, allocator: std.mem.Allocator, arguments: []const []const u8) !in_process_tools.ToolOutput {
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "-version")) {
            return try versionOutput(allocator, "ffmpeg");
        }
        const argv = try buildArgv(allocator, "ffmpeg", &.{ "-nostdin", "-hide_banner", "-nostats", "-loglevel", "error" }, arguments);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var saved: SavedSignals = undefined;
        saved.save();
        defer saved.restore();
        {
            self.stop_mutex.lockUncancelable(self.io);
            defer self.stop_mutex.unlock(self.io);
            self.running_thread = std.Thread.getCurrentId();
        }
        av_log_set_callback(logFfmpegMessage);
        const exit_code = ffmpeg_main(@intCast(argv.len - 1), argv.ptr);
        {
            self.stop_mutex.lockUncancelable(self.io);
            defer self.stop_mutex.unlock(self.io);
            self.running_thread = null;
            ffmpeg_reset_stop();
        }
        nb_input_files = 0;
        nb_output_files = 0;
        nb_filtergraphs = 0;
        nb_decoders = 0;
        nb_output_dumped = 0;
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
    pub fn runFfprobe(self: *Ffmpeg, allocator: std.mem.Allocator, arguments: []const []const u8) !in_process_tools.ToolOutput {
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "-version")) {
            return try versionOutput(allocator, "ffprobe");
        }
        var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
        const report_name = try uuid_generator.generate(allocator, self.io);
        const report_path = try std.fs.path.join(allocator, &.{ try node_utils.fs.osTmpDir(allocator), try std.fmt.allocPrint(allocator, "ffprobe-{s}.txt", .{report_name}) });
        defer std.Io.Dir.cwd().deleteFile(self.io, report_path) catch |err| {
            // The report is not there when ffprobe failed before it wrote anything.
            if (err != error.FileNotFound) {
                utils.log.log.exception("Could not delete the report ffprobe wrote", err);
            }
        };
        const argv = try buildArgv(allocator, "ffprobe", &.{ "-o", report_path, "-show_error" }, arguments);
        var exit_code: c_int = undefined;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var saved: SavedSignals = undefined;
            saved.save();
            defer saved.restore();
            av_log_set_callback(logFfprobeMessage);
            exit_code = ffprobe_main(@intCast(argv.len - 1), argv.ptr);
        }
        const report = std.Io.Dir.cwd().readFileAlloc(self.io, report_path, allocator, .unlimited) catch |err| {
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
};

//
// FFmpeg's log callback while `ffmpeg` runs: sends the message to the program's log as `ffmpeg`'s.
//
fn logFfmpegMessage(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void {
    logMessage("ffmpeg", avcl, level, fmt, vl);
}

//
// FFmpeg's log callback while `ffprobe` runs: sends the message to the program's log as `ffprobe`'s.
//
fn logFfprobeMessage(avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) callconv(.c) void {
    logMessage("ffprobe", avcl, level, fmt, vl);
}

//
// Sends one message of FFmpeg's log to the program's log, written as FFmpeg writes it to the standard error, with the context it
// is about in front (`[in#0 @ 0x...] Error opening input: ...`). A message above the level the run asked for (`-loglevel`) is
// left out, as FFmpeg's own callback leaves it out. An error goes to the log's errors, and anything else to the log as the
// program's standard error. A message longer than the line it is written into is cut short, and says so.
//
fn logMessage(program: []const u8, avcl: ?*anyopaque, level: c_int, fmt: [*c]const u8, vl: ?*anyopaque) void {
    // As av_log_default_callback (libavutil/log.c) does, the colour FFmpeg may give a message in the bits above the level is
    // dropped before the level is compared.
    const plain_level = if (level >= 0) level & 0xff else level;
    if (plain_level > av_log_get_level()) {
        return;
    }
    var line: [4096]u8 = undefined;
    var print_prefix: c_int = 1;
    const length = av_log_format_line2(avcl, level, fmt, vl, &line, line.len, &print_prefix);
    if (length < 0) {
        utils.log.log.@"error"("A message of FFmpeg's log could not be written out.");
        return;
    }
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(std.heap.smp_allocator);
    const written: usize = @min(@as(usize, @intCast(length)), line.len - 1);
    const text = std.mem.trimEnd(u8, line[0..written], "\r\n");
    if (text.len == 0) {
        return;
    }
    message.appendSlice(std.heap.smp_allocator, text) catch @panic("out of memory logging a message of FFmpeg");
    if (written < length) {
        message.appendSlice(std.heap.smp_allocator, " [cut short]") catch @panic("out of memory logging a message of FFmpeg");
    }
    if (plain_level <= av_log_error) {
        utils.log.log.@"error"(message.items);
    }
    else {
        message.append(std.heap.smp_allocator, '\n') catch @panic("out of memory logging a message of FFmpeg");
        utils.log.log.tool(program, .{
            .stdout = null,
            .stderr = message.items,
        });
    }
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

//
// The handling of the signals the programs take over, saved before a run and put back after it. Windows has none to save.
//
const SavedSignals = struct {
    // The handling each of the signals ffmpeg takes over had.
    actions: if (builtin.os.tag == .windows) void else [4]std.posix.Sigaction,

    //
    // Saves the handling the signals have now.
    //
    fn save(self: *SavedSignals) void {
        if (builtin.os.tag == .windows) {
            return;
        }
        else {
            std.posix.sigaction(std.posix.SIG.INT, null, &self.actions[0]);
            std.posix.sigaction(std.posix.SIG.TERM, null, &self.actions[1]);
            std.posix.sigaction(std.posix.SIG.PIPE, null, &self.actions[2]);
            std.posix.sigaction(std.posix.SIG.XCPU, null, &self.actions[3]);
        }
    }

    //
    // Puts back the handling that was saved.
    //
    fn restore(self: *SavedSignals) void {
        if (builtin.os.tag == .windows) {
            return;
        }
        else {
            std.posix.sigaction(std.posix.SIG.INT, &self.actions[0], null);
            std.posix.sigaction(std.posix.SIG.TERM, &self.actions[1], null);
            std.posix.sigaction(std.posix.SIG.PIPE, &self.actions[2], null);
            std.posix.sigaction(std.posix.SIG.XCPU, &self.actions[3], null);
        }
    }
};

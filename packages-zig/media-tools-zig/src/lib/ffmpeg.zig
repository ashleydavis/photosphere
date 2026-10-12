const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

const in_process_tools = node_utils.in_process_tools;

//
// FFmpeg, built into the program and run in its process: the `ffmpeg` and `ffprobe` command line programs, whose `main` functions
// are compiled under the names `ffmpeg_main` and `ffprobe_main` (see packages-zig/media-tools-zig/ffmpeg), called with the arguments
// of a command line.
//
// The programs keep their state in variables of the whole program, so one command runs at a time (the mutex), and the counts the
// programs leave behind after a run are put back to zero so the next run starts with none. The programs also take over the
// program's handling of some signals (SIGINT, SIGTERM, SIGXCPU and SIGPIPE) when they start, so the handling that was in place is
// put back after each run.
//
// What a command prints is not collected: `ffprobe` writes its report to a file the runner names, and `ffmpeg` writes its errors
// to the standard error. They are the library's log, which is one callback for the whole program and has no way to tell which call
// a message belongs to, so it would take a variable for the whole program to collect it.
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

//
// Running FFmpeg's `ffmpeg` and `ffprobe`.
//
pub const Ffmpeg = struct {
    // Makes the names of the files ffprobe writes to, and takes the mutex.
    io: std.Io,

    // Lets one command run at a time.
    mutex: std.Io.Mutex,

    //
    // Makes the runner. Nothing is started until a command runs.
    //
    pub fn init(io: std.Io) Ffmpeg {
        return .{
            .io = io,
            .mutex = .init,
        };
    }

    //
    // Runs `ffmpeg` with the arguments, which do not include the program's name, and returns its exit code. It is told not to read
    // the keyboard, not to print the banner or progress and to say only errors, because the program is not at a terminal. It
    // prints nothing that is returned: the output is empty.
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
        const exit_code = ffmpeg_main(@intCast(argv.len - 1), argv.ptr);
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
    // wrote, which ffprobe is told to write to a file of the runner's naming.
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
        const argv = try buildArgv(allocator, "ffprobe", &.{ "-o", report_path }, arguments);
        var exit_code: c_int = undefined;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var saved: SavedSignals = undefined;
            saved.save();
            defer saved.restore();
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
// What `<program> -version` prints: the line the version is read from (`ffmpeg version 9.0.2`), then FFmpeg's configuration and
// license. The programs print theirs through the library's log, which is not collected (see the top of this file).
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
    actions: if (builtin.os.tag == .windows) void else [3]std.posix.Sigaction,

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
        }
    }
};

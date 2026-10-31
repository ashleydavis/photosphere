const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
// The C interface of ImageMagick, for a program that needs more of it than the runner.
pub const c = @import("magick");

const in_process_tools = node_utils.in_process_tools;
const ThreadAllocator = @import("ziggy").utils.thread_allocator.ThreadAllocator;

//
// ImageMagick, built into the program and run in its process: the same thing the `magick` program does with its command line, which
// is to hand the arguments to the command they name (MagickImageCommand, or IdentifyImageCommand for `identify`), without starting a
// program.
//
// The text a command prints is collected without touching the process's standard output, which other threads share and which a
// redirect would take from them:
//
//   * `identify` hands what it prints back as text.
//   * `-version` writes the version to a file it is given.
//   * A command that ends in `info:` or `histogram:info:` writes what it prints to the file named after the colon, so the file name
//     of a temporary file is put there.
//
// Everything else a command prints goes to the process's standard output as it would from `magick`.
//
// ImageMagick's warnings and errors are never printed to the process's standard error. They are handed back the way the standard
// error of a `magick` program was:
//
//   * A command that fails hands back its messages as its output, which exec puts in the error it fails with.
//   * The warnings of a command that works go to the log as the tool's standard error (`log.tool`), where execLogged puts the
//     standard error of a program that worked.
//

//
// ImageMagick started for the whole program. ImageMagick keeps one set of state for the whole program, which MagickWandGenesis starts
// and MagickWandTerminus ends for every thread at once, so the program's main thread holds one of these, started before any thread
// runs a command and stopped after the last has ended. The program's code keeps no variable for it.
//
pub const Started = struct {
    // ImageMagick's warning handler before start set its own, put back by stop.
    previous_warning_handler: c.WarningHandler,

    // ImageMagick's error handler before start set its own, put back by stop.
    previous_error_handler: c.ErrorHandler,

    //
    // Starts ImageMagick.
    //
    // A command leaves its messages in the exception it is given, and runMagick hands them back. The `magick` command also hands the
    // warnings it meets to ImageMagick's warning handler as it goes, and clears them (CLICatchException in MagickWand/wandcli.c), and a
    // few parts of the library do the same with errors they carry on from. Those handlers are set for the whole of ImageMagick and
    // are given no pointer of the caller's, so they cannot tell which call a message belongs to. In place of the handlers that print to
    // the standard error, this sets ones that send a warning to the log as the tool's standard error and an error to the log's errors:
    // the log of the thread that runs the command, since each thread has a log of its own.
    //
    // The library is built with zero configuration, so it reads no policy.xml and applies no security policy of its own. This sets
    // one, and fails with ImageMagick's error when it cannot be set. The policy denies:
    //
    //   * The coders that reach outside the file being read or run a script: the URL coders (HTTP, HTTPS, FTP), MSL, MVG, MSVG, TEXT
    //     and TXT (which read a text description as an image), EPHEMERAL (which deletes the file it reads), and the display coders
    //     SHOW, WIN and X. Every other coder stays allowed, because the import reads whatever image type the user has.
    //   * Every delegate, since none is meant to run a program.
    //   * Indirect reads, `@file`, which read a list of other paths from a file.
    //
    pub fn start() !Started {
        c.MagickWandGenesis();
        const exception = c.AcquireExceptionInfo();
        defer _ = c.DestroyExceptionInfo(exception);
        if (c.SetMagickSecurityPolicy(
            \\<policymap>
            \\  <policy domain="coder" rights="none" pattern="{URL,HTTP,HTTPS,FTP,MSL,MVG,MSVG,TEXT,TXT,EPHEMERAL,SHOW,WIN,X}"/>
            \\  <policy domain="delegate" rights="none" pattern="*"/>
            \\  <policy domain="path" rights="none" pattern="@*"/>
            \\</policymap>
        , exception) != c.MagickTrue) {
            const reason: []const u8 = if (exception.*.reason != null) std.mem.span(exception.*.reason) else "no reason given";
            const description: []const u8 = if (exception.*.description != null) std.mem.span(exception.*.description) else "";
            c.MagickWandTerminus();
            return utils.errors.throwError("The ImageMagick security policy could not be set: {s} {s}", .{ reason, description });
        }
        return .{
            .previous_warning_handler = c.SetWarningHandler(logWarning),
            .previous_error_handler = c.SetErrorHandler(logError),
        };
    }

    //
    // Stops ImageMagick and frees what it holds, once no thread runs a command.
    //
    pub fn stop(self: *Started) void {
        _ = c.SetWarningHandler(self.previous_warning_handler);
        _ = c.SetErrorHandler(self.previous_error_handler);
        c.MagickWandTerminus();
    }
};

//
// Running ImageMagick's commands, on any thread once ImageMagick has been started (see `Started`). ImageMagick runs commands from several
// threads at once, each with the Io and allocator of the thread that runs it.
//
pub const ImageMagick = struct {
    //
    // Runs `magick` with the arguments and returns the exit code (0 when the command worked, 1 when it failed) and what it printed.
    // A command that fails hands back ImageMagick's messages instead of what it printed.
    //
    pub fn runMagick(io: std.Io, log: ILog, allocator: std.mem.Allocator, arguments: []const []const u8) !in_process_tools.ToolOutput {
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "-version")) {
            return try readVersion(io, allocator);
        }

        // The unified `magick` command takes its first argument as an input file, so it cannot run `identify`; `identify` is its own
        // command.
        const is_identify = arguments.len > 0 and std.mem.eql(u8, arguments[0], "identify");
        var command_arguments: std.ArrayList([]const u8) = .empty;
        if (!is_identify) {
            try command_arguments.append(allocator, "magick");
        }
        try command_arguments.appendSlice(allocator, arguments);

        // The text of a command that ends in `info:` goes to a file.
        var text_path_buffer: [c.MagickPathExtent]u8 = undefined;
        var text_path: ?[:0]const u8 = null;
        const last_argument = command_arguments.items[command_arguments.items.len - 1];
        if (std.mem.endsWith(u8, last_argument, "info:")) {
            text_path = try acquireTemporaryPath(&text_path_buffer);
            command_arguments.items[command_arguments.items.len - 1] = try std.fmt.allocPrint(allocator, "{s}{s}", .{ last_argument, text_path.? });
        }
        defer if (text_path) |path| {
            _ = c.RelinquishUniqueFileResource(path.ptr);
        };

        const argv = try allocator.alloc([*c]u8, command_arguments.items.len + 1);
        for (command_arguments.items, 0..) |argument, index| {
            argv[index] = (try allocator.dupeZ(u8, argument)).ptr;
        }
        argv[command_arguments.items.len] = null;

        const image_info = c.AcquireImageInfo();
        defer _ = c.DestroyImageInfo(image_info);
        const exception = c.AcquireExceptionInfo();
        defer _ = c.DestroyExceptionInfo(exception);
        // The command is called as MagickCommandGenesis (MagickWand/magick-cli.c), which `magick` runs, calls it for a single run,
        // without MagickCommandGenesis itself: it hands the messages the command left in the exception to ImageMagick's handlers
        // (CatchException), which clears them, and so they could not be handed back. Its other work is left out too: the options it
        // reads (-bench, -concurrent, -debug, -distribute-cache, -duration, -regard-warnings) are not ones the program passes, and
        // setting the process's locale and ImageMagick's client name changes state the whole program shares.
        var metadata: [*c]u8 = null;
        defer if (metadata != null) {
            _ = c.DestroyString(metadata);
        };
        // ImageMagick's handlers are called with no way to pass a log, so for the length of the command they print to this thread's
        // console, and its lines go to the log given (see RunConsole). The forward that was set is put back after.
        var run_console: RunConsole = .{
            .log = log,
        };
        const previous_forward = utils.console.currentForward();
        utils.console.setForward(.{
            .context = &run_console,
            .function = RunConsole.forwardLine,
        });
        defer utils.console.setForward(previous_forward);
        const command: c.MagickCommand = if (is_identify) &c.IdentifyImageCommand else &c.MagickImageCommand;
        var succeeded = command.?(image_info, @intCast(command_arguments.items.len), argv.ptr, &metadata, exception) == c.MagickTrue;
        // As MagickCommandGenesis does without -regard-warnings: an error worse than ErrorException fails the command.
        if (exception.*.severity > c.ErrorException) {
            succeeded = false;
        }
        const client = if (is_identify) "identify" else "magick";
        const messages = try exceptionMessages(allocator, client, exception);
        if (!succeeded) {
            return .{
                .exit_code = 1,
                .output = messages,
            };
        }
        if (messages.len > 0) {
            log.tool("magick", .{
                .stdout = null,
                .stderr = messages,
            });
        }

        // Only `identify` hands its text back. The text any other command hands back is a summary of the image ("columns,rows,format")
        // that `magick` does not print.
        var output: std.ArrayList(u8) = .empty;
        if (is_identify and metadata != null) {
            try output.appendSlice(allocator, std.mem.span(metadata));
        }
        if (text_path) |path| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
                return utils.errors.throwError("The text the magick command wrote to {s} could not be read: {s}", .{ path, @errorName(err) });
            };
            try output.appendSlice(allocator, text);
        }
        return .{
            .exit_code = 0,
            .output = output.items,
        };
    }

    //
    // What `magick -version` prints, which ImageMagick writes to a file it is given.
    //
    fn readVersion(io: std.Io, allocator: std.mem.Allocator) !in_process_tools.ToolOutput {
        var path_buffer: [c.MagickPathExtent]u8 = undefined;
        const path = try acquireTemporaryPath(&path_buffer);
        defer _ = c.RelinquishUniqueFileResource(path.ptr);
        const file = c.fopen(path.ptr, "wb") orelse {
            return utils.errors.throwError("The file {s} for the version of ImageMagick could not be opened.", .{path});
        };
        c.ListMagickVersion(file);
        if (c.fclose(file) != 0) {
            return utils.errors.throwError("The file {s} for the version of ImageMagick could not be closed.", .{path});
        }
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
            return utils.errors.throwError("The version of ImageMagick could not be read from {s}: {s}", .{ path, @errorName(err) });
        };
        return .{
            .exit_code = 0,
            .output = text,
        };
    }
};

//
// Makes an empty file in the directory ImageMagick keeps its temporary files in, and returns its path in the buffer.
//
fn acquireTemporaryPath(buffer: *[c.MagickPathExtent]u8) ![:0]const u8 {
    buffer[0] = 0;
    if (c.AcquireUniqueFilename(buffer) != c.MagickTrue) {
        return utils.errors.throwError("ImageMagick could not make a temporary file.", .{});
    }
    const length = std.mem.indexOfScalar(u8, buffer, 0).?;
    return buffer[0..length :0];
}

//
// ImageMagick's messages in the exception, each on a line of its own written as ImageMagick's own handlers print one (MagickCore/
// exception.c): the client's name, the reason and, in brackets, the description. Empty when there are none.
//
fn exceptionMessages(allocator: std.mem.Allocator, client: []const u8, exception: [*c]c.ExceptionInfo) ![]const u8 {
    var messages: std.ArrayList(u8) = .empty;
    const list: ?*c.LinkedListInfo = @ptrCast(exception.*.exceptions);
    if (list == null) {
        return "";
    }
    c.ResetLinkedListIterator(list);
    while (c.GetNextValueInLinkedList(list)) |value| {
        const entry: *const c.ExceptionInfo = @ptrCast(@alignCast(value));
        try appendMessage(allocator, &messages, client, entry.reason, entry.description);
    }
    return messages.items;
}

//
// Adds one message, as ImageMagick's own handlers print it, to the messages. A message with no reason is left out, as those handlers
// leave it out.
//
fn appendMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(u8), client: []const u8, reason: [*c]const u8, description: [*c]const u8) !void {
    if (reason == null) {
        return;
    }
    try messages.print(allocator, "{s}: {s}", .{ client, std.mem.span(reason) });
    if (description != null) {
        try messages.print(allocator, " ({s})", .{std.mem.span(description)});
    }
    try messages.appendSlice(allocator, ".\n");
}

//
// Where the console lines of a thread running a command go while it runs: ImageMagick's handlers print a warning to stdout and an error
// to stderr (see logWarning and logError), and this sends a warning to the log given as the standard error of `magick` and an error
// to its errors.
//
const RunConsole = struct {
    // The log of the run.
    log: utils.log.ILog,

    //
    // Sends one console line of the run to the log.
    //
    fn forwardLine(context: ?*anyopaque, stream: utils.console.Stream, line: []const u8) void {
        const self: *const RunConsole = @ptrCast(@alignCast(context.?));
        switch (stream) {
            .stdout => self.log.tool("magick", .{
                .stdout = null,
                .stderr = line,
            }),
            .stderr => self.log.@"error"(line),
        }
    }
};

//
// ImageMagick's warning handler while the program runs it: prints the warning to the calling thread's stdout, which a run sends to its
// log as the standard error of `magick` (see RunConsole). ImageMagick calls it with no way to pass a log.
//
fn logWarning(severity: c.ExceptionType, reason: [*c]const u8, description: [*c]const u8) callconv(.c) void {
    _ = severity;
    // This runs on whichever thread ImageMagick reports from, so the message is made with an allocator made for the call.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    appendMessage(allocator, &message, "magick", reason, description) catch @panic("out of memory logging a warning of ImageMagick");
    if (message.items.len > 0) {
        utils.console.log(message.items);
    }
}

//
// ImageMagick's error handler while the program runs it: prints the error to the calling thread's stderr, which a run sends to its
// log's errors (see RunConsole). ImageMagick calls it with no way to pass a log, and hands an error to it only where it reports the
// error and carries on.
//
fn logError(severity: c.ExceptionType, reason: [*c]const u8, description: [*c]const u8) callconv(.c) void {
    _ = severity;
    // This runs on whichever thread ImageMagick reports from, so the message is made with an allocator made for the call.
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    appendMessage(allocator, &message, "magick", reason, description) catch @panic("out of memory logging an error of ImageMagick");
    if (message.items.len > 0) {
        utils.console.@"error"(message.items[0 .. message.items.len - 1]);
    }
}

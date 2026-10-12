const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
// The C interface of ImageMagick, for a program that needs more of it than the runner.
pub const c = @import("magick");

const in_process_tools = node_utils.in_process_tools;

//
// ImageMagick, built into the program and run in its process: the same thing the `magick` program does with its command line, which
// is to hand the arguments to ImageMagick's command dispatcher (MagickCommandGenesis), without starting a program.
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

//
// A running ImageMagick. ImageMagick keeps one set of state for the whole program, so a program holds one of these at a time, and may
// run commands on it from several threads at once.
//
pub const ImageMagick = struct {
    // Reads the files the commands write their text to.
    io: std.Io,

    //
    // Starts ImageMagick. ImageMagick prints its own error and warning messages to the standard error, as `magick` does: handing them
    // to the caller would take a handler with no way to tell which call a message belongs to, which is a variable for the whole program.
    //
    pub fn init(io: std.Io) ImageMagick {
        c.MagickWandGenesis();
        return .{
            .io = io,
        };
    }

    //
    // Stops ImageMagick and frees what it holds.
    //
    pub fn deinit(self: *ImageMagick) void {
        _ = self;
        c.MagickWandTerminus();
    }

    //
    // Runs `magick` with the arguments and returns the exit code (0 when the command worked, 1 when it failed) and what it printed.
    //
    pub fn runMagick(self: *ImageMagick, allocator: std.mem.Allocator, arguments: []const []const u8) !in_process_tools.ToolOutput {
        if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "-version")) {
            return try self.readVersion(allocator);
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
        // Only `identify` hands its text back. The text any other command hands back is a summary of the image ("columns,rows,format")
        // that `magick` does not print, so it is not asked for.
        var metadata: [*c]u8 = null;
        const succeeded = c.MagickCommandGenesis(
            image_info,
            if (is_identify) c.IdentifyImageCommand else c.MagickImageCommand,
            @intCast(command_arguments.items.len),
            argv.ptr,
            if (is_identify) &metadata else null,
            exception,
        );
        var output: std.ArrayList(u8) = .empty;
        if (metadata != null) {
            try output.appendSlice(allocator, std.mem.span(metadata));
            _ = c.DestroyString(metadata);
        }
        if (text_path) |path| {
            const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .unlimited) catch |err| {
                return utils.errors.throwError("The text the magick command wrote to {s} could not be read: {s}", .{ path, @errorName(err) });
            };
            try output.appendSlice(allocator, text);
        }
        if (succeeded == c.MagickTrue) {
            return .{
                .exit_code = 0,
                .output = output.items,
            };
        }
        return .{
            .exit_code = 1,
            .output = output.items,
        };
    }

    //
    // What `magick -version` prints, which ImageMagick writes to a file it is given.
    //
    fn readVersion(self: *ImageMagick, allocator: std.mem.Allocator) !in_process_tools.ToolOutput {
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
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .unlimited) catch |err| {
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

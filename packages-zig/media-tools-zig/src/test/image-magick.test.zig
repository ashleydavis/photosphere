const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");

const ImageMagick = media_tools.ImageMagick;

// What a command hands back: its exit code and what it printed.
const ToolOutput = @import("node-utils-zig").in_process_tools.ToolOutput;

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

//
// Makes a JPEG of one colour and of exactly the size given with ImageMagick, and returns its path. The security policy lets the
// program write only JPEG and read no made-up image such as `xc:`, so the picture is the PNG fixture painted over in the colour.
//
fn makeImage(log: ILog, allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8, size: []const u8, color: []const u8) ![]const u8 {
    const path = try tempFilePath(allocator, tmp_dir, name);
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.png", "-strip", "-resize", try std.fmt.allocPrint(allocator, "{s}!", .{size}), "-fill", color, "-colorize", "100", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{path}) });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    return path;
}

test "magick -version names the version, the quantum depth and the delegates the library was built with" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const result = try ImageMagick.runMagick(std.testing.io, log, arena.allocator(), &.{"-version"});
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Version: ImageMagick 7.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Q16-HDRI") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "jpeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "zlib") != null);
}

test "identify -format hands back the size of a JPEG written by the JPEG delegate" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(log, allocator, tmp_dir, "red.jpg", "20x10", "red");
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "identify", "-format", "%w %h", path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("20 10", result.output);
}

test "a command that ends in info: hands back what it printed, for a PNG read by the PNG delegate" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.png", "-format", "%w %h", "info:" });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("100 90", result.output);
}

test "resizing writes a file of the new size" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(log, allocator, tmp_dir, "big.jpg", "200x100", "blue");
    const resized_path = try tempFilePath(allocator, tmp_dir, "small.jpg");
    const resize_result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ path, "-resize", "40x40", "-quality", "80", "-strip", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{resized_path}) });
    try std.testing.expectEqual(@as(i32, 0), resize_result.exit_code);
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ resized_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings("40 20", result.output);
}

test "the dominant colour command averages the image to one pixel" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    // An 8x8 PNG of pure red. A JPEG would not do: its compression reads the red back as 254.
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/red.png", "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" });
    try std.testing.expectEqualStrings("255,0,0", result.output);
}

test "the security policy refuses to write any type but JPEG and the text of info:, naming the coder it refused" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const refused = [_][]const u8{ "png", "webp", "gif", "bmp", "psd", "svg", "ps", "pdf", "mvg", "txt", "miff", "histogram" };
    for (refused) |coder| {
        const path = try tempFilePath(allocator, tmp_dir, try std.fmt.allocPrint(allocator, "written.{s}", .{coder}));
        errdefer std.debug.print("The write of {s} was not refused\n", .{coder});
        const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.png", try std.fmt.allocPrint(allocator, "{s}:{s}", .{ coder, path }) });
        try expectRefusedByPolicy(result, try std.ascii.allocUpperString(allocator, coder));
        // Nothing is written. For a coder that needs a seekable file (PSD) ImageMagick opens the output to check that before it asks
        // the policy, so an empty file is left there; for the others there is no file at all.
        if (std.Io.Dir.cwd().statFile(std.testing.io, path, .{})) |stat| {
            try std.testing.expectEqual(@as(u64, 0), stat.size);
        }
        else |err| {
            try std.testing.expectEqual(error.FileNotFound, err);
        }
    }
}

test "a file that is not there makes the command fail, with ImageMagick's error naming the file" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ path, "-format", "%w", "info:" });
    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, result.output, "magick: "));
    try std.testing.expect(std.mem.indexOf(u8, result.output, path) != null);
}

test "identify of a file that is not an image fails with ImageMagick's error" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try writeTextFile(allocator, tmp_dir, "broken.png", "not an image");
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "identify", "-format", "%w %h", path });
    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, result.output, "identify: ImproperImageHeader"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, path) != null);
}

//
// A log that keeps what it is given as the standard error of a tool, and ignores everything else.
//
const IToolLog = struct {
    // Every tool name and standard error the log was given, one after another.
    stderr: std.ArrayList(u8),

    // The allocator the text is kept with.
    allocator: std.mem.Allocator,

    //
    // Keeps the standard error of a tool.
    //
    fn tool(ptr: *anyopaque, tool_name: []const u8, data: utils.log.IToolOutput) void {
        const self: *IToolLog = @ptrCast(@alignCast(ptr));
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
    // Ignores an error.
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
        .@"error" = ignoreMessage,
        .exception = ignoreException,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = tool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };
};

test "the warnings of a command that works go to the log as the tool's standard error, and not into what it hands back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tool_log: IToolLog = .{
        .stderr = .empty,
        .allocator = allocator,
    };
    const log: utils.log.ILog = .{
        .ptr = &tool_log,
        .vtable = &IToolLog.vtable,
    };
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();

    // The JPEG fixture holds an XMP profile, which ImageMagick warns it cannot check without the XML library it is built without.
    // `identify` leaves the warning with the command, and `magick` hands it to ImageMagick's warning handler as it goes.
    const identified = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "identify", "-format", "%m", "../test/test.jpg" });
    try std.testing.expectEqual(@as(i32, 0), identified.exit_code);
    try std.testing.expectEqualStrings("JPEG", identified.output);
    try std.testing.expect(std.mem.indexOf(u8, tool_log.stderr.items, "magick: identify: DelegateLibrarySupportNotBuiltIn") != null);
    tool_log.stderr.clearRetainingCapacity();
    const resized_path = try tempFilePath(allocator, tmp_dir, "resized.jpg");
    const converted = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.jpg", "-resize", "16x16", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{resized_path}) });
    try std.testing.expectEqual(@as(i32, 0), converted.exit_code);
    try std.testing.expectEqualStrings("", converted.output);
    try std.testing.expect(std.mem.indexOf(u8, tool_log.stderr.items, "magick: magick: DelegateLibrarySupportNotBuiltIn") != null);
}

//
// The tests that watch the standard error, which they redirect to a file by its descriptor, so they run where the program has POSIX
// descriptors (not on Windows).
//
const StandardErrorTests = struct {
    test "ImageMagick prints none of its warnings or errors to the standard error" {
        const log = utils.mute_log.MuteLog.init();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var started = try media_tools.image_magick.Started.start();
        defer started.stop();
        const missing_path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
        const broken_path = try writeTextFile(allocator, tmp_dir, "broken.png", "not an image");
        const resized_path = try tempFilePath(allocator, tmp_dir, "resized.jpg");

        const stderr_path = try tempFilePath(allocator, tmp_dir, "stderr.txt");
        const stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{});
        const saved_stderr = std.c.dup(2);
        try std.testing.expect(saved_stderr >= 0);
        try std.testing.expect(std.c.dup2(stderr_file.handle, 2) == 2);
        // A warning from `identify`, a warning from `magick`, an error from `magick` and an error from `identify`.
        const identified = ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "identify", "-format", "%m", "../test/test.jpg" });
        const converted = ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.jpg", "-resize", "16x16", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{resized_path}) });
        const missing = ImageMagick.runMagick(std.testing.io, log, allocator, &.{ missing_path, "-format", "%w", "info:" });
        const broken = ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "identify", "-format", "%w %h", broken_path });
        const restored = std.c.dup2(saved_stderr, 2);
        _ = std.c.close(saved_stderr);
        stderr_file.close(std.testing.io);
        try std.testing.expect(restored == 2);

        try std.testing.expectEqual(@as(i32, 0), (try identified).exit_code);
        try std.testing.expectEqual(@as(i32, 0), (try converted).exit_code);
        try std.testing.expectEqual(@as(i32, 1), (try missing).exit_code);
        try std.testing.expectEqual(@as(i32, 1), (try broken).exit_code);
        const printed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .unlimited);
        try std.testing.expectEqualStrings("", printed);
    }
};

comptime {
    if (builtin.os.tag != .windows) {
        _ = StandardErrorTests;
    }
}

//
// What one thread of the concurrency test reads and runs.
//
const IWorker = struct {
    // The image to read the size of.
    path: []const u8,

    // How many times the size was read correctly.
    correct: usize,

    //
    // Reads the size of the image over and over, as tasks that hash files do at the same time.
    //
    fn run(worker: *IWorker) void {
        // The thread's own log, which writes to the console.
        const log = utils.mute_log.MuteLog.init();
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = std.heap.page_allocator;
        defer threaded.deinit();
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const result = ImageMagick.runMagick(threaded.io(), log, arena.allocator(), &.{ worker.path, "-format", "%w %h", "info:" }) catch {
                return;
            };
            if (result.exit_code == 0 and std.mem.eql(u8, result.output, "30 20")) {
                worker.correct += 1;
            }
        }
    }
};

test "commands run on several threads at once all give their own answer" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(log, allocator, tmp_dir, "shared.jpg", "30x20", "red");
    var workers: [8]IWorker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{
            .path = path,
            .correct = 0,
        };
        thread.* = try std.Thread.spawn(.{}, IWorker.run, .{worker});
    }
    for (threads) |thread| {
        thread.join();
    }
    for (workers) |worker| {
        try std.testing.expectEqual(@as(usize, 20), worker.correct);
    }
}

test "a WebP picture is read through the WebP delegate, and made into a JPEG" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const read = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.webp", "-format", "%w %h", "info:" });
    try std.testing.expectEqual(@as(i32, 0), read.exit_code);
    var sizes = std.mem.splitScalar(u8, read.output, ' ');
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);

    const format = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.webp", "-format", "%m", "info:" });
    try std.testing.expectEqualStrings("WEBP", format.output);

    // The app turns a picture into a JPEG of another size. It writes no WebP, which the security policy refuses.
    const jpeg_path = try tempFilePath(allocator, tmp_dir, "from-webp.jpg");
    const resized = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.webp", "-resize", "8x8", "-quality", "80", "-strip", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{jpeg_path}) });
    try std.testing.expectEqual(@as(i32, 0), resized.exit_code);
    const again = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ jpeg_path, "-format", "%m", "info:" });
    try std.testing.expectEqualStrings("JPEG", again.output);
}

//
// Writes a file of text into a test's temporary directory and returns its path.
//
fn writeTextFile(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8, text: []const u8) ![]const u8 {
    const path = try tempFilePath(allocator, tmp_dir, name);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = text,
    });
    return path;
}

//
// Expects a command to have failed because the security policy refused it, with ImageMagick's NotAuthorized error naming what it
// refused: a coder, in capitals as ImageMagick names them.
//
fn expectRefusedByPolicy(result: ToolOutput, refused: []const u8) !void {
    var message_buffer: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(&message_buffer, "NotAuthorized `{s}'", .{refused});
    if (result.exit_code != 1 or std.mem.indexOf(u8, result.output, message) == null) {
        std.debug.print("Expected the security policy to refuse {s}: exit code {d}, output \"{s}\"\n", .{ refused, result.exit_code, result.output });
    }
    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, message) != null);
}

//
// Asks ImageMagick for the size of the input and expects the command to fail, because the security policy refuses the read of what
// is named.
//
fn expectReadRefused(log: ILog, allocator: std.mem.Allocator, input: []const u8, refused: []const u8) !void {
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ input, "-format", "%w %h", "info:" });
    try expectRefusedByPolicy(result, refused);
}

//
// Asks ImageMagick for the size of the input and expects it to be read, with a size above zero.
//
fn expectReadAllowed(log: ILog, allocator: std.mem.Allocator, input: []const u8) !void {
    const result = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ input, "-format", "%w %h", "info:" });
    if (result.exit_code != 0) {
        std.debug.print("The read of {s} failed with exit code {d}\n", .{ input, result.exit_code });
    }
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    var sizes = std.mem.splitScalar(u8, result.output, ' ');
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
}

test "with the security policy set, a JPEG still converts and identifies" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const resized_path = try tempFilePath(allocator, tmp_dir, "resized.jpg");
    const converted = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "../test/test.jpg", "-resize", "16x16", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{resized_path}) });
    try std.testing.expectEqual(@as(i32, 0), converted.exit_code);
    const identified = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ "identify", "-format", "%m", "../test/test.jpg" });
    try std.testing.expectEqual(@as(i32, 0), identified.exit_code);
    try std.testing.expectEqualStrings("JPEG", identified.output);
    const again = try ImageMagick.runMagick(std.testing.io, log, allocator, &.{ resized_path, "-format", "%m", "info:" });
    try std.testing.expectEqualStrings("JPEG", again.output);
}

//
// Writes the text to a file of the name and expects ImageMagick to refuse to read it as an image, with the prefix (a coder name and
// a colon, or nothing) in front of its path, and its error naming the coder it refused.
//
fn expectTextFileRefused(log: ILog, name: []const u8, text: []const u8, prefix: []const u8, refused: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try writeTextFile(allocator, tmp_dir, name, text);
    try expectReadRefused(log, allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, path }), refused);
}

test "the security policy refuses an MVG drawing" {
    const log = utils.mute_log.MuteLog.init();
    try expectTextFileRefused(log, "drawing.mvg", "viewbox 0 0 10 10\nfill red\nrectangle 0 0 9 9\n", "mvg:", "MVG");
}

test "the security policy refuses a picture written as ImageMagick's text listing of its pixels" {
    const log = utils.mute_log.MuteLog.init();
    try expectTextFileRefused(log, "pixels.txt", "# ImageMagick pixel enumeration: 2,1,255,srgb\n0,0: (255,0,0)  #FF0000  red\n1,0: (255,0,0)  #FF0000  red\n", "txt:", "TXT");
}

test "the security policy refuses text drawn as an image" {
    const log = utils.mute_log.MuteLog.init();
    try expectTextFileRefused(log, "words.txt", "hello\n", "text:", "TEXT");
}

test "the security policy refuses an SVG drawing, a PostScript program and a Photoshop file, by what the file holds" {
    const log = utils.mute_log.MuteLog.init();
    const svg = "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"><rect width=\"4\" height=\"4\" fill=\"red\"/></svg>\n";
    const postscript = "%!PS-Adobe-3.0\n%%BoundingBox: 0 0 4 4\nnewpath 0 0 moveto 4 0 lineto 4 4 lineto closepath fill\nshowpage\n";
    // The first bytes of a Photoshop file, which is all ImageMagick looks at to pick its coder.
    const photoshop = "8BPS\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03";
    try expectTextFileRefused(log, "drawing.svg", svg, "", "SVG");
    try expectTextFileRefused(log, "program.ps", postscript, "", "PS");
    try expectTextFileRefused(log, "picture.psd", photoshop, "", "PSD");

    // A name that says JPEG does not let the file through: the coder is the one its first bytes name.
    try expectTextFileRefused(log, "drawing.jpg", svg, "", "SVG");
    try expectTextFileRefused(log, "program.jpg", postscript, "", "PS");
}

test "the security policy refuses an icon, a type the import takes that the program does not read" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    try expectReadRefused(log, allocator, "../apps/photosphere/icons/photosphere.ico", "ICO");
}

test "the security policy refuses an indirect read of the paths listed in a file" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const image_path = try makeImage(log, allocator, tmp_dir, "listed.jpg", "6x4", "red");
    const list_path = try writeTextFile(allocator, tmp_dir, "list.txt", image_path);
    // The path rule stops ImageMagick reading the list, and ImageMagick drops that error itself and goes on to read the list file
    // as a picture, which the policy refuses as TXT. Without the path rule the listed JPEG would be read and the command would work.
    try expectReadRefused(log, allocator, try std.fmt.allocPrint(allocator, "@{s}", .{list_path}), "TXT");
}

//
// Expects the security policy to give the coders the rights asked about, or to refuse them, as `authorized` says.
//
fn expectCoderRights(coders: []const [*c]const u8, rights: media_tools.image_magick.c.PolicyRights, authorized: bool) !void {
    const c = media_tools.image_magick.c;
    for (coders) |coder| {
        const is_authorized = c.IsRightsAuthorized(c.CoderPolicyDomain, rights, coder) == c.MagickTrue;
        if (is_authorized != authorized) {
            std.debug.print("The coder {s} with rights {d}: expected authorized {}, got {}\n", .{ coder, rights, authorized, is_authorized });
            return error.TestUnexpectedResult;
        }
    }
}

test "the security policy allows only the coders the program reads and writes, and no delegate" {
    const c = media_tools.image_magick.c;
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    try expectCoderRights(&.{ "JPEG", "JPG", "JPE", "PNG", "WEBP", "GIF", "BMP" }, c.ReadPolicyRights, true);
    try expectCoderRights(&.{ "JPEG", "JPG", "INFO" }, c.WritePolicyRights, true);
    try expectCoderRights(&.{
        "URL", "HTTP", "HTTPS", "FTP",  "MSL", "MVG",  "MSVG",      "SVG",  "TEXT", "TXT", "EPHEMERAL", "SHOW", "WIN",  "X",
        "XC",  "PS",   "EPS",   "PDF",  "PSD", "TIFF", "ICO",       "MIFF", "MPC",  "XPM", "PICT",      "DPX",  "FITS", "SGI",
        "TGA", "PCX",  "PNM",   "INFO", "MNG", "JNG",  "HISTOGRAM", "MPO",  "UHDR",
    }, c.ReadPolicyRights, false);
    try expectCoderRights(&.{ "PNG", "WEBP", "GIF", "BMP", "TIFF", "PSD", "SVG", "PS", "PDF", "MIFF", "HISTOGRAM", "TXT" }, c.WritePolicyRights, false);
    const denied_delegates = [_][*c]const u8{ "https:decode", "http:decode", "dng:decode", "video:decode", "ps:alpha" };
    for (denied_delegates) |delegate| {
        if (c.IsRightsAuthorized(c.DelegatePolicyDomain, c.ExecutePolicyRights, delegate) != c.MagickFalse) {
            std.debug.print("The delegate {s} may still run\n", .{delegate});
            return error.TestUnexpectedResult;
        }
    }
}

test "with the security policy set, every image type the program reads still reads" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    try expectReadAllowed(log, allocator, "../test/test.jpg");
    try expectReadAllowed(log, allocator, "../test/multiple-files/test-1.jpeg");
    try expectReadAllowed(log, allocator, "../test/test.png");
    try expectReadAllowed(log, allocator, "../test/test.webp");
    try expectReadAllowed(log, allocator, "../test/test.gif");
    try expectReadAllowed(log, allocator, "../test/test.bmp");
}

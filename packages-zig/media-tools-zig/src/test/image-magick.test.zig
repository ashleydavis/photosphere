const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");

const ImageMagick = media_tools.ImageMagick;

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

//
// Makes an image of one colour with ImageMagick, in the format the name's extension says, and returns its path.
//
fn makeImage(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8, size: []const u8, color: []const u8) ![]const u8 {
    const path = try tempFilePath(allocator, tmp_dir, name);
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "-size", size, color, path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    return path;
}

test "magick -version names the version, the quantum depth and the delegates the library was built with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const result = try ImageMagick.runMagick(std.testing.io, arena.allocator(), &.{"-version"});
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Version: ImageMagick 7.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Q16-HDRI") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "jpeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "zlib") != null);
}

test "identify -format hands back the size of a JPEG written by the JPEG delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(allocator, tmp_dir, "red.jpg", "20x10", "xc:red");
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "identify", "-format", "%w %h", path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("20 10", result.output);
}

test "a command that ends in info: hands back what it printed, for a PNG written by the PNG delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(allocator, tmp_dir, "red.png", "30x20", "xc:red");
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ path, "-format", "%w %h", "info:" });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("30 20", result.output);
}

test "resizing writes a file of the new size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(allocator, tmp_dir, "big.jpg", "200x100", "xc:blue");
    const resized_path = try tempFilePath(allocator, tmp_dir, "small.jpg");
    const resize_result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ path, "-resize", "40x40", "-quality", "80", "-strip", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{resized_path}) });
    try std.testing.expectEqual(@as(i32, 0), resize_result.exit_code);
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ resized_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings("40 20", result.output);
}

test "the dominant colour command averages the image to one pixel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(allocator, tmp_dir, "red.png", "8x8", "xc:red");
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ path, "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" });
    try std.testing.expectEqualStrings("255,0,0", result.output);
}

test "the histogram command lists the colours of the image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(allocator, tmp_dir, "green.png", "8x8", "xc:#00ff00");
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ path, "-resize", "500x500", "-kmeans", "3", "-format", "%c", "histogram:info:" });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "#00FF00") != null);
}

test "a file that is not there makes the command fail, with ImageMagick's error naming the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ path, "-format", "%w", "info:" });
    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, result.output, "magick: "));
    try std.testing.expect(std.mem.indexOf(u8, result.output, path) != null);
}

test "identify of a file that is not an image fails with ImageMagick's error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try writeTextFile(allocator, tmp_dir, "broken.png", "not an image");
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "identify", "-format", "%w %h", path });
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
    const previous_log = utils.log.currentLog();
    utils.log.setLog(.{
        .ptr = &tool_log,
        .vtable = &IToolLog.vtable,
    });
    defer utils.log.setLog(previous_log);
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();

    // The JPEG fixture holds an XMP profile, which ImageMagick warns it cannot check without the XML library it is built without.
    // `identify` leaves the warning with the command, and `magick` hands it to ImageMagick's warning handler as it goes.
    const identified = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "identify", "-format", "%m", "../test/test.jpg" });
    try std.testing.expectEqual(@as(i32, 0), identified.exit_code);
    try std.testing.expectEqualStrings("JPEG", identified.output);
    try std.testing.expect(std.mem.indexOf(u8, tool_log.stderr.items, "magick: identify: DelegateLibrarySupportNotBuiltIn") != null);
    tool_log.stderr.clearRetainingCapacity();
    const png_path = try tempFilePath(allocator, tmp_dir, "from-jpeg.png");
    const converted = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "../test/test.jpg", "-resize", "16x16", try std.fmt.allocPrint(allocator, "png:{s}", .{png_path}) });
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
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var started = try media_tools.image_magick.Started.start();
        defer started.stop();
        const missing_path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
        const broken_path = try writeTextFile(allocator, tmp_dir, "broken.png", "not an image");
        const png_path = try tempFilePath(allocator, tmp_dir, "from-jpeg.png");

        const stderr_path = try tempFilePath(allocator, tmp_dir, "stderr.txt");
        const stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{});
        const saved_stderr = std.c.dup(2);
        try std.testing.expect(saved_stderr >= 0);
        try std.testing.expect(std.c.dup2(stderr_file.handle, 2) == 2);
        // A warning from `identify`, a warning from `magick`, an error from `magick` and an error from `identify`.
        const identified = ImageMagick.runMagick(std.testing.io, allocator, &.{ "identify", "-format", "%m", "../test/test.jpg" });
        const converted = ImageMagick.runMagick(std.testing.io, allocator, &.{ "../test/test.jpg", "-resize", "16x16", try std.fmt.allocPrint(allocator, "png:{s}", .{png_path}) });
        const missing = ImageMagick.runMagick(std.testing.io, allocator, &.{ missing_path, "-format", "%w", "info:" });
        const broken = ImageMagick.runMagick(std.testing.io, allocator, &.{ "identify", "-format", "%w %h", broken_path });
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
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = std.heap.page_allocator;
        defer threaded.deinit();
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const result = ImageMagick.runMagick(threaded.io(), arena.allocator(), &.{ worker.path, "-format", "%w %h", "info:" }) catch {
                return;
            };
            if (result.exit_code == 0 and std.mem.eql(u8, result.output, "30 20")) {
                worker.correct += 1;
            }
        }
    }
};

test "commands run on several threads at once all give their own answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try makeImage(allocator, tmp_dir, "shared.jpg", "30x20", "xc:red");
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

test "a WebP picture is read, and written, through the WebP delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const read = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "../test/test.webp", "-format", "%w %h", "info:" });
    try std.testing.expectEqual(@as(i32, 0), read.exit_code);
    var sizes = std.mem.splitScalar(u8, read.output, ' ');
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);

    // The app turns a picture into a JPEG of another size, and may write WebP.
    const jpeg_path = try tempFilePath(allocator, tmp_dir, "from-webp.jpg");
    const resized = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "../test/test.webp", "-resize", "8x8", "-quality", "80", "-strip", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{jpeg_path}) });
    try std.testing.expectEqual(@as(i32, 0), resized.exit_code);
    const webp_path = try tempFilePath(allocator, tmp_dir, "written.webp");
    const written = try ImageMagick.runMagick(std.testing.io, allocator, &.{ jpeg_path, "-quality", "80", try std.fmt.allocPrint(allocator, "webp:{s}", .{webp_path}) });
    try std.testing.expectEqual(@as(i32, 0), written.exit_code);
    const again = try ImageMagick.runMagick(std.testing.io, allocator, &.{ webp_path, "-format", "%m", "info:" });
    try std.testing.expectEqualStrings("WEBP", again.output);
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
// Asks ImageMagick for the size of the input and expects the command to fail, because the security policy refuses the read.
//
fn expectReadRefused(allocator: std.mem.Allocator, input: []const u8) !void {
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ input, "-format", "%w %h", "info:" });
    if (result.exit_code != 1) {
        std.debug.print("The read of {s} was not refused: exit code {d}, output \"{s}\"\n", .{ input, result.exit_code, result.output });
    }
    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
}

//
// Asks ImageMagick for the size of the input and expects it to be read, with a size above zero.
//
fn expectReadAllowed(allocator: std.mem.Allocator, input: []const u8) !void {
    const result = try ImageMagick.runMagick(std.testing.io, allocator, &.{ input, "-format", "%w %h", "info:" });
    if (result.exit_code != 0) {
        std.debug.print("The read of {s} failed with exit code {d}\n", .{ input, result.exit_code });
    }
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    var sizes = std.mem.splitScalar(u8, result.output, ' ');
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
}

test "with the security policy set, a JPEG still converts and identifies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const png_path = try tempFilePath(allocator, tmp_dir, "from-jpeg.png");
    const converted = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "../test/test.jpg", "-resize", "16x16", try std.fmt.allocPrint(allocator, "png:{s}", .{png_path}) });
    try std.testing.expectEqual(@as(i32, 0), converted.exit_code);
    const identified = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "identify", "-format", "%m", "../test/test.jpg" });
    try std.testing.expectEqual(@as(i32, 0), identified.exit_code);
    try std.testing.expectEqualStrings("JPEG", identified.output);
    const again = try ImageMagick.runMagick(std.testing.io, allocator, &.{ png_path, "-format", "%m", "info:" });
    try std.testing.expectEqualStrings("PNG", again.output);
}

//
// Writes the text to a file of the name and expects ImageMagick to refuse to read it as an image, with the prefix (a coder name and
// a colon) in front of its path.
//
fn expectTextFileRefused(name: []const u8, text: []const u8, prefix: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const path = try writeTextFile(allocator, tmp_dir, name, text);
    try expectReadRefused(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, path }));
}

test "the security policy refuses an MVG drawing" {
    try expectTextFileRefused("drawing.mvg", "viewbox 0 0 10 10\nfill red\nrectangle 0 0 9 9\n", "mvg:");
}

test "the security policy refuses a picture written as ImageMagick's text listing of its pixels" {
    try expectTextFileRefused("pixels.txt", "# ImageMagick pixel enumeration: 2,1,255,srgb\n0,0: (255,0,0)  #FF0000  red\n1,0: (255,0,0)  #FF0000  red\n", "txt:");
}

test "the security policy refuses text drawn as an image" {
    try expectTextFileRefused("words.txt", "hello\n", "text:");
}

test "the security policy refuses an indirect read of the paths listed in a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const image_path = try makeImage(allocator, tmp_dir, "listed.png", "6x4", "xc:red");
    const list_path = try writeTextFile(allocator, tmp_dir, "list.txt", image_path);
    try expectReadRefused(allocator, try std.fmt.allocPrint(allocator, "@{s}", .{list_path}));
}

test "the security policy denies every coder that reaches outside the file, and every delegate" {
    const c = media_tools.image_magick.c;
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    const denied_coders = [_][*c]const u8{ "URL", "HTTP", "HTTPS", "FTP", "MSL", "MVG", "MSVG", "TEXT", "TXT", "EPHEMERAL", "SHOW", "WIN", "X" };
    for (denied_coders) |coder| {
        if (c.IsRightsAuthorized(c.CoderPolicyDomain, c.ReadPolicyRights, coder) != c.MagickFalse) {
            std.debug.print("The coder {s} may still be read\n", .{coder});
            return error.TestUnexpectedResult;
        }
    }
    const denied_delegates = [_][*c]const u8{ "https:decode", "http:decode", "dng:decode", "video:decode", "ps:alpha" };
    for (denied_delegates) |delegate| {
        if (c.IsRightsAuthorized(c.DelegatePolicyDomain, c.ExecutePolicyRights, delegate) != c.MagickFalse) {
            std.debug.print("The delegate {s} may still run\n", .{delegate});
            return error.TestUnexpectedResult;
        }
    }
    const allowed_coders = [_][*c]const u8{ "JPEG", "PNG", "WEBP", "GIF", "PSD", "TIFF", "BMP", "ICO" };
    for (allowed_coders) |coder| {
        if (c.IsRightsAuthorized(c.CoderPolicyDomain, c.ReadPolicyRights, coder) != c.MagickTrue) {
            std.debug.print("The coder {s} may not be read\n", .{coder});
            return error.TestUnexpectedResult;
        }
    }
}

test "with the security policy set, every image type the import accepts that has a fixture still reads, and so does a PSD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var started = try media_tools.image_magick.Started.start();
    defer started.stop();
    try expectReadAllowed(allocator, "../test/test.jpg");
    try expectReadAllowed(allocator, "../test/multiple-files/test-1.jpeg");
    try expectReadAllowed(allocator, "../test/test.png");
    try expectReadAllowed(allocator, "../test/test.webp");
    try expectReadAllowed(allocator, "../apps/photosphere/icons/photosphere.ico");

    // The repository has no GIF, PSD, TIFF or BMP picture, so each is made from the JPEG fixture and read back.
    const made = [_][]const u8{ "made.gif", "made.psd", "made.tif", "made.bmp" };
    for (made) |name| {
        const path = try tempFilePath(allocator, tmp_dir, name);
        const written = try ImageMagick.runMagick(std.testing.io, allocator, &.{ "../test/test.jpg", "-resize", "16x16", path });
        try std.testing.expectEqual(@as(i32, 0), written.exit_code);
        try expectReadAllowed(allocator, path);
    }
}

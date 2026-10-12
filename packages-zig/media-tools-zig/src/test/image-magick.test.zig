const std = @import("std");
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
fn makeImage(allocator: std.mem.Allocator, image_magick: *ImageMagick, tmp_dir: std.testing.TmpDir, name: []const u8, size: []const u8, color: []const u8) ![]const u8 {
    const path = try tempFilePath(allocator, tmp_dir, name);
    const result = try image_magick.runMagick(allocator, &.{ "-size", size, color, path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    return path;
}

//
// A handler of ImageMagick's errors and warnings that prints nothing, so a test that makes a command fail leaves the standard error
// clean.
//
fn quietHandler(severity: media_tools.image_magick.c.ExceptionType, reason: [*c]const u8, description: [*c]const u8) callconv(.c) void {
    _ = severity;
    _ = reason;
    _ = description;
}

test "magick -version names the version, the quantum depth and the delegates the library was built with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const result = try image_magick.runMagick(arena.allocator(), &.{"-version"});
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
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try makeImage(allocator, &image_magick, tmp_dir, "red.jpg", "20x10", "xc:red");
    const result = try image_magick.runMagick(allocator, &.{ "identify", "-format", "%w %h", path });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("20 10", result.output);
}

test "a command that ends in info: hands back what it printed, for a PNG written by the PNG delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try makeImage(allocator, &image_magick, tmp_dir, "red.png", "30x20", "xc:red");
    const result = try image_magick.runMagick(allocator, &.{ path, "-format", "%w %h", "info:" });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("30 20", result.output);
}

test "resizing writes a file of the new size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try makeImage(allocator, &image_magick, tmp_dir, "big.jpg", "200x100", "xc:blue");
    const resized_path = try tempFilePath(allocator, tmp_dir, "small.jpg");
    const resize_result = try image_magick.runMagick(allocator, &.{ path, "-resize", "40x40", "-quality", "80", "-strip", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{resized_path}) });
    try std.testing.expectEqual(@as(i32, 0), resize_result.exit_code);
    const result = try image_magick.runMagick(allocator, &.{ resized_path, "-format", "%w %h", "info:" });
    try std.testing.expectEqualStrings("40 20", result.output);
}

test "the dominant colour command averages the image to one pixel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try makeImage(allocator, &image_magick, tmp_dir, "red.png", "8x8", "xc:red");
    const result = try image_magick.runMagick(allocator, &.{ path, "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" });
    try std.testing.expectEqualStrings("255,0,0", result.output);
}

test "the histogram command lists the colours of the image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try makeImage(allocator, &image_magick, tmp_dir, "green.png", "8x8", "xc:#00ff00");
    const result = try image_magick.runMagick(allocator, &.{ path, "-resize", "500x500", "-kmeans", "3", "-format", "%c", "histogram:info:" });
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "#00FF00") != null);
}

test "a file that is not there makes the command fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const previous_handler = media_tools.image_magick.c.SetErrorHandler(quietHandler);
    defer _ = media_tools.image_magick.c.SetErrorHandler(previous_handler);
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
    const result = try image_magick.runMagick(allocator, &.{ path, "-format", "%w", "info:" });
    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.output);
}

//
// What one thread of the concurrency test reads and runs.
//
const IWorker = struct {
    // The ImageMagick all the threads run commands on.
    image_magick: *ImageMagick,

    // The image to read the size of.
    path: []const u8,

    // How many times the size was read correctly.
    correct: usize,

    //
    // Reads the size of the image over and over, as tasks that hash files do at the same time.
    //
    fn run(worker: *IWorker) void {
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const result = worker.image_magick.runMagick(arena.allocator(), &.{ worker.path, "-format", "%w %h", "info:" }) catch {
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
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const path = try makeImage(allocator, &image_magick, tmp_dir, "shared.jpg", "30x20", "xc:red");
    var workers: [8]IWorker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{
            .image_magick = &image_magick,
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
    var image_magick = ImageMagick.init(std.testing.io);
    defer image_magick.deinit();
    const read = try image_magick.runMagick(allocator, &.{ "../test/test.webp", "-format", "%w %h", "info:" });
    try std.testing.expectEqual(@as(i32, 0), read.exit_code);
    var sizes = std.mem.splitScalar(u8, read.output, ' ');
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);
    try std.testing.expect(try std.fmt.parseInt(u32, sizes.next().?, 10) > 0);

    // The app turns a picture into a JPEG of another size, and may write WebP.
    const jpeg_path = try tempFilePath(allocator, tmp_dir, "from-webp.jpg");
    const resized = try image_magick.runMagick(allocator, &.{ "../test/test.webp", "-resize", "8x8", "-quality", "80", "-strip", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{jpeg_path}) });
    try std.testing.expectEqual(@as(i32, 0), resized.exit_code);
    const webp_path = try tempFilePath(allocator, tmp_dir, "written.webp");
    const written = try image_magick.runMagick(allocator, &.{ jpeg_path, "-quality", "80", try std.fmt.allocPrint(allocator, "webp:{s}", .{webp_path}) });
    try std.testing.expectEqual(@as(i32, 0), written.exit_code);
    const again = try image_magick.runMagick(allocator, &.{ webp_path, "-format", "%m", "info:" });
    try std.testing.expectEqualStrings("WEBP", again.output);
}

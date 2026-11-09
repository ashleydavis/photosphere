const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const builtin = @import("builtin");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const node_utils = @import("node-utils-zig");
const fake_tool_runner = @import("fake-tool-runner.zig");
const Image = tools.Image;
const MediaTools = media_tools.MediaTools;
const FakeToolRunner = fake_tool_runner.FakeToolRunner;

//
// Generates the same ID every time, so the output paths are known.
//
const FixedUuidGenerator = struct {
    //
    // Gets the IUuidGenerator interface.
    //
    fn uuidGenerator(self: *FixedUuidGenerator) utils.uuid_generator.IUuidGenerator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // The functions of the generator.
    const vtable: utils.uuid_generator.IUuidGenerator.VTable = .{ .generate = generate };

    //
    // Returns the fixed ID.
    //
    fn generate(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = io;
        return "fixed";
    }
};

//
// Expects getDominantColor to refuse what the fake commands print when it is not
// three numbers between 0 and 255.
//
fn expectDominantColorRefusal(allocator: std.mem.Allocator, io: std.Io, log: ILog, fakeOutput: []const u8) !void {
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = fakeOutput,
        },
    });
    var image = Image.init("../test/test.png");
    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, io, log, fakeTools.runner()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Failed to extract dominant color: Error: Invalid RGB values: {s}", .{fakeOutput}), utils.errors.lastErrorMessage());
}

test "getInfo reads a width and a height of NaN from output ImageMagick did not write" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    // The fake identify prints "100" with no height, so parseInt reads the width and finds nothing for the height.
    var widthOnly = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "100",
        },
    });
    var image = Image.init("../test/test.png");
    const info = try image.getInfo(allocator, io, log, widthOnly.runner());
    try std.testing.expectEqual(@as(f64, 100), info.dimensions.width);
    try std.testing.expect(std.math.isNan(info.dimensions.height));

    // Output with no width at all is NaN for both.
    var nothing = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "",
        },
    });
    var blank = Image.init("../test/test.png");
    const blankInfo = try blank.getInfo(allocator, io, log, nothing.runner());
    try std.testing.expect(std.math.isNan(blankInfo.dimensions.width));
    try std.testing.expect(std.math.isNan(blankInfo.dimensions.height));
    try std.testing.expect(blankInfo.createdAt == null);
}

test "getDimensions runs only the size identify, and getInfo runs the EXIF identify as well" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var sizeOnly = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "100 90",
        },
    });
    var image = Image.init("../test/test.png");
    const dimensions = try image.getDimensions(allocator, io, log, sizeOnly.runner());
    try std.testing.expectEqual(@as(f64, 100), dimensions.width);
    try std.testing.expectEqual(@as(f64, 90), dimensions.height);
    try std.testing.expectEqual(@as(usize, 1), sizeOnly.calls.items.len);
    try std.testing.expectEqualStrings("magick identify -format %w %h\n ../test/test.png", sizeOnly.calls.items[0]);

    // getInfo still reads the EXIF for createdAt, after the size.
    var full = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "100 90",
        },
    });
    var withInfo = Image.init("../test/test.png");
    const info = try withInfo.getInfo(allocator, io, log, full.runner());
    try std.testing.expectEqual(dimensions, info.dimensions);
    try std.testing.expectEqual(@as(usize, 2), full.calls.items.len);
    try std.testing.expectEqualStrings("magick identify -format %w %h\n ../test/test.png", full.calls.items[0]);
    try std.testing.expectEqualStrings("magick identify -format %[EXIF:*] ../test/test.png", full.calls.items[1]);

    // Once getInfo has read the image, getDimensions answers from it without running anything more.
    try std.testing.expectEqual(info.dimensions, try withInfo.getDimensions(allocator, io, log, full.runner()));
    try std.testing.expectEqual(@as(usize, 2), full.calls.items.len);
}

test "getDominantColor refuses output that is not three values between 0 and 255" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Two values where three are needed.
    try expectDominantColorRefusal(allocator, io, log, "1,2");

    // A value past 255.
    try expectDominantColorRefusal(allocator, io, log, "256,0,0");

    // A value that is not a number at all.
    try expectDominantColorRefusal(allocator, io, log, "a,b,c");
}

test "verifyImageMagick reports a magick that fails with no install advice, and remembers nothing of it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // A runner whose `magick -version` fails.
    var failing = FakeToolRunner.init(allocator, &.{});
    const failed = try tools.Image.verifyImageMagick(allocator, io, log, failing.runner());
    try std.testing.expect(!failed.available);
    try std.testing.expectEqualStrings("The ImageMagick built into the program did not run: Error: Command failed: magick -version\n", failed.@"error".?);
    try std.testing.expect(std.mem.indexOf(u8, failed.@"error".?, "install") == null);
    try std.testing.expect(failed.version == null);
    try std.testing.expectEqualStrings("-version", try failing.argumentsOf("magick"));

    // Nothing is remembered from the failure, so the next call with the built-in ImageMagick runs it and finds it.
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const builtIn = try tools.Image.verifyImageMagick(allocator, io, log, mediaTools.runner());
    try std.testing.expect(builtIn.available);
    try std.testing.expect(builtIn.@"error" == null);
    try std.testing.expect(std.mem.startsWith(u8, builtIn.version.?, "7."));
}

test "verifyImageMagick reads the version from the tool's output" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "Version: ImageMagick 7.1.1-29 Q16-HDRI x86_64 https://imagemagick.org",
        },
    });

    const status = try tools.Image.verifyImageMagick(allocator, io, log, fakeTools.runner());

    try std.testing.expect(status.available);
    try std.testing.expectEqualStrings("7.1.1-29", status.version.?);
}

test "verifyImageMagick reports unknown when the version cannot be found" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "Something else",
        },
    });

    const status = try tools.Image.verifyImageMagick(allocator, io, log, fakeTools.runner());

    try std.testing.expect(status.available);
    try std.testing.expectEqualStrings("unknown", status.version.?);
}

test "resize and transform write their numbers as a template string writes a number" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    // A magick that writes no image, so the validation after each command fails.
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "",
        },
    });
    var uuids: FixedUuidGenerator = .{};
    var image = Image.init("../test/test.png");

    // Resize writes the sRGB profile into its temp directory before it runs the command, so that directory has to exist.
    var randomBytes: [8]u8 = undefined;
    io.random(&randomBytes);
    const resizeDir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/image-command-test-resize-{x}", .{std.mem.readInt(u64, &randomBytes, .little)});
    try std.Io.Dir.cwd().createDirPath(io, resizeDir);
    defer std.Io.Dir.cwd().deleteTree(io, resizeDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ resizeDir, @errorName(err) });

    // Every path is passed as an argument of its own (`magick <file> -resize <geometry> -profile <sRGB profile> -strip <output>`),
    // unquoted. The profile and the output paths are joined with node-utils' path.join, which normalizes every `/` to a `\` on Windows.
    const separator = if (builtin.os.tag == .windows) "\\" else "/";
    const resizeDirJoined = try std.mem.replaceOwned(u8, allocator, resizeDir, "/", separator);
    const resizeArguments = try std.mem.concat(allocator, u8, &.{ "../test/test.png -resize 1e+21x -profile ", resizeDirJoined, separator, "temp_resize_fixed.icc -strip -quality 1e-7 ", resizeDirJoined, separator, "temp_resize_fixed.jpg" });
    const transformArguments = if (builtin.os.tag == .windows)
        "../test/test.png -rotate 1e+21 out\\temp_transform_output_fixed.jpg"
    else
        "../test/test.png -rotate 1e+21 out/temp_transform_output_fixed.jpg";

    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 1e21, .height = 0, .quality = 1e-7, .format = null, .ext = "jpg", .transformation = null }, resizeDir, uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(resizeArguments, try fakeTools.argumentsOf("magick"));

    // The profile is removed after the command, which failed.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try std.fs.path.join(allocator, &.{ resizeDir, "temp_resize_fixed.icc" }), .{}));

    try std.testing.expectError(error.Thrown, image.transform(allocator, io, log, fakeTools.runner(), .{ .rotate = 1e21 }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(transformArguments, try fakeTools.argumentsOf("magick"));
}

//
// A new directory for a resize under test to write its sRGB profile into, which it does before it runs the command, and the
// same path with `/` written as the platform's separator, as the command line shows it.
//
const IResizeDir = struct {
    // The directory, as given to resize.
    path: []const u8,

    // The directory as it appears in the command line.
    joined: []const u8,
};

//
// Makes the directory a resize under test writes into.
//
fn makeResizeDir(allocator: std.mem.Allocator, io: std.Io) !IResizeDir {
    var randomBytes: [8]u8 = undefined;
    io.random(&randomBytes);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/image-command-test-resize-{x}", .{std.mem.readInt(u64, &randomBytes, .little)});
    try std.Io.Dir.cwd().createDirPath(io, path);
    const separator = if (builtin.os.tag == .windows) "\\" else "/";
    return .{
        .path = path,
        .joined = try std.mem.replaceOwned(u8, allocator, path, "/", separator),
    };
}

//
// The command line of a resize into resizeDir: what comes before `-resize`, then `-resize <geometry>`, the sRGB profile and
// the strip, then the quality and the output.
//
fn resizeCommand(allocator: std.mem.Allocator, resizeDir: IResizeDir, before: []const u8, geometry: []const u8) ![]const u8 {
    const separator = if (builtin.os.tag == .windows) "\\" else "/";
    return std.mem.concat(allocator, u8, &.{ before, " -resize ", geometry, " -profile ", resizeDir.joined, separator, "temp_resize_fixed.icc -strip -quality 95 jpeg:", resizeDir.joined, separator, "temp_resize_fixed.jpg" });
}

test "resize puts a flip and a turn before the resize, in the same command" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    // A magick that writes no image, so the validation after each command fails.
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "",
        },
    });
    var uuids: FixedUuidGenerator = .{};
    var image = Image.init("../test/test.png");
    const resizeDir = try makeResizeDir(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, resizeDir.path) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ resizeDir.path, @errorName(err) });

    // `-flop` then `-rotate`, as transform writes them, between the input and `-resize`, so the picture is turned before it is made smaller.
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 45, .height = 50, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = .{ .flipX = true, .rotate = 270, .changeOrientation = true } }, resizeDir.path, uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(try resizeCommand(allocator, resizeDir, "../test/test.png -flop -rotate 270", "45x50"), try fakeTools.argumentsOf("magick"));

    // A transformation that asks for nothing (no flip, a turn of 0) adds nothing to the command.
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 45, .height = 50, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = .{ .flipX = false, .rotate = 0 } }, resizeDir.path, uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(try resizeCommand(allocator, resizeDir, "../test/test.png", "45x50"), try fakeTools.argumentsOf("magick"));
}

test "resize with a reduced JPEG decode hints it at half as big again as the target, before the input" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    // A magick that writes no image, so the validation after each command fails.
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "",
        },
    });
    var uuids: FixedUuidGenerator = .{};
    var image = Image.init("../test/test.jpg");
    const resizeDir = try makeResizeDir(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, resizeDir.path) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ resizeDir.path, @errorName(err) });

    // 1333x1000 is hinted as 2000x1500: 1333 * 1.5 is 1999.5, rounded up, and 1000 * 1.5 is 1500. The define comes before
    // the input, as ImageMagick reads it when it decodes the input.
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 1333, .height = 1000, .quality = 95, .format = "jpeg", .ext = "jpg", .maintainAspectRatio = false, .reducedJpegDecode = true, .transformation = null }, resizeDir.path, uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(try resizeCommand(allocator, resizeDir, "-define jpeg:size=2000x1500 ../test/test.jpg", "1333x1000!"), try fakeTools.argumentsOf("magick"));

    // With a quarter turn the target is the turned size, 1000x1333, and the hint is for the decode, which comes before the
    // turn, so it is given the way the photo is stored: 2000x1500 again, not 1500x2000.
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 1000, .height = 1333, .quality = 95, .format = "jpeg", .ext = "jpg", .maintainAspectRatio = false, .reducedJpegDecode = true, .transformation = .{ .rotate = 90, .changeOrientation = true } }, resizeDir.path, uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(try resizeCommand(allocator, resizeDir, "-define jpeg:size=2000x1500 ../test/test.jpg -rotate 90", "1000x1333!"), try fakeTools.argumentsOf("magick"));

    // Without it there is no hint.
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 1333, .height = 1000, .quality = 95, .format = "jpeg", .ext = "jpg", .maintainAspectRatio = false, .transformation = null }, resizeDir.path, uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(try resizeCommand(allocator, resizeDir, "../test/test.jpg", "1333x1000!"), try fakeTools.argumentsOf("magick"));
}

test "resize refuses a reduced JPEG decode without both a width and a height" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fakeTools = FakeToolRunner.init(allocator, &.{
        .{
            .name = "magick",
            .output = "",
        },
    });
    var uuids: FixedUuidGenerator = .{};
    var image = Image.init("../test/test.jpg");
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, fakeTools.runner(), .{ .width = 0, .height = 45, .quality = null, .format = null, .ext = "jpg", .reducedJpegDecode = true, .transformation = null }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings("A reduced JPEG decode needs both a width and a height, given 0x45", utils.errors.lastErrorMessage());
}

//
// A magick whose `identify -format "%[EXIF:*]"` fails, as it does when ImageMagick cannot read a file's EXIF, and which
// prints "100 90" for anything else, so the `identify -format "%w %h"` before it reads a size.
//
fn runFailingExif(context: ?*anyopaque, _: std.Io, _: ILog, _: std.mem.Allocator, _: []const u8, arguments: []const []const u8) anyerror!node_utils.in_process_tools.ToolOutput {
    _ = context;
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "%[EXIF:*]")) {
            return .{
                .exit_code = 1,
                .output = "",
            };
        }
    }
    return .{
        .exit_code = 0,
        .output = "100 90",
    };
}

test "getInfo fails, naming the command and the file, when the EXIF cannot be read" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const failingExif: node_utils.in_process_tools.InProcessRunner = .{
        .context = null,
        .run = runFailingExif,
    };

    // The size is read, but the EXIF read fails, and that failure is the result rather than an image with no date.
    var image = Image.init("../test/test.png");
    try std.testing.expectError(error.Thrown, image.getInfo(allocator, io, log, failingExif));
    try std.testing.expectEqualStrings("Failed to get EXIF data: Error: Failed to execute command: magick identify -format %[EXIF:*] ../test/test.png", utils.errors.lastErrorMessage());

    // getFileInfo, which import and validation call, reports it for the file.
    try std.testing.expectError(error.Thrown, tools.getFileInfo(allocator, io, log, failingExif, "../test/test.png", "image/png"));
    try std.testing.expectEqualStrings("Failed to get image info for ../test/test.png: Error: Failed to get EXIF data: Error: Failed to execute command: magick identify -format %[EXIF:*] ../test/test.png\nThrown", utils.errors.lastErrorMessage());
}

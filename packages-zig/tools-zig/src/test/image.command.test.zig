const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const builtin = @import("builtin");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
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

    // Both paths are passed as arguments of their own (`magick <file> -resize <geometry> -strip <output>`), unquoted. The output path is joined with node-utils' path.join, which normalizes every `/` to a `\`
    // on Windows.
    const resizeArguments = if (builtin.os.tag == .windows)
        "../test/test.png -resize 1e+21x -strip -quality 1e-7 out\\temp_resize_fixed.jpg"
    else
        "../test/test.png -resize 1e+21x -strip -quality 1e-7 out/temp_resize_fixed.jpg";
    const transformArguments = if (builtin.os.tag == .windows)
        "../test/test.png -rotate 1e+21 out\\temp_transform_output_fixed.jpg"
    else
        "../test/test.png -rotate 1e+21 out/temp_transform_output_fixed.jpg";

    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 1e21, .height = 0, .quality = 1e-7, .format = null, .ext = "jpg", .transformation = null }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(resizeArguments, try fakeTools.argumentsOf("magick"));

    try std.testing.expectError(error.Thrown, image.transform(allocator, io, log, fakeTools.runner(), .{ .rotate = 1e21 }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(transformArguments, try fakeTools.argumentsOf("magick"));
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

    // `-flop` then `-rotate`, as transform writes them, between the input and `-resize`, so the picture is turned before it is made smaller.
    const transformedArguments = if (builtin.os.tag == .windows)
        "../test/test.png -flop -rotate 270 -resize 45x50 -strip -quality 95 jpeg:out\\temp_resize_fixed.jpg"
    else
        "../test/test.png -flop -rotate 270 -resize 45x50 -strip -quality 95 jpeg:out/temp_resize_fixed.jpg";
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 45, .height = 50, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = .{ .flipX = true, .rotate = 270, .changeOrientation = true } }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(transformedArguments, try fakeTools.argumentsOf("magick"));

    // A transformation that asks for nothing (no flip, a turn of 0) adds nothing to the command.
    const plainArguments = if (builtin.os.tag == .windows)
        "../test/test.png -resize 45x50 -strip -quality 95 jpeg:out\\temp_resize_fixed.jpg"
    else
        "../test/test.png -resize 45x50 -strip -quality 95 jpeg:out/temp_resize_fixed.jpg";
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, log, fakeTools.runner(), .{ .width = 45, .height = 50, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = .{ .flipX = false, .rotate = 0 } }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(plainArguments, try fakeTools.argumentsOf("magick"));
}

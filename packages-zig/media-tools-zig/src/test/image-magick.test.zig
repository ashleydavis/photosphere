const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");
const ziggy = @import("ziggy");
const ICapturedLog = @import("captured-log.zig").ICapturedLog;

const image_magick = media_tools.image_magick;
const c = image_magick.c;

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

//
// Writes an image of one colour in the format, with writeRgbImage, and returns its path.
//
fn makeImage(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8, width: usize, height: usize, color: [3]u8, format: []const u8) ![]const u8 {
    const path = try tempFilePath(allocator, tmp_dir, name);
    const bytes = try allocator.alloc(u8, width * height * 3);
    for (0..width * height) |pixel| {
        @memcpy(bytes[pixel * 3 ..][0..3], &color);
    }
    try image_magick.writeRgbImage(allocator, std.testing.io, utils.mute_log.MuteLog.init(), .{
        .width = width,
        .height = height,
        .bytes = bytes,
    }, .{
        .source = name,
        .output_path = path,
        .turn = .{},
        .format = format,
        .quality = 90,
    });
    return path;
}

// The colours of the six pixels of the picture makeGrid writes, by position: A B C on the top row and D E F on the bottom one.
const color_a = [3]u8{ 255, 0, 0 };
const color_b = [3]u8{ 0, 255, 0 };
const color_c = [3]u8{ 0, 0, 255 };
const color_d = [3]u8{ 255, 255, 255 };
const color_e = [3]u8{ 0, 0, 0 };
const color_f = [3]u8{ 255, 255, 0 };

//
// Writes a PNG of three by two pixels, A B C over D E F, so a turn can be read back from where each colour went.
//
fn makeGrid(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const path = try tempFilePath(allocator, tmp_dir, name);
    const bytes = color_a ++ color_b ++ color_c ++ color_d ++ color_e ++ color_f;
    try image_magick.writeRgbImage(allocator, std.testing.io, utils.mute_log.MuteLog.init(), .{
        .width = 3,
        .height = 2,
        .bytes = &bytes,
    }, .{
        .source = name,
        .output_path = path,
        .turn = .{},
        .format = "PNG",
        .quality = 90,
    });
    return path;
}

//
// Puts the path in an ImageInfo's file name, ending it with a zero.
//
fn setFileName(field: []u8, path: []const u8) void {
    @memcpy(field[0..path.len], path);
    field[path.len] = 0;
}

//
// Reads the colour of one pixel of the image at the path, through ImageMagick's own C interface, as eight bit red, green and blue.
//
fn pixelAt(path: []const u8, x: isize, y: isize) ![3]u8 {
    c.MagickCoreGenesis(null, c.MagickFalse);
    const image_info = c.AcquireImageInfo();
    defer _ = c.DestroyImageInfo(image_info);
    setFileName(&@as(*c.ImageInfo, image_info).filename, path);
    const exception = c.AcquireExceptionInfo();
    defer _ = c.DestroyExceptionInfo(exception);
    const image = c.ReadImage(image_info, exception) orelse return error.TestUnexpectedResult;
    defer _ = c.DestroyImageList(image);
    var pixel: c.PixelInfo = undefined;
    if (c.GetOneVirtualPixelInfo(image, c.UndefinedVirtualPixelMethod, x, y, &pixel, exception) != c.MagickTrue) {
        return error.TestUnexpectedResult;
    }
    const range: f64 = c.QuantumRange;
    return .{
        @intFromFloat(@round(@as(f64, pixel.red) / range * 255)),
        @intFromFloat(@round(@as(f64, pixel.green) / range * 255)),
        @intFromFloat(@round(@as(f64, pixel.blue) / range * 255)),
    };
}

//
// The quality a JPEG says it was written at, through ImageMagick's own C interface.
//
fn jpegQuality(path: []const u8) !usize {
    c.MagickCoreGenesis(null, c.MagickFalse);
    const image_info = c.AcquireImageInfo();
    defer _ = c.DestroyImageInfo(image_info);
    setFileName(&@as(*c.ImageInfo, image_info).filename, path);
    const exception = c.AcquireExceptionInfo();
    defer _ = c.DestroyExceptionInfo(exception);
    const image = c.PingImage(image_info, exception) orelse return error.TestUnexpectedResult;
    defer _ = c.DestroyImageList(image);
    return image.*.quality;
}

//
// Expects the pixels of a three by two or two by three image to be the colours given, row by row.
//
fn expectPixels(path: []const u8, width: usize, expected: []const [3]u8) !void {
    for (expected, 0..) |color, index| {
        const actual = try pixelAt(path, @intCast(index % width), @intCast(index / width));
        if (!std.mem.eql(u8, &color, &actual)) {
            std.debug.print("The pixel at {d},{d} is {any}, not {any}\n", .{ index % width, index / width, actual, color });
            return error.TestUnexpectedResult;
        }
    }
}

test "version, quantum and delegates name ImageMagick 7, Q16-HDRI and the JPEG, PNG and zlib libraries it is built with" {
    try std.testing.expect(std.mem.startsWith(u8, image_magick.version(), "7."));
    try std.testing.expect(std.mem.indexOfScalar(u8, image_magick.version(), '-') != null);
    try std.testing.expectEqualStrings("Q16-HDRI", image_magick.quantum());
    const delegates = try image_magick.delegates();
    try std.testing.expect(std.mem.indexOf(u8, delegates, "jpeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, delegates, "png") != null);
    try std.testing.expect(std.mem.indexOf(u8, delegates, "zlib") != null);
}

test "readImageInfo gives the size and format of a JPEG written by the JPEG delegate and a PNG by the PNG delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    const jpeg = try image_magick.readImageInfo(allocator, log, try makeImage(allocator, tmp_dir, "red.jpg", 20, 10, color_a, "JPEG"));
    try std.testing.expectEqual(@as(usize, 20), jpeg.width);
    try std.testing.expectEqual(@as(usize, 10), jpeg.height);
    try std.testing.expectEqualStrings("JPEG", jpeg.format);
    const png = try image_magick.readImageInfo(allocator, log, try makeImage(allocator, tmp_dir, "red.png", 30, 20, color_a, "PNG"));
    try std.testing.expectEqual(@as(usize, 30), png.width);
    try std.testing.expectEqual(@as(usize, 20), png.height);
    try std.testing.expectEqualStrings("PNG", png.format);
}

test "resizeImage writes a file of the new size, in the format and at the quality asked for, with no EXIF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    const big = try makeImage(allocator, tmp_dir, "big.jpg", 200, 100, color_c, "JPEG");
    const small = try tempFilePath(allocator, tmp_dir, "small.jpg");
    try image_magick.resizeImage(allocator, std.testing.io, log, .{
        .input_path = big,
        .output_path = small,
        .width = 40,
        .height = 40,
        .exact = false,
        .quality = 95,
        .format = "JPEG",
    });
    const info = try image_magick.readImageInfo(allocator, log, small);
    try std.testing.expectEqual(@as(usize, 40), info.width);
    try std.testing.expectEqual(@as(usize, 20), info.height);
    try std.testing.expectEqualStrings("JPEG", info.format);
    try std.testing.expectEqual(@as(usize, 95), try jpegQuality(small));

    // test.jpg carries EXIF, which the resize drops along with every other profile.
    try std.testing.expect((try image_magick.readExif(allocator, log, "../test/test.jpg")).count() > 0);
    const stripped = try tempFilePath(allocator, tmp_dir, "stripped.jpg");
    try image_magick.resizeImage(allocator, std.testing.io, log, .{
        .input_path = "../test/test.jpg",
        .output_path = stripped,
        .width = 64,
        .height = null,
        .exact = false,
        .quality = 90,
        .format = "JPEG",
    });
    try std.testing.expectEqual(@as(usize, 0), (try image_magick.readExif(allocator, log, stripped)).count());

    // The colour survives the resize.
    const color = try pixelAt(small, 20, 10);
    try std.testing.expect(color[0] < 10 and color[1] < 10 and color[2] > 245);
}

test "resizeSize works out the size as ImageMagick's -resize geometry does" {
    // Fitted inside, keeping the aspect ratio ("40x40").
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 40,
        .height = 20,
    }, try image_magick.resizeSize(200, 100, 40, 40, false));
    // 2560x1920 fitted inside 1333x1000 is 1333x1000.
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 1333,
        .height = 1000,
    }, try image_magick.resizeSize(2560, 1920, 1333, 1000, false));
    // A width alone ("50x") and a height alone ("x45").
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 50,
        .height = 45,
    }, try image_magick.resizeSize(100, 90, 50, null, false));
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 50,
        .height = 45,
    }, try image_magick.resizeSize(100, 90, null, 45, false));
    // Exactly the size asked for ("20x30!").
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 20,
        .height = 30,
    }, try image_magick.resizeSize(100, 90, 20, 30, true));
    // A side rounds half up and is never less than one pixel.
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 3,
        .height = 1,
    }, try image_magick.resizeSize(5, 1, 3, null, false));
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 1,
        .height = 1,
    }, try image_magick.resizeSize(1000, 1, 1, null, false));
    // An image enlarged.
    try std.testing.expectEqual(image_magick.IImageSize{
        .width = 200,
        .height = 180,
    }, try image_magick.resizeSize(100, 90, 200, null, false));
    try std.testing.expectError(error.Thrown, image_magick.resizeSize(100, 90, null, null, false));
}

test "resizeImage of an animation writes its first frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();

    // A GIF of a red frame and a blue one, made through ImageMagick's C interface.
    c.MagickCoreGenesis(null, c.MagickFalse);
    const exception = c.AcquireExceptionInfo();
    defer _ = c.DestroyExceptionInfo(exception);
    const red_bytes = [_]u8{ 255, 0, 0 } ** (20 * 10);
    const blue_bytes = [_]u8{ 0, 0, 255 } ** (20 * 10);
    const frames = c.ConstituteImage(20, 10, "RGB", c.CharPixel, &red_bytes, exception);
    c.AppendImageToList(@constCast(&frames), c.ConstituteImage(20, 10, "RGB", c.CharPixel, &blue_bytes, exception));
    defer _ = c.DestroyImageList(frames);
    const animation_path = try tempFilePath(allocator, tmp_dir, "animation.gif");
    const image_info = c.AcquireImageInfo();
    defer _ = c.DestroyImageInfo(image_info);
    try std.testing.expectEqual(@as(c.MagickBooleanType, c.MagickTrue), c.WriteImages(image_info, frames, animation_path.ptr, exception));

    const output_path = try tempFilePath(allocator, tmp_dir, "first.png");
    try image_magick.resizeImage(allocator, std.testing.io, log, .{
        .input_path = animation_path,
        .output_path = output_path,
        .width = 10,
        .height = null,
        .exact = false,
        .quality = null,
        .format = "PNG",
    });
    const info = try image_magick.readImageInfo(allocator, log, output_path);
    try std.testing.expectEqual(@as(usize, 10), info.width);
    try std.testing.expectEqual(@as(usize, 5), info.height);
    try std.testing.expectEqualSlices(u8, &color_a, &(try pixelAt(output_path, 5, 2)));
}

test "dominantColor averages the image to one pixel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, try image_magick.dominantColor(allocator, log, try makeImage(allocator, tmp_dir, "red.png", 8, 8, color_a, "PNG")));
    // Half black and half white is a mid grey.
    const grid = try makeGrid(allocator, tmp_dir, "grid.png");
    const mean = try image_magick.dominantColor(allocator, log, grid);
    try std.testing.expect(mean[0] > 60 and mean[0] < 200);
}

test "colorComponent rounds down to a whole number from 0 to 255 and refuses a component outside 0 to 1" {
    try std.testing.expectEqual(@as(u8, 255), try image_magick.colorComponent(1));
    try std.testing.expectEqual(@as(u8, 0), try image_magick.colorComponent(0));
    try std.testing.expectEqual(@as(u8, 127), try image_magick.colorComponent(0.5));
    try std.testing.expectEqual(@as(u8, 254), try image_magick.colorComponent(0.999));
    try std.testing.expectError(error.Thrown, image_magick.colorComponent(1.01));
    try std.testing.expectError(error.Thrown, image_magick.colorComponent(-0.01));
    try std.testing.expectError(error.Thrown, image_magick.colorComponent(std.math.nan(f64)));
}

test "transformImage and writeRgbImage turn and mirror the picture as asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    const grid = try makeGrid(allocator, tmp_dir, "grid.png");
    try expectPixels(grid, 3, &.{ color_a, color_b, color_c, color_d, color_e, color_f });

    const IExpectedTurn = struct {
        turn: image_magick.ITurn,
        width: usize,
        pixels: []const [3]u8,
    };
    const cases = [_]IExpectedTurn{
        .{
            .turn = .{
                .flop = true,
            },
            .width = 3,
            .pixels = &.{ color_c, color_b, color_a, color_f, color_e, color_d },
        },
        .{
            .turn = .{
                .flip = true,
            },
            .width = 3,
            .pixels = &.{ color_d, color_e, color_f, color_a, color_b, color_c },
        },
        .{
            .turn = .{
                .rotate_degrees = 90,
            },
            .width = 2,
            .pixels = &.{ color_d, color_a, color_e, color_b, color_f, color_c },
        },
        .{
            .turn = .{
                .rotate_degrees = 270,
            },
            .width = 2,
            .pixels = &.{ color_c, color_f, color_b, color_e, color_a, color_d },
        },
        .{
            .turn = .{
                .transpose = true,
            },
            .width = 2,
            .pixels = &.{ color_a, color_d, color_b, color_e, color_c, color_f },
        },
        .{
            .turn = .{
                .transverse = true,
            },
            .width = 2,
            .pixels = &.{ color_f, color_c, color_e, color_b, color_d, color_a },
        },
        // Mirrored, then turned a quarter clockwise, as transform does for an EXIF orientation that says both.
        .{
            .turn = .{
                .flop = true,
                .rotate_degrees = 90,
            },
            .width = 2,
            .pixels = &.{ color_f, color_c, color_e, color_b, color_d, color_a },
        },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("case {d}\n", .{index});
        const output_path = try tempFilePath(allocator, tmp_dir, try std.fmt.allocPrint(allocator, "turned-{d}.png", .{index}));
        try image_magick.transformImage(allocator, std.testing.io, log, .{
            .input_path = grid,
            .output_path = output_path,
            .turn = case.turn,
            .format = "PNG",
        });
        try expectPixels(output_path, case.width, case.pixels);

        const written_path = try tempFilePath(allocator, tmp_dir, try std.fmt.allocPrint(allocator, "written-{d}.png", .{index}));
        const bytes = color_a ++ color_b ++ color_c ++ color_d ++ color_e ++ color_f;
        try image_magick.writeRgbImage(allocator, std.testing.io, log, .{
            .width = 3,
            .height = 2,
            .bytes = &bytes,
        }, .{
            .source = "the grid",
            .output_path = written_path,
            .turn = case.turn,
            .format = "PNG",
            .quality = 90,
        });
        try expectPixels(written_path, case.width, case.pixels);
    }

    // A JPEG keeps the size of the turned picture, and is a JPEG.
    const jpeg_path = try tempFilePath(allocator, tmp_dir, "turned.jpg");
    try image_magick.transformImage(allocator, std.testing.io, log, .{
        .input_path = "../test/test.png",
        .output_path = jpeg_path,
        .turn = .{
            .rotate_degrees = 90,
        },
        .format = "JPEG",
    });
    const info = try image_magick.readImageInfo(allocator, log, jpeg_path);
    try std.testing.expectEqual(@as(usize, 90), info.width);
    try std.testing.expectEqual(@as(usize, 100), info.height);
    try std.testing.expectEqualStrings("JPEG", info.format);
}

test "writeRgbImage refuses bytes that are not the size it is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expectError(error.Thrown, image_magick.writeRgbImage(allocator, std.testing.io, utils.mute_log.MuteLog.init(), .{
        .width = 2,
        .height = 1,
        .bytes = &bytes,
    }, .{
        .source = "five bytes",
        .output_path = "never-written.png",
        .turn = .{},
        .format = "PNG",
        .quality = 90,
    }));
    try std.testing.expectEqualStrings("5 bytes are not the 2x1 pixels of five bytes.", utils.errors.lastErrorMessage());
}

test "a file that is not there fails the call, with ImageMagick's error naming the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
    try std.testing.expectError(error.Thrown, image_magick.readImageInfo(allocator, utils.mute_log.MuteLog.init(), path));
    const message = utils.errors.lastErrorMessage();
    try std.testing.expect(std.mem.startsWith(u8, message, try std.fmt.allocPrint(allocator, "ImageMagick could not read the size of {s}: ", .{path})));
    try std.testing.expect(std.mem.indexOf(u8, message, "UnableToOpenBlob") != null);
}

test "a file that is not an image fails the call with ImageMagick's error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try writeTextFile(allocator, tmp_dir, "broken.png", "not an image");
    try std.testing.expectError(error.Thrown, image_magick.readImageInfo(allocator, utils.mute_log.MuteLog.init(), path));
    const message = utils.errors.lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, message, "ImproperImageHeader") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, path) != null);
}

test "the warnings of a call that works go to the log as ImageMagick's output, and not into what it hands back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var captured = ICapturedLog.init(allocator);
    const log = captured.ilog();

    // The JPEG fixture holds an XMP profile, which ImageMagick warns it cannot check without the XML library it is built without.
    const info = try image_magick.readImageInfo(allocator, log, "../test/test.jpg");
    try std.testing.expectEqualStrings("JPEG", info.format);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr.items, "magick: read the size of ../test/test.jpg: DelegateLibrarySupportNotBuiltIn") != null);
    captured.stderr.clearRetainingCapacity();
    const png_path = try tempFilePath(allocator, tmp_dir, "from-jpeg.png");
    try image_magick.resizeImage(allocator, std.testing.io, log, .{
        .input_path = "../test/test.jpg",
        .output_path = png_path,
        .width = 16,
        .height = 16,
        .exact = false,
        .quality = null,
        .format = "PNG",
    });
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr.items, "magick: resize ../test/test.jpg: DelegateLibrarySupportNotBuiltIn") != null);
    try std.testing.expectEqualStrings("", captured.errors.items);
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
        const missing_path = try tempFilePath(allocator, tmp_dir, "missing.jpg");
        const broken_path = try writeTextFile(allocator, tmp_dir, "broken.png", "not an image");
        const png_path = try tempFilePath(allocator, tmp_dir, "from-jpeg.png");

        const stderr_path = try tempFilePath(allocator, tmp_dir, "stderr.txt");
        const stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{});
        const saved_stderr = std.c.dup(2);
        try std.testing.expect(saved_stderr >= 0);
        try std.testing.expect(std.c.dup2(stderr_file.handle, 2) == 2);
        // Two warnings and two errors.
        const identified = image_magick.readImageInfo(allocator, log, "../test/test.jpg");
        const converted = image_magick.resizeImage(allocator, std.testing.io, log, .{
            .input_path = "../test/test.jpg",
            .output_path = png_path,
            .width = 16,
            .height = 16,
            .exact = false,
            .quality = null,
            .format = "PNG",
        });
        const missing = image_magick.readImageInfo(allocator, log, missing_path);
        const broken = image_magick.readExif(allocator, log, broken_path);
        const restored = std.c.dup2(saved_stderr, 2);
        _ = std.c.close(saved_stderr);
        stderr_file.close(std.testing.io);
        try std.testing.expect(restored == 2);

        _ = try identified;
        try converted;
        try std.testing.expectError(error.Thrown, missing);
        try std.testing.expectError(error.Thrown, broken);
        const printed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .unlimited);
        try std.testing.expectEqualStrings("", printed);
    }
};

comptime {
    if (builtin.os.tag != .windows) {
        _ = StandardErrorTests;
    }
}

test "a WebP picture is read, and written, through the WebP delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const log = utils.mute_log.MuteLog.init();
    const read = try image_magick.readImageInfo(allocator, log, "../test/test.webp");
    try std.testing.expectEqualStrings("WEBP", read.format);
    try std.testing.expect(read.width > 0 and read.height > 0);

    // The app turns a picture into a JPEG of another size, and may write WebP.
    const jpeg_path = try tempFilePath(allocator, tmp_dir, "from-webp.jpg");
    try image_magick.resizeImage(allocator, std.testing.io, log, .{
        .input_path = "../test/test.webp",
        .output_path = jpeg_path,
        .width = 8,
        .height = 8,
        .exact = false,
        .quality = 80,
        .format = "JPEG",
    });
    const webp_path = try tempFilePath(allocator, tmp_dir, "written.webp");
    try image_magick.resizeImage(allocator, std.testing.io, log, .{
        .input_path = jpeg_path,
        .output_path = webp_path,
        .width = 8,
        .height = null,
        .exact = false,
        .quality = 80,
        .format = "WEBP",
    });
    try std.testing.expectEqualStrings("WEBP", (try image_magick.readImageInfo(allocator, log, webp_path)).format);
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
// Asks ImageMagick for the size of the input and expects the call to fail, because the security policy refuses the read.
//
fn expectReadRefused(allocator: std.mem.Allocator, input: []const u8) !void {
    const result = image_magick.readImageInfo(allocator, utils.mute_log.MuteLog.init(), input);
    if (result) |info| {
        std.debug.print("The read of {s} was not refused: {d}x{d} {s}\n", .{ input, info.width, info.height, info.format });
        return error.TestUnexpectedResult;
    }
    else |err| {
        try std.testing.expectEqual(error.Thrown, err);
    }
}

//
// Asks ImageMagick for the size of the input and expects it to be read, with a size above zero.
//
fn expectReadAllowed(allocator: std.mem.Allocator, input: []const u8) !void {
    errdefer std.debug.print("The read of {s} failed: {s}\n", .{ input, utils.errors.lastErrorMessage() });
    const info = try image_magick.readImageInfo(allocator, utils.mute_log.MuteLog.init(), input);
    try std.testing.expect(info.width > 0);
    try std.testing.expect(info.height > 0);
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
    const image_path = try makeImage(allocator, tmp_dir, "listed.png", 6, 4, color_a, "PNG");
    const list_path = try writeTextFile(allocator, tmp_dir, "list.txt", image_path);
    try expectReadRefused(allocator, try std.fmt.allocPrint(allocator, "@{s}", .{list_path}));
}

test "once any function has run, the security policy denies every coder that reaches outside the file, and every delegate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try image_magick.readImageInfo(arena.allocator(), utils.mute_log.MuteLog.init(), "../test/test.png");
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

test "with the security policy in place, every image type the import accepts that has a fixture still reads, and so does a PSD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try expectReadAllowed(allocator, "../test/test.jpg");
    try expectReadAllowed(allocator, "../test/multiple-files/test-1.jpeg");
    try expectReadAllowed(allocator, "../test/test.png");
    try expectReadAllowed(allocator, "../test/test.webp");
    try expectReadAllowed(allocator, "../apps/photosphere/icons/photosphere.ico");

    // The repository has no GIF, PSD, TIFF or BMP picture, so each is made from the JPEG fixture and read back.
    const IMade = struct {
        name: []const u8,
        format: []const u8,
    };
    const made = [_]IMade{
        .{
            .name = "made.gif",
            .format = "GIF",
        },
        .{
            .name = "made.psd",
            .format = "PSD",
        },
        .{
            .name = "made.bmp",
            .format = "BMP",
        },
    };
    // The library is built without libtiff, so it writes no TIFF, and says so. (The `magick` program, given a path ending in .tif,
    // wrote the picture in the format it was read in instead, so a TIFF made that way was a JPEG.)
    try std.testing.expectError(error.Thrown, image_magick.resizeImage(allocator, std.testing.io, utils.mute_log.MuteLog.init(), .{
        .input_path = "../test/test.jpg",
        .output_path = try tempFilePath(allocator, tmp_dir, "made.tif"),
        .width = 16,
        .height = 16,
        .exact = false,
        .quality = null,
        .format = "TIFF",
    }));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "NoEncodeDelegateForThisImageFormat `TIFF'") != null);
    for (made) |entry| {
        errdefer std.debug.print("{s}: {s}\n", .{ entry.name, utils.errors.lastErrorMessage() });
        const path = try tempFilePath(allocator, tmp_dir, entry.name);
        try image_magick.resizeImage(allocator, std.testing.io, utils.mute_log.MuteLog.init(), .{
            .input_path = "../test/test.jpg",
            .output_path = path,
            .width = 16,
            .height = 16,
            .exact = false,
            .quality = null,
            .format = entry.format,
        });
        try expectReadAllowed(allocator, path);
        try std.testing.expectEqualStrings(entry.format, (try image_magick.readImageInfo(allocator, utils.mute_log.MuteLog.init(), path)).format);
    }
}

//
// What one thread of the several-threads test found, which only that thread writes and the test reads once it has ended.
//
const IThreadOutcome = struct {
    // How many rounds every call of the thread gave its own answer.
    correct_rounds: usize = 0,

    // The first thing that went wrong, or null.
    failure: ?[]const u8 = null,
};

// How many threads the several-threads test calls ImageMagick on at once.
const thread_count = 8;

//
// What one thread of the several-threads test does, with an allocator, an Io and a log of its own, and with no setup: every function
// here, on a picture of a size and colour only this thread uses, checking each answer is this thread's own.
//
fn callEveryFunction(directory: []const u8, index: usize, outcome: *IThreadOutcome) void {
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    const io = threaded.io();
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena.deinit();
        const allocator = arena.allocator();
        var captured = ICapturedLog.init(allocator);
        const log = captured.ilog();
        callEveryFunctionOnce(allocator, io, log, directory, index, round) catch |err| {
            outcome.failure = std.fmt.allocPrint(std.heap.page_allocator, "thread {d}, round {d}: {s}: {s}", .{ index, round, @errorName(err), utils.errors.lastErrorMessage() }) catch @panic("out of memory");
            return;
        };
        outcome.correct_rounds += 1;
    }
}

//
// One round of callEveryFunction.
//
fn callEveryFunctionOnce(allocator: std.mem.Allocator, io: std.Io, log: utils.log.ILog, directory: []const u8, index: usize, round: usize) !void {
    const width = 10 + index;
    const height = 4 + index;
    const color = [3]u8{ @intCast(index * 30), 255 - @as(u8, @intCast(index * 30)), 128 };
    const bytes = try allocator.alloc(u8, width * height * 3);
    for (0..width * height) |pixel| {
        @memcpy(bytes[pixel * 3 ..][0..3], &color);
    }
    const source = try std.fmt.allocPrint(allocator, "{s}/source-{d}-{d}.png", .{ directory, index, round });
    try image_magick.writeRgbImage(allocator, io, log, .{
        .width = width,
        .height = height,
        .bytes = bytes,
    }, .{
        .source = "the thread's picture",
        .output_path = source,
        .turn = .{},
        .format = "PNG",
        .quality = 90,
    });
    const info = try image_magick.readImageInfo(allocator, log, source);
    if (info.width != width or info.height != height or !std.mem.eql(u8, info.format, "PNG")) {
        return error.TheSizeIsAnotherThreads;
    }
    if ((try image_magick.readExif(allocator, log, source)).count() != 0) {
        return error.TheExifIsAnotherThreads;
    }
    if (!std.mem.eql(u8, &(try image_magick.dominantColor(allocator, log, source)), &color)) {
        return error.TheColourIsAnotherThreads;
    }
    const resized = try std.fmt.allocPrint(allocator, "{s}/resized-{d}-{d}.png", .{ directory, index, round });
    try image_magick.resizeImage(allocator, io, log, .{
        .input_path = source,
        .output_path = resized,
        .width = width * 2,
        .height = null,
        .exact = false,
        .quality = null,
        .format = "PNG",
    });
    const resized_info = try image_magick.readImageInfo(allocator, log, resized);
    if (resized_info.width != width * 2 or resized_info.height != height * 2) {
        return error.TheResizeIsAnotherThreads;
    }
    const turned = try std.fmt.allocPrint(allocator, "{s}/turned-{d}-{d}.png", .{ directory, index, round });
    try image_magick.transformImage(allocator, io, log, .{
        .input_path = source,
        .output_path = turned,
        .turn = .{
            .rotate_degrees = 90,
        },
        .format = "PNG",
    });
    const turned_info = try image_magick.readImageInfo(allocator, log, turned);
    if (turned_info.width != height or turned_info.height != width) {
        return error.TheTurnIsAnotherThreads;
    }
}

test "every function works first on a thread of its own with no setup, and on several threads at once, each giving its own answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const directory = try tempFilePath(allocator, tmp_dir, "");
    var outcomes: [thread_count]IThreadOutcome = @splat(.{});
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &outcomes, 0..) |*thread, *outcome, index| {
        thread.* = try std.Thread.spawn(.{}, callEveryFunction, .{ directory, index, outcome });
    }
    for (threads) |thread| {
        thread.join();
    }
    for (outcomes) |outcome| {
        if (outcome.failure) |failure| {
            std.debug.print("A thread failed: {s}\n", .{failure});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(@as(usize, 10), outcome.correct_rounds);
    }
}

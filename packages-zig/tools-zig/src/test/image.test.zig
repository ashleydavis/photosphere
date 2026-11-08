const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const MemoryLog = @import("utils-zig").memory_log.MemoryLog;
const media_tools = @import("media-tools-zig");
const Image = tools.Image;
const magick = media_tools.image_magick.c;
const builtin = @import("builtin");

//
// Generates the same ID every time, so the output paths are known.
//
const FixedUuidGenerator = struct {
    // The ID to generate.
    id: []const u8,

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
        _ = allocator;
        _ = io;
        const self: *FixedUuidGenerator = @ptrCast(@alignCast(ptr));
        return self.id;
    }
};

//
// Reads an image with ImageMagick's own C interface, which the tests measure the files Image wrote with. The caller frees it.
//
fn readWithImageMagick(allocator: std.mem.Allocator, filePath: []const u8) ![*c]magick.Image {
    try media_tools.image_magick.check();
    const image_info = magick.AcquireImageInfo();
    defer _ = magick.DestroyImageInfo(image_info);
    _ = magick.CopyMagickString(&@as(*magick.ImageInfo, image_info).filename, (try allocator.dupeZ(u8, filePath)).ptr, image_info.*.filename.len);
    const exception = magick.AcquireExceptionInfo();
    defer _ = magick.DestroyExceptionInfo(exception);
    return magick.ReadImage(image_info, exception) orelse error.TestUnexpectedResult;
}

//
// Reads the width, height, format and JPEG quality of an image file with ImageMagick, as "<w> <h> <format> <quality>" (what
// `identify -format "%w %h %m %Q"` prints).
//
fn describeImage(allocator: std.mem.Allocator, filePath: []const u8) ![]const u8 {
    const image = try readWithImageMagick(allocator, filePath);
    defer _ = magick.DestroyImageList(image);
    return std.fmt.allocPrint(allocator, "{d} {d} {s} {d}", .{ image.*.columns, image.*.rows, std.mem.sliceTo(&@as(*magick.Image, image).magick, 0), image.*.quality });
}

//
// The colour of one pixel of an image file, read with ImageMagick, as eight bit red, green and blue.
//
fn pixelAt(allocator: std.mem.Allocator, filePath: []const u8, x: isize, y: isize) ![3]f64 {
    const image = try readWithImageMagick(allocator, filePath);
    defer _ = magick.DestroyImageList(image);
    const exception = magick.AcquireExceptionInfo();
    defer _ = magick.DestroyExceptionInfo(exception);
    var pixel: magick.PixelInfo = undefined;
    if (magick.GetOneVirtualPixelInfo(image, magick.UndefinedVirtualPixelMethod, x, y, &pixel, exception) != magick.MagickTrue) {
        return error.TestUnexpectedResult;
    }
    const range: f64 = magick.QuantumRange;
    return .{ @as(f64, pixel.red) / range * 255, @as(f64, pixel.green) / range * 255, @as(f64, pixel.blue) / range * 255 };
}

//
// The mean colour of every pixel of an image file, read with ImageMagick, as eight bit red, green and blue.
//
fn meanColor(allocator: std.mem.Allocator, filePath: []const u8) ![3]f64 {
    const image = try readWithImageMagick(allocator, filePath);
    defer _ = magick.DestroyImageList(image);
    const pixels = try allocator.alloc(u8, image.*.columns * image.*.rows * 3);
    const exception = magick.AcquireExceptionInfo();
    defer _ = magick.DestroyExceptionInfo(exception);
    if (magick.ExportImagePixels(image, 0, 0, image.*.columns, image.*.rows, "RGB", magick.CharPixel, pixels.ptr, exception) != magick.MagickTrue) {
        return error.TestUnexpectedResult;
    }
    var sums = [3]f64{ 0, 0, 0 };
    for (0..pixels.len / 3) |index| {
        for (&sums, 0..) |*sum, channel| {
            sum.* += @floatFromInt(pixels[index * 3 + channel]);
        }
    }
    const count: f64 = @floatFromInt(pixels.len / 3);
    return .{ sums[0] / count, sums[1] / count, sums[2] / count };
}

//
// Expects two colours to be the same, give or take the tolerance in each of red, green and blue.
//
fn expectColorNear(expected: [3]f64, actual: [3]f64, tolerance: f64) !void {
    for (expected, actual) |expected_component, actual_component| {
        if (@abs(expected_component - actual_component) > tolerance) {
            std.debug.print("expected the colour {any}, found {any}\n", .{ expected, actual });
            return error.TestUnexpectedResult;
        }
    }
}

//
// Creates a temporary directory for a test.
//
fn makeTempDir(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    std.testing.io.random(&random_bytes);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/image-test-{s}-{x}", .{ name, std.mem.readInt(u64, &random_bytes, .little) });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, path, allocator);
}


//
// An image file and what Image's getInfo reads from it.
//
const IExpectedImageInfo = struct {
    // The file.
    filePath: []const u8,

    // The width, in pixels.
    width: f64,

    // The height, in pixels.
    height: f64,

    // The time value of the file's EXIF DateTimeOriginal, or null when the
    // file has none, so createdAt stays undefined.
    createdAt: ?f64,
};

test "getInfo reads the dimensions and the date of an image" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The sizes are those in the files' headers (the JPEG frame header, the PNG IHDR chunk and the WebP VP8 frame).
    // test.jpg has an EXIF DateTimeOriginal of "2025:05:27 09:54:16", so createdAt is set to
    // `new Date("2025-05-27 09:54:16")` (the date colons are rewritten as dashes and the rest is handed to
    // `new Date`). Node and Bun read that date-time with no zone offset as local time, which measured
    // 1748303656000 on a machine at UTC+10:00; js-date.zig assumes local time is UTC (a documented deviation
    // from JavaScript), so the value read here is the UTC reading, ten hours later. The PNG and WebP have no
    // EXIF, so createdAt stays undefined.
    const cases = [_]IExpectedImageInfo{
        .{
            .filePath = "../test/test.jpg",
            .width = 2560,
            .height = 1920,
            .createdAt = 1748339656000,
        },
        .{
            .filePath = "../test/test.png",
            .width = 100,
            .height = 90,
            .createdAt = null,
        },
        .{
            .filePath = "../test/test.webp",
            .width = 100,
            .height = 80,
            .createdAt = null,
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        var image = Image.init(expected.filePath);
        const info = try image.getInfo(allocator, std.testing.io, log);
        try std.testing.expectEqual(expected.width, info.dimensions.width);
        try std.testing.expectEqual(expected.height, info.dimensions.height);
        try std.testing.expectEqual(expected.createdAt, info.createdAt);
        try std.testing.expectEqualStrings(expected.filePath, info.filePath);
        try std.testing.expectEqual(@as(?bool, false), info.hasAudio);
        try std.testing.expect(info.duration == null);
        try std.testing.expect(info.fps == null);
        try std.testing.expect(info.bitrate == null);

        // The information is read once.
        try std.testing.expectEqual(info.dimensions, (try image.getDimensions(allocator, std.testing.io, log)));
    }
}


test "getExifData reads the tags of a real image" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var image = Image.init("../test/test.jpg");
    const exifData = try image.getExifData(allocator, std.testing.io, log);
    try std.testing.expectEqualStrings("Google", exifData.get("Make").?);
    try std.testing.expectEqualStrings("Pixel 6", exifData.get("Model").?);
    try std.testing.expectEqualStrings("2025:05:27 09:54:16", exifData.get("DateTimeOriginal").?);

    // The DateTimeOriginal is what getInfo turns into createdAt, with the colons of the date replaced by dashes.
    // That is a real date: "2025-05-27 09:54:16" is the local time, which the Date
    // Time String Format of ECMA-262 allows with a space where the ISO form has a "T". js_date.parseDate reads that
    // form too, so it reads the UTC reading, which is the same value the getInfo test above asserts.
    var withDate = Image.init("../test/test.jpg");
    const info = try withDate.getInfo(allocator, std.testing.io, log);
    try std.testing.expectEqual(@as(f64, 1748339656000), info.createdAt.?);
    try std.testing.expectEqualStrings("2025-05-27 09:54:16", try tools.image.exifDateToDashes(allocator, exifData.get("DateTimeOriginal").?));
}

test "getInfo fails for a file that does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var image = Image.init("../test/no-such-file.jpg");
    try std.testing.expectError(error.Thrown, image.getInfo(arena.allocator(), std.testing.io, log));
    try std.testing.expectEqualStrings("File not found: ../test/no-such-file.jpg", utils.errors.lastErrorMessage());
}

test "resize writes the image the resize command writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "resize");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };

    var image = Image.init("../test/test.jpg");
    const outputPath = try image.resize(allocator, std.testing.io, log, .{ .width = 1333, .height = 1000, .quality = 95, .format = "jpeg", .ext = "jpg" }, tempDir, generator.uuidGenerator());

    // The path is the temp directory joined with temp_resize_ and the generated id, then a dot and the extension.
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_fixed-id.jpg" }), outputPath);

    // 2560x1920 fitted inside 1333x1000 keeping the aspect ratio is 1333x1000, at the quality asked for.
    try std.testing.expectEqualStrings("1333 1000 JPEG 95", try describeImage(allocator, outputPath));

    // The strip drops the EXIF of the original, which has some.
    try std.testing.expect((try image.getExifData(allocator, std.testing.io, log)).count() > 0);
    var resized = Image.init(outputPath);
    try std.testing.expectEqual(@as(usize, 0), (try resized.getExifData(allocator, std.testing.io, log)).count());

    // It is the same picture, smaller: its mean colour is the original's.
    try expectColorNear(try meanColor(allocator, "../test/test.jpg"), try meanColor(allocator, outputPath), 2);

    // A second resize to the same path is refused.
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, .{ .width = 10, .height = 10, .quality = 95, .format = "jpeg", .ext = "jpg" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{outputPath}), utils.errors.lastErrorMessage());
}

test "transform writes the image the transform command writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "transform");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };

    var image = Image.init("../test/test.png");
    const outputPath = try image.transform(allocator, std.testing.io, log, .{ .rotate = 90, .flipX = true }, tempDir, generator.uuidGenerator());

    // The path is the temp directory joined with temp_transform_output_, the generated id and .jpg.
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_transform_output_fixed-id.jpg" }), outputPath);

    // The 100x90 PNG turned a quarter turn is 90x100, written as a JPEG because of the extension.
    try std.testing.expectEqualStrings("90 100 JPEG", (try describeImage(allocator, outputPath))[0.."90 100 JPEG".len]);

    // Mirrored left to right and then turned a quarter clockwise, as `-flop -rotate 90` does, the pixel at x,y of the 100x90 original
    // is at 89-y,99-x: each corner of the card's lettering lands in the corner of the turned picture it should.
    const IPoint = struct {
        x: isize,
        y: isize,
    };
    for ([_]IPoint{
        .{
            .x = 10,
            .y = 40,
        },
        .{
            .x = 50,
            .y = 45,
        },
        .{
            .x = 30,
            .y = 50,
        },
        .{
            .x = 70,
            .y = 42,
        },
    }) |point| {
        errdefer std.debug.print("point {d},{d}\n", .{ point.x, point.y });
        try expectColorNear(try pixelAt(allocator, "../test/test.png", point.x, point.y), try pixelAt(allocator, outputPath, 89 - point.y, 99 - point.x), 24);
    }

    // No transformation returns the original.
    try std.testing.expectEqualStrings("../test/test.png", try image.transform(allocator, std.testing.io, log, .{}, tempDir, generator.uuidGenerator()));
}

test "getDominantColor gives the mean colour of the image" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "../test/test.jpg", "../test/test.png" }) |filePath| {
        errdefer std.debug.print("case: {s}\n", .{filePath});
        var image = Image.init(filePath);
        const color = try image.getDominantColor(allocator, std.testing.io, log);

        // Whole numbers, each the image's mean resized to one pixel, which is near the plain mean of all its pixels.
        for (color) |component| {
            try std.testing.expectEqual(@floor(component), component);
        }
        try expectColorNear(try meanColor(allocator, filePath), color, 3);
    }

    // test.png is a flat grey card (204, 204, 204) with darker grey lettering, so its mean is a grey.
    var card = Image.init("../test/test.png");
    const cardColor = try card.getDominantColor(allocator, std.testing.io, log);
    try std.testing.expectEqual(cardColor[0], cardColor[1]);
    try std.testing.expectEqual(cardColor[1], cardColor[2]);
    try std.testing.expect(cardColor[0] > 150 and cardColor[0] < 204);
}

test "every operation fails for a file that does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };
    var image = Image.init("../test/no-such-file.jpg");
    const expectedMessage = "File not found: ../test/no-such-file.jpg";

    try std.testing.expectError(error.Thrown, image.getExifData(allocator, std.testing.io, log));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, .{ .width = 10, .height = 10, .quality = null, .format = null, .ext = "jpg" }, ".", generator.uuidGenerator()));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, std.testing.io, log));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.transform(allocator, std.testing.io, log, .{ .rotate = 90 }, ".", generator.uuidGenerator()));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());
}

test "resize to only a width or only a height keeps the aspect ratio" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "resize-one-side");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var image = Image.init("../test/test.png");

    // The 100x90 PNG to 50 wide is 50x45 (`-resize 50x`), written in the format of the extension (no format given).
    var widthGenerator: FixedUuidGenerator = .{ .id = "width" };
    const widthPath = try image.resize(allocator, std.testing.io, log, .{ .width = 50, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, widthGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45 PNG", (try describeImage(allocator, widthPath))[0.."50 45 PNG".len]);

    // To 45 high is 50x45 too (`-resize x45`).
    var heightGenerator: FixedUuidGenerator = .{ .id = "height" };
    const heightPath = try image.resize(allocator, std.testing.io, log, .{ .width = 0, .height = 45, .quality = null, .format = null, .ext = "png" }, tempDir, heightGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45 PNG", (try describeImage(allocator, heightPath))[0.."50 45 PNG".len]);

    // Without keeping the aspect ratio both sides are what was asked for (`-resize 20x30!`).
    var exactGenerator: FixedUuidGenerator = .{ .id = "exact" };
    const exactPath = try image.resize(allocator, std.testing.io, log, .{ .width = 20, .height = 30, .quality = null, .format = null, .maintainAspectRatio = false, .ext = "png" }, tempDir, exactGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("20 30 PNG", (try describeImage(allocator, exactPath))[0.."20 30 PNG".len]);
}

test "resize refuses a quality outside 0 to 100" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "resize-quality");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "quality" };
    var image = Image.init("../test/test.png");
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, .{ .width = 10, .height = 0, .quality = 101, .format = null, .ext = "jpg" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings("Quality must be between 0 and 100", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, .{ .width = 10, .height = 0, .quality = -1, .format = null, .ext = "jpg" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings("Quality must be between 0 and 100", utils.errors.lastErrorMessage());
}

test "resize of an animation returns its first frame" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "resize-animation");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A two frame GIF, red then blue, made with ImageMagick's C interface, resized to a PNG of its first frame.
    const animationPath = try std.fs.path.join(allocator, &.{ tempDir, "animation.gif" });
    try media_tools.image_magick.check();
    const exception = magick.AcquireExceptionInfo();
    defer _ = magick.DestroyExceptionInfo(exception);
    const red = [_]u8{ 255, 0, 0 } ** (20 * 10);
    const blue = [_]u8{ 0, 0, 255 } ** (20 * 10);
    var frames = magick.ConstituteImage(20, 10, "RGB", magick.CharPixel, &red, exception);
    magick.AppendImageToList(&frames, magick.ConstituteImage(20, 10, "RGB", magick.CharPixel, &blue, exception));
    defer _ = magick.DestroyImageList(frames);
    const image_info = magick.AcquireImageInfo();
    defer _ = magick.DestroyImageInfo(image_info);
    try std.testing.expectEqual(@as(magick.MagickBooleanType, magick.MagickTrue), magick.WriteImages(image_info, frames, (try allocator.dupeZ(u8, animationPath)).ptr, exception));
    var generator: FixedUuidGenerator = .{ .id = "animation" };
    var image = Image.init(animationPath);
    const outputPath = try image.resize(allocator, std.testing.io, log, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, generator.uuidGenerator());
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_animation.png" }), outputPath);
    try std.testing.expectEqualStrings("10 5 PNG", (try describeImage(allocator, outputPath))[0.."10 5 PNG".len]);
    try expectColorNear(.{ 255, 0, 0 }, try pixelAt(allocator, outputPath, 5, 2), 1);

    // A resize whose first frame path is taken is refused.
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{outputPath}), utils.errors.lastErrorMessage());
}

test "resize fails loudly when the resized image cannot be written" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "resize-nothing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // An output directory that does not exist: the write fails and nothing is written.
    const missingDir = try std.fs.path.join(allocator, &.{ tempDir, "missing" });
    var generator: FixedUuidGenerator = .{ .id = "nothing" };
    var image = Image.init("../test/test.png");

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, memory.log, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, missingDir, generator.uuidGenerator()));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to resize ../test/test.png into ") != null);
}

test "getDominantColor fails for a file ImageMagick cannot read" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var image = Image.init("../test/demo-news.yaml");

    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, std.testing.io, memory.log));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to read the mean colour of ../test/demo-news.yaml") != null);
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to extract dominant color: Error: "));
}

test "getExifData fails for a file ImageMagick cannot read" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var image = Image.init("../test/demo-news.yaml");

    try std.testing.expectError(error.Thrown, image.getExifData(allocator, std.testing.io, memory.log));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to read the EXIF of ../test/demo-news.yaml") != null);
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get EXIF data: Error: "));
}

test "transform fails loudly when the turned image cannot be written" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try makeTempDir(allocator, "transform-nothing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    const missingDir = try std.fs.path.join(allocator, &.{ tempDir, "missing" });
    var generator: FixedUuidGenerator = .{ .id = "nothing" };
    var image = Image.init("../test/test.png");

    try std.testing.expectError(error.Thrown, image.transform(allocator, std.testing.io, memory.log, .{ .flipX = true }, missingDir, generator.uuidGenerator()));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to turn ../test/test.png into ") != null);

    // A rotation of 0 is no transformation (it is falsy).
    try std.testing.expectEqualStrings("../test/test.png", try image.transform(allocator, std.testing.io, memory.log, .{ .rotate = 0 }, tempDir, generator.uuidGenerator()));
}

test "exifDateToDashes turns the date of an EXIF date into dashes and leaves anything else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("2023-12-25 14:30:00", try tools.image.exifDateToDashes(allocator, "2023:12:25 14:30:00"));
    try std.testing.expectEqualStrings("2023-12-25", try tools.image.exifDateToDashes(allocator, "2023-12-25"));
    try std.testing.expectEqualStrings("20231225", try tools.image.exifDateToDashes(allocator, "20231225"));
    try std.testing.expectEqualStrings("", try tools.image.exifDateToDashes(allocator, ""));
}


test "every operation works on a file whose name holds $, a backtick and a double quote" {
    // The goal is to show that a path holding a space, `$`, a backtick and `"` reaches ImageMagick unchanged, as the source and as
    // the output. The method is to copy test.jpg under such a name, write every output into a directory whose name holds them too,
    // and check that each operation gives what the same operation gives on test.jpg written to an ordinary path.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    errdefer std.debug.print("The last error: {s}\n", .{utils.errors.lastErrorMessage()});
    const tempDir = try makeTempDir(allocator, "special-file-name");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    // `"` is a reserved character in Windows file names, so it is left out there.
    const specialName = if (builtin.os.tag == .windows) "Trip $5 `a`" else "Trip $5 `a` \"b\"";
    const specialDir = try std.fs.path.join(allocator, &.{ tempDir, "out $x `y`" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, specialDir);
    const specialPath = try std.fs.path.join(allocator, &.{ tempDir, specialName ++ ".jpg" });
    try std.Io.Dir.cwd().copyFile("../test/test.jpg", std.Io.Dir.cwd(), specialPath, std.testing.io, .{});

    var special = Image.init(specialPath);
    var plain = Image.init("../test/test.jpg");

    const specialInfo = try special.getInfo(allocator, std.testing.io, log);
    const plainInfo = try plain.getInfo(allocator, std.testing.io, log);
    try std.testing.expectEqual(plainInfo.dimensions, specialInfo.dimensions);
    try std.testing.expectEqual(plainInfo.createdAt, specialInfo.createdAt);

    const specialExif = try special.getExifData(allocator, std.testing.io, log);
    const plainExif = try plain.getExifData(allocator, std.testing.io, log);
    try std.testing.expect(plainExif.count() > 0);
    try std.testing.expectEqual(plainExif.count(), specialExif.count());
    var plainEntries = plainExif.iterator();
    while (plainEntries.next()) |entry| {
        try std.testing.expectEqualStrings(entry.value_ptr.*, specialExif.get(entry.key_ptr.*).?);
    }

    // With a format, the output goes to ImageMagick as one "jpeg:<path>" argument; without one, as the path alone.
    for ([_]?[]const u8{ "jpeg", null }) |format| {
        const options: tools.types.ResizeOptions = .{
            .width = 100,
            .height = 0,
            .quality = 90,
            .format = format,
            .ext = "jpg",
        };
        var specialGenerator: FixedUuidGenerator = .{ .id = if (format == null) "special-plain" else "special-format" };
        var plainGenerator: FixedUuidGenerator = .{ .id = if (format == null) "plain-plain" else "plain-format" };
        const specialResized = try special.resize(allocator, std.testing.io, log, options, specialDir, specialGenerator.uuidGenerator());
        const plainResized = try plain.resize(allocator, std.testing.io, log, options, tempDir, plainGenerator.uuidGenerator());
        try std.testing.expect(std.mem.startsWith(u8, specialResized, specialDir));
        try std.testing.expectEqualStrings(try describeImage(allocator, plainResized), try describeImage(allocator, specialResized));
    }

    var specialTransformGenerator: FixedUuidGenerator = .{ .id = "special-transform" };
    var plainTransformGenerator: FixedUuidGenerator = .{ .id = "plain-transform" };
    const specialTransformed = try special.transform(allocator, std.testing.io, log, .{ .rotate = 90 }, specialDir, specialTransformGenerator.uuidGenerator());
    const plainTransformed = try plain.transform(allocator, std.testing.io, log, .{ .rotate = 90 }, tempDir, plainTransformGenerator.uuidGenerator());
    try std.testing.expect(std.mem.startsWith(u8, specialTransformed, specialDir));
    try std.testing.expectEqualStrings(try describeImage(allocator, plainTransformed), try describeImage(allocator, specialTransformed));

    try std.testing.expectEqual(try plain.getDominantColor(allocator, std.testing.io, log), try special.getDominantColor(allocator, std.testing.io, log));
}

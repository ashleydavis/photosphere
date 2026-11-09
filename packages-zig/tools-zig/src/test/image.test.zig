const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const MemoryLog = @import("utils-zig").memory_log.MemoryLog;
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const Image = tools.Image;
const MediaTools = media_tools.MediaTools;
const builtin = @import("builtin");
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;

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
// Runs an ImageMagick tool ("convert" or "identify") with the ImageMagick built into the program, the way Image runs it
// (`magick` and `magick identify`), and returns what it printed. The tests use it to measure the files Image wrote, and
// to run the commands Image builds so their output is the expected output. It runs the same ImageMagick as Image, so the
// expected bytes come from the same version of it.
//
fn runImageMagick(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner, tool: []const u8, arguments: []const []const u8) ![]const u8 {
    var magickArguments: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, tool, "identify")) {
        try magickArguments.append(allocator, "identify");
    }
    try magickArguments.appendSlice(allocator, arguments);
    const result = try runner.run(runner.context, std.testing.io, log, allocator, "magick", magickArguments.items);
    if (result.exit_code != 0) {
        std.debug.print("ImageMagick failed with exit code {d}:\n{s}\n", .{ result.exit_code, result.output });
        return error.TestUnexpectedResult;
    }
    return std.mem.trimEnd(u8, result.output, "\r\n");
}

//
// Reads the width, height, format and JPEG quality of an image file with ImageMagick, as "<w> <h> <format> <quality>".
//
fn describeImage(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner, filePath: []const u8) ![]const u8 {
    return runImageMagick(log, allocator, runner, "identify", &.{ "-format", "%w %h %m %Q", filePath });
}

//
// Reads a file.
//
fn readFile(allocator: std.mem.Allocator, filePath: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, filePath, allocator, .unlimited);
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
// The sRGB ICC profile ImageMagick ships, which the build embeds for Image.resize, relative to the directory the tests run in
// (packages-zig).
//
const srgb_profile_path = "../third-party/imagemagick/vendor/imagemagick/config/sRGB.icm";

//
// Reads the mean colour of an image file with ImageMagick, as its red, green and blue numbers from 0 to 255, rounded. The numbers are
// the ones in the file, whatever colour profile it has.
//
fn meanColour(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner, filePath: []const u8) ![3]f64 {
    const printed = try runImageMagick(log, allocator, runner, "convert", &.{ filePath, "-format", "%[fx:round(mean.r*255)],%[fx:round(mean.g*255)],%[fx:round(mean.b*255)]", "info:" });
    var components = std.mem.splitScalar(u8, printed, ',');
    var colour: [3]f64 = undefined;
    for (&colour) |*component| {
        component.* = try std.fmt.parseFloat(f64, components.next() orelse return error.TestUnexpectedResult);
    }
    if (components.next() != null) {
        return error.TestUnexpectedResult;
    }
    return colour;
}

//
// Fails a test that needs ImageMagick, loudly, when the ImageMagick built into the program does not run.
//
fn requireImageMagick(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner) !void {
    if (!(try Image.verifyImageMagick(allocator, std.testing.io, log, runner)).available) {
        std.debug.print("This test needs the ImageMagick built into the program, which did not run.\n", .{});
        return error.RequiredToolsMissing;
    }
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
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);

    // The sizes are those in the files' headers (the JPEG frame header, the PNG IHDR chunk, the WebP VP8 frame, the GIF
    // image descriptor and the BMP info header).
    // test.jpg has an EXIF DateTimeOriginal of "2025:05:27 09:54:16", so createdAt is set to
    // `new Date("2025-05-27 09:54:16")` (the date colons are rewritten as dashes and the rest is handed to
    // `new Date`). Node and Bun read that date-time with no zone offset as local time, which measured
    // 1748303656000 on a machine at UTC+10:00; js-date.zig assumes local time is UTC (a documented deviation
    // from JavaScript), so the value read here is the UTC reading, ten hours later. The PNG, WebP, GIF and BMP have no
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
        .{
            .filePath = "../test/test.gif",
            .width = 16,
            .height = 12,
            .createdAt = null,
        },
        .{
            .filePath = "../test/test.bmp",
            .width = 16,
            .height = 12,
            .createdAt = null,
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        var image = Image.init(expected.filePath);
        const info = try image.getInfo(allocator, std.testing.io, log, runner);
        try std.testing.expectEqual(expected.width, info.dimensions.width);
        try std.testing.expectEqual(expected.height, info.dimensions.height);
        try std.testing.expectEqual(expected.createdAt, info.createdAt);
        try std.testing.expectEqualStrings(expected.filePath, info.filePath);
        try std.testing.expectEqual(@as(?bool, false), info.hasAudio);
        try std.testing.expect(info.duration == null);
        try std.testing.expect(info.fps == null);
        try std.testing.expect(info.bitrate == null);

        // The information is read once.
        try std.testing.expectEqual(info.dimensions, (try image.getDimensions(allocator, std.testing.io, log, runner)));
    }
}

test "resize refuses when the second output path is already taken" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-second-output");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "second" };
    var image = Image.init("../test/test.png");

    // The second output path Image.resize checks is <base>-0.<ext>, the one a multi-frame image is written to.
    const secondOutputPath = try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_second-0.png" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = secondOutputPath, .data = "already here" });

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png", .transformation = null }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{secondOutputPath}), utils.errors.lastErrorMessage());
}

test "getExifData reads the tags of a real image" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);

    var image = Image.init("../test/test.jpg");
    const exifData = try image.getExifData(allocator, std.testing.io, log, runner);
    try std.testing.expectEqualStrings("Google", exifData.get("Make").?);
    try std.testing.expectEqualStrings("Pixel 6", exifData.get("Model").?);
    try std.testing.expectEqualStrings("2025:05:27 09:54:16", exifData.get("DateTimeOriginal").?);

    // The DateTimeOriginal is what getInfo turns into createdAt, with the colons of the date replaced by dashes.
    // That is a real date: "2025-05-27 09:54:16" is the local time, which the Date
    // Time String Format of ECMA-262 allows with a space where the ISO form has a "T". js_date.parseDate reads that
    // form too, so it reads the UTC reading, which is the same value the getInfo test above asserts.
    var withDate = Image.init("../test/test.jpg");
    const info = try withDate.getInfo(allocator, std.testing.io, log, runner);
    try std.testing.expectEqual(@as(f64, 1748339656000), info.createdAt.?);
    try std.testing.expectEqualStrings("2025-05-27 09:54:16", try tools.image.exifDateToDashes(allocator, exifData.get("DateTimeOriginal").?));
}

test "getInfo fails for a file that does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    var image = Image.init("../test/no-such-file.jpg");
    try std.testing.expectError(error.Thrown, image.getInfo(arena.allocator(), std.testing.io, log, runner));
    try std.testing.expectEqualStrings("File not found: ../test/no-such-file.jpg", utils.errors.lastErrorMessage());
}

test "resize writes the image the resize command writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };

    var image = Image.init("../test/test.jpg");
    const outputPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 1333, .height = 1000, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator());

    // The path is the temp directory joined with temp_resize_ and the generated id, then a dot and the extension.
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_fixed-id.jpg" }), outputPath);

    // 2560x1920 fitted inside 1333x1000 keeping the aspect ratio is 1333x1000, at the quality asked for.
    try std.testing.expectEqualStrings("1333 1000 JPEG 95", try describeImage(log, allocator, runner, outputPath));

    // -strip drops the EXIF of the original.
    try std.testing.expectEqualStrings("", try runImageMagick(log, allocator, runner, "identify", &.{ "-format", "%[EXIF:*]", outputPath }));

    // The sRGB profile written for the command is removed after it.
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_fixed-id.icc" })));

    // The same bytes as the command built: `<convert> "<file>" -resize <w>x<h> -profile <sRGB profile> -strip -quality <q> jpeg:"<output>"`,
    // with the sRGB profile ImageMagick ships, which is the one the build embeds.
    const referencePath = try std.fs.path.join(allocator, &.{ tempDir, "reference.jpg" });
    _ = try runImageMagick(log, allocator, runner, "convert", &.{ "../test/test.jpg", "-resize", "1333x1000", "-profile", srgb_profile_path, "-strip", "-quality", "95", try std.mem.concat(allocator, u8, &.{ "jpeg:", referencePath }) });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), try readFile(allocator, outputPath)));

    // A second resize to the same path is refused.
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 10, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{outputPath}), utils.errors.lastErrorMessage());
}

test "resize converts a Display P3 picture into sRGB, so its colours survive the strip" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-display-p3");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A flat picture tagged with a Display P3 profile, as an iPhone writes its photos, from scripts/make-format-test-images.sh.
    // The built-in ImageMagick's security policy lets it read only JPEG, PNG, WebP, GIF and BMP pictures, so the picture is made
    // by that script rather than drawn here.
    const sourcePath = "../test/formats/79x45-display-p3.jpg";
    if (!node_utils.fs.pathExists(std.testing.io, sourcePath)) {
        std.debug.print("{s} is missing: run bash scripts/make-format-test-images.sh\n", .{sourcePath});
        return error.FormatTestImageMissing;
    }

    // Its colour in sRGB: the picture converted from its own profile into sRGB with the sRGB profile ImageMagick ships.
    const srgbPath = try std.fs.path.join(allocator, &.{ tempDir, "srgb.jpg" });
    _ = try runImageMagick(log, allocator, runner, "convert", &.{ sourcePath, "-profile", srgb_profile_path, "-quality", "100", srgbPath });
    const srgbColour = try meanColour(log, allocator, runner, srgbPath);

    // The picture holds the colour's Display P3 numbers, which are not its sRGB numbers: read as sRGB, as every viewer reads a
    // picture with no profile, they are another colour. A resize that only stripped the profile wrote these numbers.
    const sourceColour = try meanColour(log, allocator, runner, sourcePath);
    try std.testing.expect(@abs(sourceColour[0] - srgbColour[0]) > 5 or @abs(sourceColour[1] - srgbColour[1]) > 5 or @abs(sourceColour[2] - srgbColour[2]) > 5);

    var generator: FixedUuidGenerator = .{ .id = "display-p3" };
    var image = Image.init(sourcePath);
    const outputPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 32, .height = 24, .quality = 90, .format = "jpeg", .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator());

    // The resized copy holds the sRGB numbers, within 3 of each: the sRGB reference was written at quality 100 and the copy at
    // 90, and each JPEG moves a flat colour by a rounding of each 8 bit number.
    const outputColour = try meanColour(log, allocator, runner, outputPath);
    errdefer std.debug.print("Display P3 numbers {any}, sRGB numbers {any}, resized numbers {any}\n", .{ sourceColour, srgbColour, outputColour });
    try std.testing.expect(@abs(outputColour[0] - srgbColour[0]) <= 3);
    try std.testing.expect(@abs(outputColour[1] - srgbColour[1]) <= 3);
    try std.testing.expect(@abs(outputColour[2] - srgbColour[2]) <= 3);
}

test "transform writes the image the transform command writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "transform");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };

    var image = Image.init("../test/test.png");
    const outputPath = try image.transform(allocator, std.testing.io, log, runner, .{ .rotate = 90, .flipX = true }, tempDir, generator.uuidGenerator());

    // The path is the temp directory joined with temp_transform_output_, the generated id and .jpg.
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_transform_output_fixed-id.jpg" }), outputPath);

    // The 100x90 PNG turned a quarter turn is 90x100, written as a JPEG because of the extension.
    try std.testing.expectEqualStrings("90 100 JPEG", (try describeImage(log, allocator, runner, outputPath))[0.."90 100 JPEG".len]);

    // The same bytes as the command built: `<convert> "<file>"  -flop -rotate 90 "<output>"`.
    const referencePath = try std.fs.path.join(allocator, &.{ tempDir, "reference.jpg" });
    _ = try runImageMagick(log, allocator, runner, "convert", &.{ "../test/test.png", "-flop", "-rotate", "90", referencePath });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), try readFile(allocator, outputPath)));

    // No transformation returns the original.
    try std.testing.expectEqualStrings("../test/test.png", try image.transform(allocator, std.testing.io, log, runner, .{}, tempDir, generator.uuidGenerator()));
}

test "resize with a transformation flips and turns the image before it resizes it, as a transform and then a resize would" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-transformed");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A white 40x30 picture with a black 10x10 square in its top left corner, so a flip or a turn shows where the square ends up,
    // from scripts/make-format-test-images.sh: the built-in ImageMagick's security policy lets it draw nothing of its own.
    const sourcePath = "../test/formats/40x30-corner-square.png";
    if (!node_utils.fs.pathExists(std.testing.io, sourcePath)) {
        std.debug.print("{s} is missing: run bash scripts/make-format-test-images.sh\n", .{sourcePath});
        return error.FormatTestImageMissing;
    }

    // Flipped, the square is top right; turned a quarter clockwise after that, it is bottom right of a 30x40 picture, which the
    // resize doubles to 60x80. The policy lets ImageMagick write only JPEG, so the square's middle is near black and the opposite
    // corner near white rather than exactly 0 and 255.
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };
    var image = Image.init(sourcePath);
    const outputPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 60, .height = 80, .quality = 95, .format = "jpeg", .ext = "jpg", .transformation = .{ .flipX = true, .rotate = 90, .changeOrientation = true } }, tempDir, generator.uuidGenerator());
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_fixed-id.jpg" }), outputPath);
    try std.testing.expectEqualStrings("60 80 JPEG", (try describeImage(log, allocator, runner, outputPath))[0.."60 80 JPEG".len]);
    const corners = try runImageMagick(log, allocator, runner, "convert", &.{ outputPath, "-format", "%[fx:int(p{50,70}.r*255)] %[fx:int(p{5,5}.r*255)]", "info:" });
    var cornerValues = std.mem.splitScalar(u8, corners, ' ');
    const squareValue = try std.fmt.parseInt(i32, cornerValues.next().?, 10);
    const oppositeValue = try std.fmt.parseInt(i32, cornerValues.next().?, 10);
    errdefer std.debug.print("square {d}, opposite corner {d}\n", .{ squareValue, oppositeValue });
    try std.testing.expect(squareValue < 16);
    try std.testing.expect(oppositeValue > 239);

    // The same bytes as one command that flips and turns the picture and then resizes it, in that order.
    const referencePath = try std.fs.path.join(allocator, &.{ tempDir, "reference.jpg" });
    _ = try runImageMagick(log, allocator, runner, "convert", &.{ sourcePath, "-flop", "-rotate", "90", "-resize", "60x80", "-profile", srgb_profile_path, "-strip", "-quality", "95", try std.mem.concat(allocator, u8, &.{ "jpeg:", referencePath }) });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), try readFile(allocator, outputPath)));
}

test "getDominantColor gives the color the command prints" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    for ([_][]const u8{ "../test/test.jpg", "../test/test.png" }) |filePath| {
        errdefer std.debug.print("case: {s}\n", .{filePath});
        var image = Image.init(filePath);
        const color = try image.getDominantColor(allocator, std.testing.io, log, runner);

        // The command is `<convert> "<file>" -resize 1x1! -format "%[fx:int(mean.r*255)],..." info:`, split on commas.
        const printed = try runImageMagick(log, allocator, runner, "convert", &.{ filePath, "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" });
        var components = std.mem.splitScalar(u8, printed, ',');
        for (color) |component| {
            try std.testing.expectEqual(try std.fmt.parseFloat(f64, components.next().?), component);
        }
        try std.testing.expect(components.next() == null);
    }

    // test.png is a flat grey card (204, 204, 204) with darker grey lettering, so its mean is a grey.
    var card = Image.init("../test/test.png");
    const cardColor = try card.getDominantColor(allocator, std.testing.io, log, runner);
    try std.testing.expectEqual(cardColor[0], cardColor[1]);
    try std.testing.expectEqual(cardColor[1], cardColor[2]);
    try std.testing.expect(cardColor[0] > 150 and cardColor[0] < 204);
}

test "every operation fails for a file that does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };
    var image = Image.init("../test/no-such-file.jpg");
    const expectedMessage = "File not found: ../test/no-such-file.jpg";

    try std.testing.expectError(error.Thrown, image.getExifData(allocator, std.testing.io, log, runner));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 10, .quality = null, .format = null, .ext = "jpg", .transformation = null }, ".", generator.uuidGenerator()));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, std.testing.io, log, runner));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.transform(allocator, std.testing.io, log, runner, .{ .rotate = 90 }, ".", generator.uuidGenerator()));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());
}

test "resize to only a width or only a height keeps the aspect ratio" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-one-side");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var image = Image.init("../test/test.png");

    // The 100x90 PNG to 50 wide is 50x45 (`-resize 50x`), written in the format of the extension (no format given).
    var widthGenerator: FixedUuidGenerator = .{ .id = "width" };
    const widthPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 50, .height = 0, .quality = null, .format = null, .ext = "jpg", .transformation = null }, tempDir, widthGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45 JPEG", (try describeImage(log, allocator, runner, widthPath))[0.."50 45 JPEG".len]);

    // To 45 high is 50x45 too (`-resize x45`).
    var heightGenerator: FixedUuidGenerator = .{ .id = "height" };
    const heightPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 0, .height = 45, .quality = null, .format = null, .ext = "jpg", .transformation = null }, tempDir, heightGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45 JPEG", (try describeImage(log, allocator, runner, heightPath))[0.."50 45 JPEG".len]);

    // Without keeping the aspect ratio both sides are what was asked for (`-resize 20x30!`).
    var exactGenerator: FixedUuidGenerator = .{ .id = "exact" };
    const exactPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 20, .height = 30, .quality = null, .format = null, .maintainAspectRatio = false, .ext = "jpg", .transformation = null }, tempDir, exactGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("20 30 JPEG", (try describeImage(log, allocator, runner, exactPath))[0.."20 30 JPEG".len]);
}

test "resize refuses a quality outside 0 to 100" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-quality");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    var generator: FixedUuidGenerator = .{ .id = "quality" };
    var image = Image.init("../test/test.png");
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 0, .quality = 101, .format = null, .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings("Quality must be between 0 and 100", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 0, .quality = -1, .format = null, .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings("Quality must be between 0 and 100", utils.errors.lastErrorMessage());
}

test "resize of an animation returns the first frame ImageMagick writes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-animation");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A two frame GIF (a red and a blue frame of 20x10) resized to JPEG is written as <base>-0.jpg and <base>-1.jpg, so
    // the validation moves on to the second output path.
    var generator: FixedUuidGenerator = .{ .id = "animation" };
    var image = Image.init("../test/animation.gif");
    const outputPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator());
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_animation-0.jpg" }), outputPath);

    // A resize whose first frame path is taken is refused.
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "jpg", .transformation = null }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{outputPath}), utils.errors.lastErrorMessage());
}

test "resize fails loudly when ImageMagick writes nothing" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(memory.log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-nothing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A source ImageMagick cannot read: ImageMagick fails and nothing is written. (An output directory that does not exist no longer
    // reaches ImageMagick: resize writes the sRGB profile there first, and fails on that, which the test below covers.)
    var generator: FixedUuidGenerator = .{ .id = "nothing" };
    var image = Image.init("../test/demo-news.yaml");

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, memory.log, runner, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png", .transformation = null }, tempDir, generator.uuidGenerator()));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to execute command: ") != null);

    // The sRGB profile written for the command is removed after it failed too.
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_nothing.icc" })));
}

test "resize fails loudly when the output directory does not exist" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-missing-directory");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    const missingDir = try std.fs.path.join(allocator, &.{ tempDir, "missing" });
    var generator: FixedUuidGenerator = .{ .id = "missing" };
    var image = Image.init("../test/test.png");

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, log, runner, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "jpg", .transformation = null }, missingDir, generator.uuidGenerator()));
    const profilePath = try std.fs.path.join(allocator, &.{ missingDir, "temp_resize_missing.icc" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Failed to write the sRGB colour profile to {s}: FileNotFound", .{profilePath}), utils.errors.lastErrorMessage());
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
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(memory.log, allocator, runner);
    var image = Image.init("../test/demo-news.yaml");

    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, std.testing.io, memory.log, runner));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to execute command: ") != null);
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
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(memory.log, allocator, runner);
    var image = Image.init("../test/demo-news.yaml");

    try std.testing.expectError(error.Thrown, image.getExifData(allocator, std.testing.io, memory.log, runner));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to execute command: ") != null);
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get EXIF data: Error: "));
}

test "transform fails loudly when ImageMagick writes nothing" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(memory.log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "transform-nothing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });
    const missingDir = try std.fs.path.join(allocator, &.{ tempDir, "missing" });
    var generator: FixedUuidGenerator = .{ .id = "nothing" };
    var image = Image.init("../test/test.png");

    try std.testing.expectError(error.Thrown, image.transform(allocator, std.testing.io, memory.log, runner, .{ .flipX = true }, missingDir, generator.uuidGenerator()));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to execute command: ") != null);

    // A rotation of 0 is no transformation (it is falsy).
    try std.testing.expectEqualStrings("../test/test.png", try image.transform(allocator, std.testing.io, memory.log, runner, .{ .rotate = 0 }, tempDir, generator.uuidGenerator()));
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

test "parseExifOutput reads the tags as String.prototype.trim and the regular expression /exif:([^=]+)=(.*)/ do" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // trim() removes the U+3000 ending the output, which ends the last value.
    const trimmed = try Image.parseExifOutput(allocator, "exif:Make=Canon\nexif:Model=EOS\u{3000}");
    try std.testing.expectEqualStrings("EOS", trimmed.get("Model").?);

    // `.` stops at U+2028 as it does at \r.
    const separated = try Image.parseExifOutput(allocator, "exif:Artist=Ann\u{2028}Lee\nexif:Copyright=Me\rYou");
    try std.testing.expectEqualStrings("Ann", separated.get("Artist").?);
    try std.testing.expectEqualStrings("Me", separated.get("Copyright").?);

    // An "exif:" with nothing before the "=" does not match there, so the search goes on to the next "exif:".
    const later = try Image.parseExifOutput(allocator, "exif:=x exif:Make=Nikon");
    try std.testing.expectEqualStrings("Nikon", later.get("Make").?);
}

test "every operation works on a file whose name holds $, a backtick and a double quote" {
    // The goal is to show that a path holding a space, `$`, a backtick and `"` reaches ImageMagick unchanged, as the source and as
    // the output. The method is to copy test.jpg under such a name, write every output into a directory whose name holds them too,
    // and check that each operation gives what the same operation gives on test.jpg written to an ordinary path.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
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

    const specialInfo = try special.getInfo(allocator, std.testing.io, log, runner);
    const plainInfo = try plain.getInfo(allocator, std.testing.io, log, runner);
    try std.testing.expectEqual(plainInfo.dimensions, specialInfo.dimensions);
    try std.testing.expectEqual(plainInfo.createdAt, specialInfo.createdAt);

    const specialExif = try special.getExifData(allocator, std.testing.io, log, runner);
    const plainExif = try plain.getExifData(allocator, std.testing.io, log, runner);
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
            .transformation = null,
        };
        var specialGenerator: FixedUuidGenerator = .{ .id = if (format == null) "special-plain" else "special-format" };
        var plainGenerator: FixedUuidGenerator = .{ .id = if (format == null) "plain-plain" else "plain-format" };
        const specialResized = try special.resize(allocator, std.testing.io, log, runner, options, specialDir, specialGenerator.uuidGenerator());
        const plainResized = try plain.resize(allocator, std.testing.io, log, runner, options, tempDir, plainGenerator.uuidGenerator());
        try std.testing.expect(std.mem.startsWith(u8, specialResized, specialDir));
        try std.testing.expectEqualStrings(try describeImage(log, allocator, runner, plainResized), try describeImage(log, allocator, runner, specialResized));
    }

    var specialTransformGenerator: FixedUuidGenerator = .{ .id = "special-transform" };
    var plainTransformGenerator: FixedUuidGenerator = .{ .id = "plain-transform" };
    const specialTransformed = try special.transform(allocator, std.testing.io, log, runner, .{ .rotate = 90 }, specialDir, specialTransformGenerator.uuidGenerator());
    const plainTransformed = try plain.transform(allocator, std.testing.io, log, runner, .{ .rotate = 90 }, tempDir, plainTransformGenerator.uuidGenerator());
    try std.testing.expect(std.mem.startsWith(u8, specialTransformed, specialDir));
    try std.testing.expectEqualStrings(try describeImage(log, allocator, runner, plainTransformed), try describeImage(log, allocator, runner, specialTransformed));

    try std.testing.expectEqual(try plain.getDominantColor(allocator, std.testing.io, log, runner), try special.getDominantColor(allocator, std.testing.io, log, runner));
}

test "resize with a reduced JPEG decode decodes a large JPEG no smaller than the target, and a PNG as without it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "resize-jpeg-size");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A 5472x3648 JPEG, the size of a 20 megapixel camera's photo, from scripts/make-format-test-images.sh: the built-in
    // ImageMagick's security policy lets it draw nothing of its own.
    const largePath = "../test/formats/5472x3648-camera.jpg";
    if (!node_utils.fs.pathExists(std.testing.io, largePath)) {
        std.debug.print("{s} is missing: run bash scripts/make-format-test-images.sh\n", .{largePath});
        return error.FormatTestImageMissing;
    }
    try std.testing.expectEqualStrings("5472 3648 JPEG 90", try describeImage(log, allocator, runner, largePath));

    // 1500x1000 is hinted as 2250x1500, which the bundled ImageMagick decodes at 3/8, 2052x1368: smaller than the original
    // and no smaller than the target. Hinted at the target itself it rounds to 2/8, 1368x912, smaller than the target.
    try std.testing.expectEqualStrings("2052 1368", try runImageMagick(log, allocator, runner, "convert", &.{ "-define", "jpeg:size=2250x1500", largePath, "-format", "%w %h", "info:" }));
    try std.testing.expectEqualStrings("1368 912", try runImageMagick(log, allocator, runner, "convert", &.{ "-define", "jpeg:size=1500x1000", largePath, "-format", "%w %h", "info:" }));

    var generator: FixedUuidGenerator = .{ .id = "large" };
    var image = Image.init(largePath);
    const outputPath = try image.resize(allocator, std.testing.io, log, runner, .{ .width = 1500, .height = 1000, .quality = 95, .format = "jpeg", .ext = "jpg", .maintainAspectRatio = false, .reducedJpegDecode = true, .transformation = null }, tempDir, generator.uuidGenerator());
    try std.testing.expectEqualStrings("1500 1000 JPEG 95", try describeImage(log, allocator, runner, outputPath));

    // The same bytes as the command with the hint, and not those of the command without it, so the resize decoded at the
    // reduced size.
    const referencePath = try std.fs.path.join(allocator, &.{ tempDir, "reference.jpg" });
    _ = try runImageMagick(log, allocator, runner, "convert", &.{ "-define", "jpeg:size=2250x1500", largePath, "-resize", "1500x1000!", "-profile", srgb_profile_path, "-strip", "-quality", "95", try std.mem.concat(allocator, u8, &.{ "jpeg:", referencePath }) });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), try readFile(allocator, outputPath)));
    const fullDecodePath = try std.fs.path.join(allocator, &.{ tempDir, "full-decode.jpg" });
    _ = try runImageMagick(log, allocator, runner, "convert", &.{ largePath, "-resize", "1500x1000!", "-profile", srgb_profile_path, "-strip", "-quality", "95", try std.mem.concat(allocator, u8, &.{ "jpeg:", fullDecodePath }) });
    try std.testing.expect(!std.mem.eql(u8, try readFile(allocator, fullDecodePath), try readFile(allocator, outputPath)));

    // A PNG is resized to the same bytes as without the hint, as only the JPEG decoder reads it. The copies are JPEGs, the only
    // type the built-in ImageMagick's security policy lets it write.
    var pngGenerator: FixedUuidGenerator = .{ .id = "png" };
    var png = Image.init("../test/test.png");
    const pngPath = try png.resize(allocator, std.testing.io, log, runner, .{ .width = 50, .height = 45, .quality = 95, .format = "jpeg", .ext = "jpg", .maintainAspectRatio = false, .reducedJpegDecode = true, .transformation = null }, tempDir, pngGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45", try runImageMagick(log, allocator, runner, "identify", &.{ "-format", "%w %h", pngPath }));
    var pngPlainGenerator: FixedUuidGenerator = .{ .id = "png-plain" };
    const pngPlainPath = try png.resize(allocator, std.testing.io, log, runner, .{ .width = 50, .height = 45, .quality = 95, .format = "jpeg", .ext = "jpg", .maintainAspectRatio = false, .transformation = null }, tempDir, pngPlainGenerator.uuidGenerator());
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, pngPlainPath), try readFile(allocator, pngPath)));
}

test "getInfo of an image with no EXIF reads no date and does not fail" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    try requireImageMagick(log, allocator, runner);
    const tempDir = try makeTempDir(allocator, "no-exif");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch |err| std.debug.panic("The test directory {s} could not be deleted: {s}", .{ tempDir, @errorName(err) });

    // A three frame GIF, the kind of file a GIF import reads, from scripts/make-format-test-images.sh: the built-in ImageMagick's
    // security policy lets it draw nothing of its own.
    const gifPath = "../test/formats/43x17-animated.gif";
    if (!node_utils.fs.pathExists(std.testing.io, gifPath)) {
        std.debug.print("{s} is missing: run bash scripts/make-format-test-images.sh\n", .{gifPath});
        return error.FormatTestImageMissing;
    }

    // `identify -format "%[EXIF:*]"` succeeds and prints nothing for a file with no EXIF, so getExifData finds no tags
    // and getInfo leaves createdAt null.
    for ([_][]const u8{ "../test/test.png", "../test/test.webp", "../test/multiple-files/test-1.jpeg", "../test/duplicate-images/a.png", gifPath }) |filePath| {
        errdefer std.debug.print("file: {s}\n", .{filePath});
        var image = Image.init(filePath);
        const exifData = try image.getExifData(allocator, std.testing.io, log, runner);
        try std.testing.expectEqual(@as(usize, 0), exifData.count());
        const info = try image.getInfo(allocator, std.testing.io, log, runner);
        try std.testing.expect(info.createdAt == null);
        try std.testing.expect(info.dimensions.width > 0);
        try std.testing.expect(info.dimensions.height > 0);
    }

    // A HEIC is imported from the JPEG it is decoded to, whose size is read with getInfo. The decoded JPEG of the
    // fixture carries no EXIF either.
    const decodedPath = try std.fs.path.join(allocator, &.{ tempDir, "decoded.jpg" });
    try tools.heic.decodeHeic(allocator, std.testing.io, log, runner, "../test/heic/tiled.heic", decodedPath);
    var decoded = Image.init(decodedPath);
    const decodedExif = try decoded.getExifData(allocator, std.testing.io, log, runner);
    const decodedInfo = try decoded.getInfo(allocator, std.testing.io, log, runner);
    try std.testing.expectEqual(@as(usize, 0), decodedExif.count());
    try std.testing.expect(decodedInfo.createdAt == null);
    try std.testing.expectEqual(@as(f64, 1000), decodedInfo.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), decodedInfo.dimensions.height);
}

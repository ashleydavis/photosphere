const std = @import("std");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const Image = tools.Image;

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
// Runs an ImageMagick tool ("convert" or "identify") the way the TypeScript Image runs it for the installation
// verifyImageMagick found (`magick` and `magick identify` for ImageMagick 7, `convert` and `identify` for
// ImageMagick 6), and returns what it printed. The tests use it to measure the files Image wrote, and to run the
// commands the TypeScript Image builds (packages/tools/src/lib/image.ts) so their output is the expected output.
//
fn runImageMagick(allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (Image.getImageMagickType() == .modern) {
        try argv.append(allocator, "magick");
        if (std.mem.eql(u8, tool, "identify")) {
            try argv.append(allocator, "identify");
        }
    }
    else {
        try argv.append(allocator, tool);
    }
    try argv.appendSlice(allocator, arguments);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv.items });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("ImageMagick failed:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

//
// Reads the width, height, format and JPEG quality of an image file with ImageMagick, as "<w> <h> <format> <quality>".
//
fn describeImage(allocator: std.mem.Allocator, filePath: []const u8) ![]const u8 {
    return runImageMagick(allocator, "identify", &.{ "-format", "%w %h %m %Q", filePath });
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
// Fails a test that needs ImageMagick, loudly, where it is not installed.
//
fn requireImageMagick(allocator: std.mem.Allocator) !void {
    if (!(try Image.verifyImageMagick(allocator, std.testing.io)).available) {
        std.debug.print("This test needs ImageMagick installed.\n", .{});
        return error.RequiredToolsMissing;
    }
}

//
// An image file and what the TypeScript Image's getInfo reads from it.
//
const IExpectedImageInfo = struct {
    // The file.
    filePath: []const u8,

    // The width, in pixels.
    width: f64,

    // The height, in pixels.
    height: f64,

    // The time value TypeScript's `new Date(...)` gives for the file's EXIF DateTimeOriginal, or null when the
    // file has none, so TypeScript leaves createdAt undefined.
    createdAt: ?f64,
};

test "getInfo reads the dimensions and the date of an image like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);

    // The sizes are those in the files' headers (the JPEG frame header, the PNG IHDR chunk and the WebP VP8 frame).
    // test.jpg has an EXIF DateTimeOriginal of "2025:05:27 09:54:16", so TypeScript sets createdAt to
    // `new Date("2025-05-27 09:54:16")` (image.ts rewrites the date colons as dashes and hands the rest to
    // `new Date`). Node and Bun read that date-time with no zone offset as local time, which measured
    // 1748303656000 on a machine at UTC+10:00; js-date.zig assumes local time is UTC (a documented deviation
    // from JavaScript), so the value read here is the UTC reading, ten hours later. The PNG and WebP have no
    // EXIF, so createdAt stays undefined.
    const cases = [_]IExpectedImageInfo{
        .{
            .filePath = "../../test/test.jpg",
            .width = 2560,
            .height = 1920,
            .createdAt = 1748339656000,
        },
        .{
            .filePath = "../../test/test.png",
            .width = 100,
            .height = 90,
            .createdAt = null,
        },
        .{
            .filePath = "../../test/test.webp",
            .width = 100,
            .height = 80,
            .createdAt = null,
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        var image = Image.init(expected.filePath);
        const info = try image.getInfo(allocator, std.testing.io);
        try std.testing.expectEqual(expected.width, info.dimensions.width);
        try std.testing.expectEqual(expected.height, info.dimensions.height);
        try std.testing.expectEqual(expected.createdAt, info.createdAt);
        try std.testing.expectEqualStrings(expected.filePath, info.filePath);
        try std.testing.expectEqual(@as(?bool, false), info.hasAudio);
        try std.testing.expect(info.duration == null);
        try std.testing.expect(info.fps == null);
        try std.testing.expect(info.bitrate == null);

        // The information is read once.
        try std.testing.expectEqual(info.dimensions, (try image.getDimensions(allocator, std.testing.io)));
    }
}

test "resize refuses when the second output path is already taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "resize-second-output");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};
    var generator: FixedUuidGenerator = .{ .id = "second" };
    var image = Image.init("../../test/test.png");

    // The second output path Image.resize checks is <base>-0.<ext>, the one a multi-frame image is written to.
    const secondOutputPath = try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_second-0.png" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = secondOutputPath, .data = "already here" });

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{secondOutputPath}), utils.errors.lastErrorMessage());
}

test "getExifData reads the tags of a real image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);

    var image = Image.init("../../test/test.jpg");
    const exifData = try image.getExifData(allocator, std.testing.io);
    try std.testing.expectEqualStrings("Google", exifData.get("Make").?);
    try std.testing.expectEqualStrings("Pixel 6", exifData.get("Model").?);
    try std.testing.expectEqualStrings("2025:05:27 09:54:16", exifData.get("DateTimeOriginal").?);

    // The DateTimeOriginal is what getInfo turns into createdAt, with the colons of the date replaced by dashes.
    // TypeScript reads a real date out of that: `new Date("2025-05-27 09:54:16")` is the local time, which the Date
    // Time String Format of ECMA-262 allows with a space where the ISO form has a "T". js_date.parseDate reads that
    // form too, so the Zig reads the UTC reading, which is the same value the getInfo test above asserts.
    var withDate = Image.init("../../test/test.jpg");
    const info = try withDate.getInfo(allocator, std.testing.io);
    try std.testing.expectEqual(@as(f64, 1748339656000), info.createdAt.?);
    try std.testing.expectEqualStrings("2025-05-27 09:54:16", try tools.image.exifDateToDashes(allocator, exifData.get("DateTimeOriginal").?));
}

test "getInfo fails for a file that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var image = Image.init("../../test/no-such-file.jpg");
    try std.testing.expectError(error.Thrown, image.getInfo(arena.allocator(), std.testing.io));
    try std.testing.expectEqualStrings("File not found: ../../test/no-such-file.jpg", utils.errors.lastErrorMessage());
}

test "resize writes the image the TypeScript resize command writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "resize");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };

    var image = Image.init("../../test/test.jpg");
    const outputPath = try image.resize(allocator, std.testing.io, .{ .width = 1333, .height = 1000, .quality = 95, .format = "jpeg", .ext = "jpg" }, tempDir, generator.uuidGenerator());

    // TypeScript: path.join(tempDir, `temp_resize_${uuidGenerator.generate()}`) + '.' + options.ext.
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_fixed-id.jpg" }), outputPath);

    // 2560x1920 fitted inside 1333x1000 keeping the aspect ratio is 1333x1000, at the quality asked for.
    try std.testing.expectEqualStrings("1333 1000 JPEG 95", try describeImage(allocator, outputPath));

    // -strip drops the EXIF of the original.
    try std.testing.expectEqualStrings("", try runImageMagick(allocator, "identify", &.{ "-format", "%[EXIF:*]", outputPath }));

    // The same bytes as the command TypeScript builds: `<convert> "<file>" -resize <w>x<h> -strip -quality <q> jpeg:"<output>"`.
    const referencePath = try std.fs.path.join(allocator, &.{ tempDir, "reference.jpg" });
    _ = try runImageMagick(allocator, "convert", &.{ "../../test/test.jpg", "-resize", "1333x1000", "-strip", "-quality", "95", try std.fmt.allocPrint(allocator, "jpeg:{s}", .{referencePath}) });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), try readFile(allocator, outputPath)));

    // A second resize to the same path is refused.
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 10, .quality = 95, .format = "jpeg", .ext = "jpg" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{outputPath}), utils.errors.lastErrorMessage());
}

test "transform writes the image the TypeScript transform command writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "transform");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };

    var image = Image.init("../../test/test.png");
    const outputPath = try image.transform(allocator, std.testing.io, .{ .rotate = 90, .flipX = true }, tempDir, generator.uuidGenerator());

    // TypeScript: path.join(tempDir, `temp_transform_output_${uuidGenerator.generate()}.jpg`).
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_transform_output_fixed-id.jpg" }), outputPath);

    // The 100x90 PNG turned a quarter turn is 90x100, written as a JPEG because of the extension.
    try std.testing.expectEqualStrings("90 100 JPEG", (try describeImage(allocator, outputPath))[0.."90 100 JPEG".len]);

    // The same bytes as the command TypeScript builds: `<convert> "<file>"  -flop -rotate 90 "<output>"`.
    const referencePath = try std.fs.path.join(allocator, &.{ tempDir, "reference.jpg" });
    _ = try runImageMagick(allocator, "convert", &.{ "../../test/test.png", "-flop", "-rotate", "90", referencePath });
    try std.testing.expect(std.mem.eql(u8, try readFile(allocator, referencePath), try readFile(allocator, outputPath)));

    // No transformation returns the original.
    try std.testing.expectEqualStrings("../../test/test.png", try image.transform(allocator, std.testing.io, .{}, tempDir, generator.uuidGenerator()));
}

test "getDominantColor gives the color the TypeScript command prints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    for ([_][]const u8{ "../../test/test.jpg", "../../test/test.png" }) |filePath| {
        errdefer std.debug.print("case: {s}\n", .{filePath});
        var image = Image.init(filePath);
        const color = try image.getDominantColor(allocator, std.testing.io);

        // TypeScript: `<convert> "<file>" -resize 1x1! -format "%[fx:int(mean.r*255)],..." info:`, split on commas.
        const printed = try runImageMagick(allocator, "convert", &.{ filePath, "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" });
        var components = std.mem.splitScalar(u8, printed, ',');
        for (color) |component| {
            try std.testing.expectEqual(try std.fmt.parseFloat(f64, components.next().?), component);
        }
        try std.testing.expect(components.next() == null);
    }

    // test.png is a flat grey card (204, 204, 204) with darker grey lettering, so its mean is a grey.
    var card = Image.init("../../test/test.png");
    const cardColor = try card.getDominantColor(allocator, std.testing.io);
    try std.testing.expectEqual(cardColor[0], cardColor[1]);
    try std.testing.expectEqual(cardColor[1], cardColor[2]);
    try std.testing.expect(cardColor[0] > 150 and cardColor[0] < 204);
}

test "every operation fails for a file that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var generator: FixedUuidGenerator = .{ .id = "fixed-id" };
    var image = Image.init("../../test/no-such-file.jpg");
    const expectedMessage = "File not found: ../../test/no-such-file.jpg";

    try std.testing.expectError(error.Thrown, image.getExifData(allocator, std.testing.io));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 10, .quality = null, .format = null, .ext = "jpg" }, ".", generator.uuidGenerator()));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, std.testing.io));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, image.transform(allocator, std.testing.io, .{ .rotate = 90 }, ".", generator.uuidGenerator()));
    try std.testing.expectEqualStrings(expectedMessage, utils.errors.lastErrorMessage());
}

test "resize to only a width or only a height keeps the aspect ratio" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "resize-one-side");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};
    var image = Image.init("../../test/test.png");

    // The 100x90 PNG to 50 wide is 50x45 (`-resize 50x`), written in the format of the extension (no format given).
    var widthGenerator: FixedUuidGenerator = .{ .id = "width" };
    const widthPath = try image.resize(allocator, std.testing.io, .{ .width = 50, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, widthGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45 PNG", (try describeImage(allocator, widthPath))[0.."50 45 PNG".len]);

    // To 45 high is 50x45 too (`-resize x45`).
    var heightGenerator: FixedUuidGenerator = .{ .id = "height" };
    const heightPath = try image.resize(allocator, std.testing.io, .{ .width = 0, .height = 45, .quality = null, .format = null, .ext = "png" }, tempDir, heightGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("50 45 PNG", (try describeImage(allocator, heightPath))[0.."50 45 PNG".len]);

    // Without keeping the aspect ratio both sides are what was asked for (`-resize 20x30!`).
    var exactGenerator: FixedUuidGenerator = .{ .id = "exact" };
    const exactPath = try image.resize(allocator, std.testing.io, .{ .width = 20, .height = 30, .quality = null, .format = null, .maintainAspectRatio = false, .ext = "png" }, tempDir, exactGenerator.uuidGenerator());
    try std.testing.expectEqualStrings("20 30 PNG", (try describeImage(allocator, exactPath))[0.."20 30 PNG".len]);
}

test "resize refuses a quality outside 0 to 100" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "resize-quality");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};
    var generator: FixedUuidGenerator = .{ .id = "quality" };
    var image = Image.init("../../test/test.png");
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 0, .quality = 101, .format = null, .ext = "jpg" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings("Quality must be between 0 and 100", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 0, .quality = -1, .format = null, .ext = "jpg" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings("Quality must be between 0 and 100", utils.errors.lastErrorMessage());
}

test "resize of an animation returns the first frame ImageMagick writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "resize-animation");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};

    // A two frame GIF resized to PNG is written as <base>-0.png and <base>-1.png, so the validation moves on to the
    // second output path TypeScript checks.
    const animationPath = try std.fs.path.join(allocator, &.{ tempDir, "animation.gif" });
    _ = try runImageMagick(allocator, "convert", &.{ "-size", "20x10", "xc:red", "xc:blue", animationPath });
    var generator: FixedUuidGenerator = .{ .id = "animation" };
    var image = Image.init(animationPath);
    const outputPath = try image.resize(allocator, std.testing.io, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, generator.uuidGenerator());
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_animation-0.png" }), outputPath);

    // A resize whose first frame path is taken is refused.
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, tempDir, generator.uuidGenerator()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Output file already exists: {s}", .{outputPath}), utils.errors.lastErrorMessage());
}

test "resize fails loudly when ImageMagick writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "resize-nothing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};

    // An output directory that does not exist: ImageMagick fails and nothing is written.
    const missingDir = try std.fs.path.join(allocator, &.{ tempDir, "missing" });
    var generator: FixedUuidGenerator = .{ .id = "nothing" };
    var image = Image.init("../../test/test.png");
    try std.testing.expectError(error.Thrown, image.resize(allocator, std.testing.io, .{ .width = 10, .height = 0, .quality = null, .format = null, .ext = "png" }, missingDir, generator.uuidGenerator()));
}

test "getDominantColor fails for a file ImageMagick cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    var image = Image.init("build.zig");
    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, std.testing.io));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to extract dominant color: Error: "));
}

test "getExifData fails for a file ImageMagick cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    var image = Image.init("build.zig");
    try std.testing.expectError(error.Thrown, image.getExifData(allocator, std.testing.io));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to get EXIF data: Error: "));
}

test "transform fails loudly when ImageMagick writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try requireImageMagick(allocator);
    const tempDir = try makeTempDir(allocator, "transform-nothing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tempDir) catch {};
    const missingDir = try std.fs.path.join(allocator, &.{ tempDir, "missing" });
    var generator: FixedUuidGenerator = .{ .id = "nothing" };
    var image = Image.init("../../test/test.png");
    try std.testing.expectError(error.Thrown, image.transform(allocator, std.testing.io, .{ .flipX = true }, missingDir, generator.uuidGenerator()));

    // A rotation of 0 is no transformation, like TypeScript's truthiness check.
    try std.testing.expectEqualStrings("../../test/test.png", try image.transform(allocator, std.testing.io, .{ .rotate = 0 }, tempDir, generator.uuidGenerator()));
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

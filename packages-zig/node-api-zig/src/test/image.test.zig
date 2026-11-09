const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const utils = @import("utils-zig");
const MemoryLog = @import("utils-zig").memory_log.MemoryLog;
const bdb = @import("bdb-zig");
const tools = @import("tools-zig");
const serialization_zig = @import("serialization-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const test_jpg_exif = @import("test-jpg-exif.zig");
const image = node_api.image;
const MediaTools = media_tools.MediaTools;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;

//
// Counts the IDs it generates, so the output paths are known.
//
const CountingUuidGenerator = struct {
    // How many IDs it has generated.
    generated: usize = 0,

    //
    // Gets the IUuidGenerator interface.
    //
    fn uuidGenerator(self: *CountingUuidGenerator) utils.uuid_generator.IUuidGenerator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // The functions of the generator.
    const vtable: utils.uuid_generator.IUuidGenerator.VTable = .{ .generate = generate };

    //
    // Returns the next ID.
    //
    fn generate(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        _ = io;
        const self: *CountingUuidGenerator = @ptrCast(@alignCast(ptr));
        self.generated += 1;
        return std.fmt.allocPrint(allocator, "generated-{d}", .{self.generated});
    }
};

//
// Where test/test.jpg was taken, worked out from the photo's GPS tags: degrees + minutes / 60 + seconds / 3600 of
// each [numerator, denominator] pair, made negative for the S of GPSLatitudeRef (GPSLongitudeRef is E).
//
const TEST_JPG_LOCATION: utils.reverse_geocode.ILocation = .{
    .lat = -((29.0 / 1.0) + ((1.0 / 1.0) / 60.0) + ((856.0 / 100.0) / 3600.0)),
    .lng = (152.0 / 1.0) + ((11.0 / 1.0) / 60.0) + ((2208.0 / 100.0) / 3600.0),
};

//
// The photoDate of test/test.jpg: its DateTimeOriginal, "2025:05:27 09:54:16", read as UTC and written as an
// ISO timestamp.
//
const TEST_JPG_PHOTO_DATE = "2025-05-27T09:54:16.000Z";

//
// Expects the metadata, as `JSON.stringify(metadata, null, 2)`, to be the expected text (null for undefined).
//
fn expectMetadata(allocator: std.mem.Allocator, expected: ?[]const u8, actual: ?serialization_zig.bson.BsonValue) !void {
    if (expected) |text| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(text, try bdb.js_value.jsonStringifyIndented(allocator, actual.?));
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Expects an optional string to be the expected one (null for undefined).
//
fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |text| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(text, actual.?);
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Expects a location to be the expected one (null for undefined).
//
fn expectCoordinates(expected: ?utils.reverse_geocode.ILocation, actual: ?utils.reverse_geocode.ILocation) !void {
    if (expected) |location| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqual(location.lat, actual.?.lat);
        try std.testing.expectEqual(location.lng, actual.?.lng);
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Reads the width, height, format and JPEG quality of an image file with the ImageMagick built into the program, as
// "<w> <h> <format> <quality>", and whether it still holds any EXIF.
//
fn describeImage(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner, filePath: []const u8) ![]const u8 {
    const result = try runner.run(runner.context, std.testing.io, log, allocator, "magick", &.{ "identify", "-format", "%w %h %m %Q exif:[%[EXIF:*]]", filePath });
    if (result.exit_code != 0) {
        std.debug.print("identify failed with exit code {d}:\n{s}\n", .{ result.exit_code, result.output });
        return error.TestUnexpectedResult;
    }
    return std.mem.trimEnd(u8, result.output, "\r\n");
}

//
// A file, the content type it is read as, and the metadata getImageMetadata reads from it.
//
const IMetadataCase = struct {
    // The file.
    filePath: []const u8,

    // The content type.
    contentType: []const u8,

    // `JSON.stringify(metadata, null, 2)`, or null when metadata is undefined.
    metadata: ?[]const u8,

    // The coordinates, or null when undefined.
    coordinates: ?utils.reverse_geocode.ILocation,

    // The photo date, or null when undefined.
    photoDate: ?[]const u8,

    // The dimensions from the JPEG frame header, or null when undefined.
    dimensions: ?node_api.media_file_database.IResolution,
};

test "getImageMetadata reads the metadata" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);

    // The code under test logs the failure below; a passing test must write nothing to stderr, so the log is muted.
    const cases = [_]IMetadataCase{
        // A photo with EXIF and GPS; the frame header (at byte 87843) is inside the 256 KB head.
        .{
            .filePath = "../test/test.jpg",
            .contentType = "image/jpeg",
            .metadata = test_jpg_exif.TEST_JPG_TAGS_JSON,
            .coordinates = TEST_JPG_LOCATION,
            .photoDate = TEST_JPG_PHOTO_DATE,
            .dimensions = .{
                .width = 2560,
                .height = 1920,
            },
        },
        // A JPEG with no APP1 section: no tags (so the whole file is read again, and still has none), no date, but
        // the 100x80 frame header.
        .{
            .filePath = "../test/multiple-files/test-1.jpeg",
            .contentType = "image/jpg",
            .metadata = "{}",
            .coordinates = null,
            .photoDate = null,
            .dimensions = .{
                .width = 100,
                .height = 80,
            },
        },
        // Only JPEGs are read.
        .{
            .filePath = "../test/test.png",
            .contentType = "image/png",
            .metadata = null,
            .coordinates = null,
            .photoDate = null,
            .dimensions = null,
        },
        // A file that is not a JPEG makes the EXIF parser throw, which is logged and turned into nothing.
        .{
            .filePath = "../test/demo-news.yaml",
            .contentType = "image/jpeg",
            .metadata = null,
            .coordinates = null,
            .photoDate = null,
            .dimensions = null,
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        const metadata = try image.getImageMetadata(allocator, std.testing.io, log, expected.filePath, expected.contentType);
        try expectMetadata(allocator, expected.metadata, metadata.metadata);
        try expectCoordinates(expected.coordinates, metadata.coordinates);
        try expectOptionalString(expected.photoDate, metadata.photoDate);
        try std.testing.expectEqual(expected.dimensions, metadata.dimensions);
    }
}

//
// A file, the content type it is read as, and the details getImageDetails produces for it.
//
const IDetailsCase = struct {
    // The file.
    filePath: []const u8,

    // The content type.
    contentType: []const u8,

    // The resolution.
    resolution: node_api.media_file_database.IResolution,

    // What ImageMagick reads from the display image: "<w> <h> JPEG <quality> exif:[]".
    display: []const u8,

    // What ImageMagick reads from the thumbnail.
    thumbnail: []const u8,

    // What ImageMagick reads from the micro image.
    micro: []const u8,

    // `JSON.stringify(metadata, null, 2)`, or null when metadata is undefined.
    metadata: ?[]const u8,

    // The coordinates, or null when undefined.
    coordinates: ?utils.reverse_geocode.ILocation,

    // The photo date, or null when undefined.
    photoDate: ?[]const u8,
};

test "getImageDetails produces the details and the files" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);

    // resizeImage makes the short side minSize and the long side
    // trunc(long / short * minSize): the display at 1000 and quality 95, the thumbnail at 300 and quality 90
    // made from the display, and the micro at 40 and quality 75 made from the thumbnail, each a JPEG resized with
    // -strip, so none keeps any EXIF. None of these files has an Orientation that needs a transformation.
    const cases = [_]IDetailsCase{
        // 2560x1920: 1333x1000, 400x300 and 53x40. The micro is written at quality 75, and ImageMagick reads its quality
        // back as 76: the libjpeg built into the program (IJG libjpeg 9f) writes a chroma table at quality 75 that starts
        // with 8 where libjpeg-turbo's starts with 9, and ImageMagick estimates the quality from the tables. The other
        // files hold only greys, so ImageMagick writes their micros as grey JPEGs, which have no chroma table, and they read
        // back as 75.
        .{
            .filePath = "../test/test.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 2560,
                .height = 1920,
            },
            .display = "1333 1000 JPEG 95 exif:[]",
            .thumbnail = "400 300 JPEG 90 exif:[]",
            .micro = "53 40 JPEG 76 exif:[]",
            .metadata = test_jpg_exif.TEST_JPG_TAGS_JSON,
            .coordinates = TEST_JPG_LOCATION,
            .photoDate = TEST_JPG_PHOTO_DATE,
        },
        // 100x80: 1250x1000, 375x300 and 50x40.
        .{
            .filePath = "../test/multiple-files/test-1.jpeg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 100,
                .height = 80,
            },
            .display = "1250 1000 JPEG 95 exif:[]",
            .thumbnail = "375 300 JPEG 90 exif:[]",
            .micro = "50 40 JPEG 75 exif:[]",
            .metadata = "{}",
            .coordinates = null,
            .photoDate = null,
        },
        // 100x90, the size from the image tool as there is no EXIF parse: 1111x1000, 333x300 and 44x40.
        .{
            .filePath = "../test/test.png",
            .contentType = "image/png",
            .resolution = .{
                .width = 100,
                .height = 90,
            },
            .display = "1111 1000 JPEG 95 exif:[]",
            .thumbnail = "333 300 JPEG 90 exif:[]",
            .micro = "44 40 JPEG 75 exif:[]",
            .metadata = null,
            .coordinates = null,
            .photoDate = null,
        },
        // 100x80, from the image tool: 1250x1000, 375x300 and 50x40.
        .{
            .filePath = "../test/test.webp",
            .contentType = "image/webp",
            .resolution = .{
                .width = 100,
                .height = 80,
            },
            .display = "1250 1000 JPEG 95 exif:[]",
            .thumbnail = "375 300 JPEG 90 exif:[]",
            .micro = "50 40 JPEG 75 exif:[]",
            .metadata = null,
            .coordinates = null,
            .photoDate = null,
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        const tempDir = try temp_dirs.makeTempDir(allocator, std.testing.io, "image-details");
        defer temp_dirs.removeTempDir(std.testing.io, tempDir);
        var generator: CountingUuidGenerator = .{};
        const details = try image.getImageDetails(allocator, std.testing.io, log, runner, expected.filePath, tempDir, expected.contentType, generator.uuidGenerator(), expected.filePath);
        try std.testing.expectEqual(expected.resolution, details.resolution);

        // Image.resize names each file temp_resize_<id>.jpg in the temp directory, and the IDs are generated in the
        // order the files are made: display, thumbnail, micro.
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-1.jpg" }), details.displayPath.?);
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-2.jpg" }), details.thumbnailPath);
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-3.jpg" }), details.microPath);
        try std.testing.expectEqualStrings(expected.display, try describeImage(log, allocator, runner, details.displayPath.?));
        try std.testing.expectEqualStrings(expected.thumbnail, try describeImage(log, allocator, runner, details.thumbnailPath));
        try std.testing.expectEqualStrings(expected.micro, try describeImage(log, allocator, runner, details.microPath));
        try std.testing.expectEqualStrings("image/jpeg", details.thumbnailContentType);
        try expectOptionalString("image/jpeg", details.displayContentType);
        try expectMetadata(allocator, expected.metadata, details.metadata);
        try expectCoordinates(expected.coordinates, details.coordinates);
        try expectOptionalString(expected.photoDate, details.photoDate);
    }
}

//
// One tag of a hand-built EXIF IFD.
//
const IExifTag = struct {
    // The tag number.
    tag: u16,

    // The TIFF type (2 ASCII, 3 SHORT, 4 LONG, 5 RATIONAL).
    tiffType: u16,

    // The number of values.
    count: u32,

    // The value bytes, little-endian (stored in the entry when they fit in four bytes).
    value: []const u8,
};

//
// Appends a little-endian integer.
//
fn appendLittle(allocator: std.mem.Allocator, output: *std.ArrayList(u8), comptime IntType: type, value: IntType) !void {
    var bytes: [@sizeOf(IntType)]u8 = undefined;
    std.mem.writeInt(IntType, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

//
// Appends an IFD at the given offset of the TIFF data, its larger values right after it.
//
fn appendIfd(allocator: std.mem.Allocator, tiff: *std.ArrayList(u8), tags: []const IExifTag) !void {
    const ifdOffset: u32 = @intCast(tiff.items.len);
    var dataOffset: u32 = ifdOffset + 2 + 12 * @as(u32, @intCast(tags.len)) + 4;
    var data: std.ArrayList(u8) = .empty;
    try appendLittle(allocator, tiff, u16, @intCast(tags.len));
    for (tags) |exifTag| {
        try appendLittle(allocator, tiff, u16, exifTag.tag);
        try appendLittle(allocator, tiff, u16, exifTag.tiffType);
        try appendLittle(allocator, tiff, u32, exifTag.count);
        if (exifTag.value.len <= 4) {
            var inline_value = [4]u8{ 0, 0, 0, 0 };
            @memcpy(inline_value[0..exifTag.value.len], exifTag.value);
            try tiff.appendSlice(allocator, &inline_value);
        }
        else {
            try appendLittle(allocator, tiff, u32, dataOffset);
            try data.appendSlice(allocator, exifTag.value);
            dataOffset += @intCast(exifTag.value.len);
        }
    }
    try appendLittle(allocator, tiff, u32, 0);
    try tiff.appendSlice(allocator, data.items);
}

//
// Little-endian RATIONAL values: numerator and denominator pairs.
//
fn rationals(allocator: std.mem.Allocator, pairs: []const [2]u32) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (pairs) |pair| {
        try appendLittle(allocator, &output, u32, pair[0]);
        try appendLittle(allocator, &output, u32, pair[1]);
    }
    return output.items;
}

//
// Writes test/multiple-files/test-1.jpeg (100x80, no EXIF of its own) with an APP1 EXIF segment of an Orientation and
// a GPS IFD holding the given tags, and returns its path.
//
fn writeJpegWithExif(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, orientation: u16, gpsTags: []const IExifTag) ![]const u8 {
    var tiff: std.ArrayList(u8) = .empty;
    try tiff.appendSlice(allocator, "II");
    try appendLittle(allocator, &tiff, u16, 42);
    try appendLittle(allocator, &tiff, u32, 8);
    // IFD0 holds two tags whose values fit in their entries: 2 + 2 * 12 + 4 bytes, so the GPS IFD starts at 38.
    var orientationValue: [2]u8 = undefined;
    std.mem.writeInt(u16, &orientationValue, orientation, .little);
    var gpsOffset: [4]u8 = undefined;
    std.mem.writeInt(u32, &gpsOffset, 38, .little);
    try appendIfd(allocator, &tiff, &.{
        .{ .tag = 0x0112, .tiffType = 3, .count = 1, .value = &orientationValue },
        .{ .tag = 0x8825, .tiffType = 4, .count = 1, .value = &gpsOffset },
    });
    try std.testing.expectEqual(@as(usize, 38), tiff.items.len);
    try appendIfd(allocator, &tiff, gpsTags);

    const original = try test_files.readFile(allocator, io, "../test/multiple-files/test-1.jpeg");
    var jpeg: std.ArrayList(u8) = .empty;
    try jpeg.appendSlice(allocator, original[0..2]);
    try jpeg.appendSlice(allocator, &.{ 0xFF, 0xE1 });
    var segmentLength: [2]u8 = undefined;
    std.mem.writeInt(u16, &segmentLength, @intCast(2 + 6 + tiff.items.len), .big);
    try jpeg.appendSlice(allocator, &segmentLength);
    try jpeg.appendSlice(allocator, "Exif\x00\x00");
    try jpeg.appendSlice(allocator, tiff.items);
    try jpeg.appendSlice(allocator, original[2..]);
    const filePath = try std.fs.path.join(allocator, &.{ dir, "exif.jpg" });
    try test_files.writeFile(io, filePath, jpeg.items);
    return filePath;
}

test "getImageDetails turns a photo its Orientation says is on its side, and ignores GPS coordinates out of range" {
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
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(memory.log);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "image-details-rotated");
    defer temp_dirs.removeTempDir(io, tempDir);
    const filePath = try writeJpegWithExif(allocator, io, tempDir, 6, &.{
        .{ .tag = 0x0001, .tiffType = 2, .count = 2, .value = "N\x00" },
        .{ .tag = 0x0002, .tiffType = 5, .count = 3, .value = try rationals(allocator, &.{ .{ 95, 1 }, .{ 0, 1 }, .{ 0, 1 } }) },
        .{ .tag = 0x0003, .tiffType = 2, .count = 2, .value = "E\x00" },
        .{ .tag = 0x0004, .tiffType = 5, .count = 3, .value = try rationals(allocator, &.{ .{ 10, 1 }, .{ 30, 1 }, .{ 0, 1 } }) },
    });

    var generator: CountingUuidGenerator = .{};
    const details = try image.getImageDetails(allocator, io, memory.log, runner, filePath, tempDir, "image/jpeg", generator.uuidGenerator(), filePath);

    // Orientation 6 turns the 100x80 photo a quarter turn, into 80x100, before the smaller versions are made from it:
    // the short side is now the width, so each is minSize wide and Math.trunc(100 / 80 * minSize) high.
    try std.testing.expectEqual(node_api.media_file_database.IResolution{ .width = 80, .height = 100 }, details.resolution);
    try std.testing.expectEqualStrings("80 100", (try describeImage(memory.log, allocator, runner, try std.fs.path.join(allocator, &.{ tempDir, "temp_transform_output_generated-1.jpg" })))[0..6]);
    try std.testing.expectEqualStrings("1000 1250 JPEG 95 exif:[]", try describeImage(memory.log, allocator, runner, details.displayPath.?));
    try std.testing.expectEqualStrings("300 375 JPEG 90 exif:[]", try describeImage(memory.log, allocator, runner, details.thumbnailPath));
    try std.testing.expectEqualStrings("40 50 JPEG 75 exif:[]", try describeImage(memory.log, allocator, runner, details.microPath));

    try std.testing.expect(details.coordinates == null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), try std.fmt.allocPrint(allocator, "Ignoring out of range GPS coordinates: lat 95, lng 10.5, for asset {s}.", .{filePath})) != null);
}

test "getImageMetadata drops and logs coordinates that are not finite, and gives up on GPS tags that are not arrays" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(memory.log);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "image-metadata-gps");
    defer temp_dirs.removeTempDir(io, tempDir);

    // 0/0 degrees is NaN and 1/0 degrees is infinity.
    const nanPath = try writeJpegWithExif(allocator, io, tempDir, 1, &.{
        .{ .tag = 0x0002, .tiffType = 5, .count = 3, .value = try rationals(allocator, &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 1 } }) },
        .{ .tag = 0x0004, .tiffType = 5, .count = 3, .value = try rationals(allocator, &.{ .{ 1, 0 }, .{ 0, 1 }, .{ 0, 1 } }) },
    });
    const nanMetadata = try image.getImageMetadata(allocator, io, memory.log, nanPath, "image/jpeg");
    try std.testing.expect(nanMetadata.coordinates == null);
    try std.testing.expect(nanMetadata.metadata != null);
    // The sign of the NaN that 0/0 gives depends on the processor, so Zig prints "nan" or "-nan".
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Ignoring out of range GPS coordinates: lat ") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), try std.fmt.allocPrint(allocator, "nan, lng inf, for asset {s}.", .{nanPath})) != null);

    // A SHORT latitude is a number and an ASCII longitude a string: destructuring [degrees, minutes, seconds] out of
    // the number throws, so no metadata is read at all.
    const scalarPath = try writeJpegWithExif(allocator, io, tempDir, 1, &.{
        .{ .tag = 0x0002, .tiffType = 3, .count = 1, .value = "\x05\x00" },
        .{ .tag = 0x0004, .tiffType = 2, .count = 3, .value = "12\x00" },
    });
    const scalarMetadata = try image.getImageMetadata(allocator, io, memory.log, scalarPath, "image/jpeg");
    try std.testing.expect(scalarMetadata.metadata == null);
    try std.testing.expect(scalarMetadata.coordinates == null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), try std.fmt.allocPrint(allocator, "Failed to get exif data from {s}", .{scalarPath})) != null);
}

test "getImageDetails refuses a file whose content type no image tool can read" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "image-details-unsupported");
    defer temp_dirs.removeTempDir(io, tempDir);
    var uuidGenerator: CountingUuidGenerator = .{};

    // A PNG has no EXIF to give its size, so the image tool is asked, and it is asked by the content type.
    try std.testing.expectError(error.Thrown, image.getImageDetails(allocator, io, log, runner, "../test/test.png", tempDir, "application/x-unknown", uuidGenerator.uuidGenerator(), "test.png"));
    try std.testing.expectEqualStrings("Unsupported file type: application/x-unknown", utils.errors.lastErrorMessage());
}

test "getImageDetails makes the pictures of a HEIC from FFmpeg's decode of it, with the date and place from its EXIF item" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "image-details-heic");
    defer temp_dirs.removeTempDir(io, tempDir);
    // The bundled ImageMagick has no HEIC support and a machine's own ffmpeg may be too old to join a HEIC's tiles, so the tools the
    // app ships are used.
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    var generator: CountingUuidGenerator = .{};
    const heicPath = "../test/heic/tiled.heic";
    const details = try image.getImageDetails(allocator, io, log, mediaTools.runner(), heicPath, tempDir, "image/heic", generator.uuidGenerator(), heicPath);

    // The 1000x700 picture is a grid of four 512 pixel tiles: the size is the decoded picture's, not a tile's or the grid's 1024x1024.
    try std.testing.expectEqual(node_api.media_file_database.IResolution{ .width = 1000, .height = 700 }, details.resolution);

    // The first ID names the decoded JPEG, the next three the display, the thumbnail and the micro image made from it.
    try std.testing.expectEqualStrings("1000 700", (try describeImage(log, allocator, mediaTools.runner(), try std.fs.path.join(allocator, &.{ tempDir, "temp_heic_generated-1.jpg" })))[0..8]);
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-2.jpg" }), details.displayPath.?);
    try std.testing.expectEqualStrings("1428 1000 JPEG 95 exif:[]", try describeImage(log, allocator, mediaTools.runner(), details.displayPath.?));
    try std.testing.expectEqualStrings("428 300 JPEG 90 exif:[]", try describeImage(log, allocator, mediaTools.runner(), details.thumbnailPath));
    try std.testing.expectEqualStrings("57 40 JPEG 76 exif:[]", try describeImage(log, allocator, mediaTools.runner(), details.microPath));

    try expectOptionalString("2021-05-06T07:08:09.000Z", details.photoDate);
    try std.testing.expectApproxEqAbs(@as(f64, -27.4705), details.coordinates.?.lat, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f64, 153.026), details.coordinates.?.lng, 0.00001);
}

//
// Expects fitInBox to fit an image of the first size into a box of the second at the third.
//
fn expectFit(size: [2]f64, box: [2]f64, expected: [2]f64) !void {
    const fitted = image.fitInBox(.{
        .width = size[0],
        .height = size[1],
    }, .{
        .width = box[0],
        .height = box[1],
    });
    try std.testing.expectEqual(expected[0], fitted.width);
    try std.testing.expectEqual(expected[1], fitted.height);
}

test "fitInBox gives the size ImageMagick fits an image into a box at" {
    // The long side fills the box and the short side is rounded half up: 2560x1920 into 1333x1000 is scaled by
    // 1333 / 2560, which makes the short side 999.75, so 1000.
    try expectFit(.{ 2560, 1920 }, .{ 1333, 1000 }, .{ 1333, 1000 });

    // The 1111x1000 display of a 100x90 PNG into 333x300 is scaled by 333 / 1111, the smaller scale, which makes the short
    // side 299.73, so 300.
    try expectFit(.{ 1111, 1000 }, .{ 333, 300 }, .{ 333, 300 });

    // When the height needs the smaller scale it is the one that fills the box: 3000x4000 into 1000x1000 is 750x1000.
    try expectFit(.{ 3000, 4000 }, .{ 1000, 1000 }, .{ 750, 1000 });

    // A side is never less than 1: 4000x10 into 40x40 makes the short side 0.1.
    try expectFit(.{ 4000, 10 }, .{ 40, 40 }, .{ 40, 1 });

    // An image already the box's size is left alone, and a smaller one is scaled up.
    try expectFit(.{ 53, 40 }, .{ 53, 40 }, .{ 53, 40 });
    try expectFit(.{ 100, 80 }, .{ 1250, 1000 }, .{ 1250, 1000 });
}

test "getImageDetails makes pictures of a JPEG the same sizes as resizing it without the reduced decode does" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);

    // Sizes whose sides are not multiples of 8, so libjpeg rounds the sides of each reduced decode up, and a 20 megapixel
    // camera's photo, landscape and portrait.
    for ([_][]const u8{ "5472x3648", "3648x5472", "4001x2999", "2999x4001", "1111x1000", "1601x1203" }) |sizeText| {
        errdefer std.debug.print("size: {s}\n", .{sizeText});
        const tempDir = try temp_dirs.makeTempDir(allocator, std.testing.io, "image-details-sizes");
        defer temp_dirs.removeTempDir(std.testing.io, tempDir);
        const photoPath = try std.fs.path.join(allocator, &.{ tempDir, "photo.jpg" });
        const made = try runner.run(runner.context, std.testing.io, log, allocator, "magick", &.{ "-size", sizeText, "gradient:red-blue", "-quality", "90", photoPath });
        try std.testing.expectEqual(@as(u8, 0), made.exit_code);

        var generator: CountingUuidGenerator = .{};
        const details = try image.getImageDetails(allocator, std.testing.io, log, runner, photoPath, tempDir, "image/jpeg", generator.uuidGenerator(), photoPath);

        // The pictures as resizeImage makes them, each fitted into its box from the one before it with no reduced decode.
        var plainGenerator: CountingUuidGenerator = .{
            .generated = 100,
        };
        const plainDisplay = try image.resizeImage(allocator, std.testing.io, log, runner, photoPath, tempDir, details.resolution, node_api.media_file_database.DISPLAY_MIN_SIZE, plainGenerator.uuidGenerator(), node_api.media_file_database.DISPLAY_QUALITY);
        const plainThumbnail = try image.resizeImage(allocator, std.testing.io, log, runner, plainDisplay, tempDir, details.resolution, node_api.media_file_database.THUMBNAIL_MIN_SIZE, plainGenerator.uuidGenerator(), node_api.media_file_database.THUMBNAIL_QUALITY);
        const plainMicro = try image.resizeImage(allocator, std.testing.io, log, runner, plainThumbnail, tempDir, details.resolution, node_api.media_file_database.MICRO_MIN_SIZE, plainGenerator.uuidGenerator(), node_api.media_file_database.MICRO_QUALITY);

        try std.testing.expectEqualStrings(try describeImage(log, allocator, runner, plainDisplay), try describeImage(log, allocator, runner, details.displayPath.?));
        try std.testing.expectEqualStrings(try describeImage(log, allocator, runner, plainThumbnail), try describeImage(log, allocator, runner, details.thumbnailPath));
        try std.testing.expectEqualStrings(try describeImage(log, allocator, runner, plainMicro), try describeImage(log, allocator, runner, details.microPath));
    }
}

//
// A large JPEG from scripts/make-format-test-images.sh and the sizes of the pictures made of it, turned as its EXIF says.
//
const ILargeJpegCase = struct {
    // The image, relative to the package directory the tests run in.
    filePath: []const u8,

    // The width and height of the display, thumbnail and micro pictures, as `identify` prints them ("<width> <height>").
    displaySize: []const u8,

    // See displaySize.
    thumbnailSize: []const u8,

    // See displaySize.
    microSize: []const u8,
};

//
// How different two pictures of the same size are: ImageMagick's normalised root mean square error, 0 when every pixel is
// the same and 1 when every pixel is as far apart as it can be.
//
fn pictureDifference(log: ILog, allocator: std.mem.Allocator, runner: InProcessRunner, firstPath: []const u8, secondPath: []const u8) !f64 {
    const result = try runner.run(runner.context, std.testing.io, log, allocator, "magick", &.{ firstPath, secondPath, "-metric", "RMSE", "-compare", "-format", "%[distortion]", "info:" });
    if (result.exit_code != 0) {
        std.debug.print("compare failed with exit code {d}:\n{s}\n", .{ result.exit_code, result.output });
        return error.TestUnexpectedResult;
    }
    return std.fmt.parseFloat(f64, std.mem.trim(u8, result.output, " \r\n"));
}

test "getImageDetails makes the pictures of a large JPEG with its reduced decode at the size and the way up a full decode makes them" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    // Red at the top and blue at the bottom as stored. An Orientation of 3 turns it upside down, and 6 and 8 a quarter each
    // way, which stands it upright, so its pictures are the stored proportions swapped.
    const cases = [_]ILargeJpegCase{
        .{
            .filePath = "../test/formats/5472x3648-camera.jpg",
            .displaySize = "1500 1000",
            .thumbnailSize = "450 300",
            .microSize = "60 40",
        },
        .{
            .filePath = "../test/formats/4001x2999-base.jpg",
            .displaySize = "1334 1000",
            .thumbnailSize = "400 300",
            .microSize = "53 40",
        },
        .{
            .filePath = "../test/formats/4001x2999-exif-orientation-1.jpg",
            .displaySize = "1334 1000",
            .thumbnailSize = "400 300",
            .microSize = "53 40",
        },
        .{
            .filePath = "../test/formats/4001x2999-exif-orientation-3.jpg",
            .displaySize = "1334 1000",
            .thumbnailSize = "400 300",
            .microSize = "53 40",
        },
        .{
            .filePath = "../test/formats/4001x2999-exif-orientation-6.jpg",
            .displaySize = "1000 1334",
            .thumbnailSize = "300 400",
            .microSize = "40 53",
        },
        .{
            .filePath = "../test/formats/4001x2999-exif-orientation-8.jpg",
            .displaySize = "1000 1334",
            .thumbnailSize = "300 400",
            .microSize = "40 53",
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        if (!node_utils.fs.pathExists(io, expected.filePath)) {
            std.debug.print("{s} is missing: run bash scripts/make-format-test-images.sh\n", .{expected.filePath});
            return error.FormatTestImageMissing;
        }
        const tempDir = try temp_dirs.makeTempDir(allocator, io, "image-details-large-jpeg");
        defer temp_dirs.removeTempDir(io, tempDir);

        var generator: CountingUuidGenerator = .{};
        const details = try image.getImageDetails(allocator, io, log, runner, expected.filePath, tempDir, "image/jpeg", generator.uuidGenerator(), expected.filePath);

        // The pictures made the way they were before the reduced decode, from a full decode turned by ImageMagick's own
        // reading of the EXIF rather than by getImageDetails, each fitted into its box from the one before it.
        const uprightPath = try std.fs.path.join(allocator, &.{ tempDir, "upright.jpg" });
        const turned = try runner.run(runner.context, io, log, allocator, "magick", &.{ expected.filePath, "-auto-orient", "-quality", "100", uprightPath });
        try std.testing.expectEqual(@as(u8, 0), turned.exit_code);
        var plainGenerator: CountingUuidGenerator = .{
            .generated = 100,
        };
        const plainDisplay = try image.resizeImage(allocator, io, log, runner, uprightPath, tempDir, details.resolution, node_api.media_file_database.DISPLAY_MIN_SIZE, plainGenerator.uuidGenerator(), node_api.media_file_database.DISPLAY_QUALITY);
        const plainThumbnail = try image.resizeImage(allocator, io, log, runner, plainDisplay, tempDir, details.resolution, node_api.media_file_database.THUMBNAIL_MIN_SIZE, plainGenerator.uuidGenerator(), node_api.media_file_database.THUMBNAIL_QUALITY);
        const plainMicro = try image.resizeImage(allocator, io, log, runner, plainThumbnail, tempDir, details.resolution, node_api.media_file_database.MICRO_MIN_SIZE, plainGenerator.uuidGenerator(), node_api.media_file_database.MICRO_QUALITY);

        const pictures = [_][3][]const u8{
            .{ details.displayPath.?, plainDisplay, expected.displaySize },
            .{ details.thumbnailPath, plainThumbnail, expected.thumbnailSize },
            .{ details.microPath, plainMicro, expected.microSize },
        };
        for (pictures) |picture| {
            errdefer std.debug.print("picture: {s}\n", .{picture[0]});
            const description = try describeImage(log, allocator, runner, picture[0]);
            try std.testing.expectEqualStrings(try describeImage(log, allocator, runner, picture[1]), description);
            try std.testing.expect(std.mem.startsWith(u8, description, try std.fmt.allocPrint(allocator, "{s} ", .{picture[2]})));

            // A picture the wrong way up or turned the wrong way puts blue where red is in the full decode's, which is a
            // difference of about a half. The reduced decode's own difference, the blur of decoding at an eighth's scale, measured
            // at most 0.0055 over these pictures (the micro pictures), so the limit is a little under twice that.
            const difference = try pictureDifference(log, allocator, runner, picture[0], picture[1]);
            try std.testing.expect(difference < 0.01);
        }
    }
}

//
// An image of a type the import takes whose size is not in an EXIF it carries, and the size identify reports for it.
//
const ISizeCase = struct {
    // The image, relative to the package directory the tests run in.
    filePath: []const u8,

    // The content type the import gives the file.
    contentType: []const u8,

    // The width and height `identify` prints for the file.
    resolution: node_api.media_file_database.IResolution,
};

test "getImageDetails reads the size of every non-JPEG image type from the image tool alone" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    const runner = mediaTools.runner();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit(log);

    // Each size is what `identify` prints for the file, and each width and height differ, so a size read the wrong way round fails.
    // The files under test/formats are made locally by scripts/make-format-test-images.sh, which says how each is made.
    const cases = [_]ISizeCase{
        .{
            .filePath = "../test/test.png",
            .contentType = "image/png",
            .resolution = .{
                .width = 100,
                .height = 90,
            },
        },
        .{
            .filePath = "../test/test.webp",
            .contentType = "image/webp",
            .resolution = .{
                .width = 100,
                .height = 80,
            },
        },
        .{
            .filePath = "../test/heic/tiled.heic",
            .contentType = "image/heic",
            .resolution = .{
                .width = 1000,
                .height = 700,
            },
        },
        .{
            .filePath = "../test/formats/37x23.gif",
            .contentType = "image/gif",
            .resolution = .{
                .width = 37,
                .height = 23,
            },
        },
        .{
            .filePath = "../test/formats/41x29.bmp",
            .contentType = "image/bmp",
            .resolution = .{
                .width = 41,
                .height = 29,
            },
        },
        .{
            .filePath = "../test/formats/53x31-alpha.png",
            .contentType = "image/png",
            .resolution = .{
                .width = 53,
                .height = 31,
            },
        },
        .{
            .filePath = "../test/formats/61x43-lossless.webp",
            .contentType = "image/webp",
            .resolution = .{
                .width = 61,
                .height = 43,
            },
        },
        .{
            .filePath = "../test/formats/67x47-lossy.webp",
            .contentType = "image/webp",
            .resolution = .{
                .width = 67,
                .height = 47,
            },
        },
        .{
            .filePath = "../test/formats/29x57.gif",
            .contentType = "image/gif",
            .resolution = .{
                .width = 29,
                .height = 57,
            },
        },
        .{
            .filePath = "../test/formats/59x33-v3.bmp",
            .contentType = "image/bmp",
            .resolution = .{
                .width = 59,
                .height = 33,
            },
        },
        // Three frames: the size is the picture's, not the frames' sizes run together.
        .{
            .filePath = "../test/formats/43x17-animated.gif",
            .contentType = "image/gif",
            .resolution = .{
                .width = 43,
                .height = 17,
            },
        },
        .{
            .filePath = "../test/formats/47x19-no-exif.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 47,
                .height = 19,
            },
        },
        // The same 71x37 picture with an EXIF Orientation of 1, 3, 6 and 8. A turn of a quarter (6 and 8) stands it upright, so
        // its size is read with the width and height swapped; 1 and 3 keep it as stored.
        .{
            .filePath = "../test/formats/71x37-exif-orientation-1.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 71,
                .height = 37,
            },
        },
        .{
            .filePath = "../test/formats/71x37-exif-orientation-3.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 71,
                .height = 37,
            },
        },
        .{
            .filePath = "../test/formats/71x37-exif-orientation-6.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 37,
                .height = 71,
            },
        },
        .{
            .filePath = "../test/formats/71x37-exif-orientation-8.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 37,
                .height = 71,
            },
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        if (!node_utils.fs.pathExists(io, expected.filePath)) {
            std.debug.print("{s} is missing: run bash scripts/make-format-test-images.sh\n", .{expected.filePath});
            return error.FormatTestImageMissing;
        }
        const tempDir = try temp_dirs.makeTempDir(allocator, io, "image-details-size");
        defer temp_dirs.removeTempDir(io, tempDir);
        var generator: CountingUuidGenerator = .{};
        const details = try image.getImageDetails(allocator, io, log, runner, expected.filePath, tempDir, expected.contentType, generator.uuidGenerator(), expected.filePath);
        try std.testing.expectEqual(expected.resolution, details.resolution);
    }
}

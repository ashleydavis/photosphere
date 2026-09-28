const std = @import("std");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const bdb = @import("bdb-zig");
const tools = @import("tools-zig");
const serialization_zig = @import("serialization-zig");
const test_helpers = @import("test-helpers.zig");
const test_jpg_exif = @import("test-jpg-exif.zig");
const image = node_api.image;

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
// Where test/test.jpg was taken, as TypeScript's convertExifCoordinates (packages/utils/src/lib/reverse-geocode.ts)
// works it out from the photo's GPS tags: degrees + minutes / 60 + seconds / 3600 of each [numerator, denominator]
// pair, made negative for the S of GPSLatitudeRef (GPSLongitudeRef is E).
//
const TEST_JPG_LOCATION: utils.reverse_geocode.ILocation = .{
    .lat = -((29.0 / 1.0) + ((1.0 / 1.0) / 60.0) + ((856.0 / 100.0) / 3600.0)),
    .lng = (152.0 / 1.0) + ((11.0 / 1.0) / 60.0) + ((2208.0 / 100.0) / 3600.0),
};

//
// The photoDate TypeScript's pickExifDate gives for test/test.jpg: its DateTimeOriginal, "2025:05:27 09:54:16",
// read as UTC and written with toISOString.
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
// Reads the width, height, format and JPEG quality of an image file with ImageMagick, as "<w> <h> <format> <quality>",
// and whether it still holds any EXIF.
//
fn describeImage(allocator: std.mem.Allocator, filePath: []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (tools.Image.getImageMagickType() == .modern) {
        try argv.appendSlice(allocator, &.{ "magick", "identify" });
    }
    else {
        try argv.append(allocator, "identify");
    }
    try argv.appendSlice(allocator, &.{ "-format", "%w %h %m %Q exif:[%[EXIF:*]]", filePath });
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv.items });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("identify failed:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

//
// A file, the content type it is read as, and the metadata TypeScript's getImageMetadata reads from it.
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

test "getImageMetadata reads the metadata TypeScript reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = try test_helpers.setupEnvironment(std.testing.io);
    const cases = [_]IMetadataCase{
        // A photo with EXIF and GPS; the frame header (at byte 87843) is inside the 256 KB head.
        .{
            .filePath = "../../test/test.jpg",
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
            .filePath = "../../test/multiple-files/test-1.jpeg",
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
            .filePath = "../../test/test.png",
            .contentType = "image/png",
            .metadata = null,
            .coordinates = null,
            .photoDate = null,
            .dimensions = null,
        },
        // A file that is not a JPEG makes exif-parser throw, which TypeScript logs and turns into nothing.
        .{
            .filePath = "../../test/demo-news.yaml",
            .contentType = "image/jpeg",
            .metadata = null,
            .coordinates = null,
            .photoDate = null,
            .dimensions = null,
        },
    };
    for (cases) |expected| {
        errdefer std.debug.print("case: {s}\n", .{expected.filePath});
        const metadata = try image.getImageMetadata(allocator, std.testing.io, expected.filePath, expected.contentType);
        try expectMetadata(allocator, expected.metadata, metadata.metadata);
        try expectCoordinates(expected.coordinates, metadata.coordinates);
        try expectOptionalString(expected.photoDate, metadata.photoDate);
        try std.testing.expectEqual(expected.dimensions, metadata.dimensions);
    }
}

//
// A file, the content type it is read as, and the details TypeScript's getImageDetails produces for it.
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

test "getImageDetails produces the details and the files TypeScript produces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = try test_helpers.setupEnvironment(std.testing.io);

    // resizeImage (packages/node-api/src/lib/image.ts) makes the short side minSize and the long side
    // Math.trunc(long / short * minSize): the display at 1000 and quality 95, the thumbnail at 300 and quality 90
    // made from the display, and the micro at 40 and quality 75 made from the thumbnail, each a JPEG resized with
    // -strip, so none keeps any EXIF. None of these files has an Orientation that needs a transformation.
    const cases = [_]IDetailsCase{
        // 2560x1920: 1333x1000, 400x300 and 53x40.
        .{
            .filePath = "../../test/test.jpg",
            .contentType = "image/jpeg",
            .resolution = .{
                .width = 2560,
                .height = 1920,
            },
            .display = "1333 1000 JPEG 95 exif:[]",
            .thumbnail = "400 300 JPEG 90 exif:[]",
            .micro = "53 40 JPEG 75 exif:[]",
            .metadata = test_jpg_exif.TEST_JPG_TAGS_JSON,
            .coordinates = TEST_JPG_LOCATION,
            .photoDate = TEST_JPG_PHOTO_DATE,
        },
        // 100x80: 1250x1000, 375x300 and 50x40.
        .{
            .filePath = "../../test/multiple-files/test-1.jpeg",
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
            .filePath = "../../test/test.png",
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
            .filePath = "../../test/test.webp",
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
        const tempDir = try test_helpers.makeTempDir(allocator, std.testing.io, "image-details");
        defer test_helpers.removeTempDir(std.testing.io, tempDir);
        var generator: CountingUuidGenerator = .{};
        const details = try image.getImageDetails(allocator, std.testing.io, expected.filePath, tempDir, expected.contentType, generator.uuidGenerator(), expected.filePath);
        try std.testing.expectEqual(expected.resolution, details.resolution);

        // Image.resize names each file temp_resize_<id>.jpg in the temp directory, and the IDs are generated in the
        // order the files are made: display, thumbnail, micro.
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-1.jpg" }), details.displayPath.?);
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-2.jpg" }), details.thumbnailPath);
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ tempDir, "temp_resize_generated-3.jpg" }), details.microPath);
        try std.testing.expectEqualStrings(expected.display, try describeImage(allocator, details.displayPath.?));
        try std.testing.expectEqualStrings(expected.thumbnail, try describeImage(allocator, details.thumbnailPath));
        try std.testing.expectEqualStrings(expected.micro, try describeImage(allocator, details.microPath));
        try std.testing.expectEqualStrings("image/jpeg", details.thumbnailContentType);
        try expectOptionalString("image/jpeg", details.displayContentType);
        try expectMetadata(allocator, expected.metadata, details.metadata);
        try expectCoordinates(expected.coordinates, details.coordinates);
        try expectOptionalString(expected.photoDate, details.photoDate);
    }
}

test "locationJson prints numbers as JSON.stringify does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // JSON.stringify({ lat: 91.5, lng: 1e-7 }) in Bun.
    const text = try image.locationJson(arena.allocator(), .{
        .lat = 91.5,
        .lng = 1e-7,
    });
    try std.testing.expectEqualStrings("{\"lat\":91.5,\"lng\":1e-7}", text);
}

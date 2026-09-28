const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const tools = @import("tools-zig");
const media_file_database = @import("media-file-database.zig");
const exif_parser = @import("third-party/exif-parser/parser.zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const js_date = serialization_zig.js_date;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IImageTransformation = utils.image.IImageTransformation;
const ILocation = utils.reverse_geocode.ILocation;
const convertExifCoordinates = utils.reverse_geocode.convertExifCoordinates;
const isLocationInRange = utils.reverse_geocode.isLocationInRange;
const getImageTransformation = utils.image.getImageTransformation;
const readFileHead = node_utils.fs.readFileHead;
const getFileInfo = tools.getFileInfo;
const Image = tools.Image;
const IAssetDetails = media_file_database.IAssetDetails;
const IResolution = media_file_database.IResolution;
const DISPLAY_MIN_SIZE = media_file_database.DISPLAY_MIN_SIZE;
const DISPLAY_QUALITY = media_file_database.DISPLAY_QUALITY;
const MICRO_MIN_SIZE = media_file_database.MICRO_MIN_SIZE;
const MICRO_QUALITY = media_file_database.MICRO_QUALITY;
const THUMBNAIL_MIN_SIZE = media_file_database.THUMBNAIL_MIN_SIZE;
const THUMBNAIL_QUALITY = media_file_database.THUMBNAIL_QUALITY;
const log = &utils.log.log;
const errors = utils.errors;

//
// How much of a photo is read to find its EXIF.
//
// EXIF sits in the APP1 segment near the start of a JPEG, and a segment is at most 64 KB, so 256 KB
// covers the header plus any embedded thumbnail comfortably. A photo whose EXIF does not fit falls
// back to a whole-file read, so this number decides how often that happens, not whether the metadata
// is found.
//
const EXIF_HEAD_BYTES = 256 * 1024;

//
// The EXIF date tags, in the order they are preferred.
//
// DateTimeOriginal is when the shutter fired, which is what the date of a photo means to a person.
// DateTimeDigitized is when the image was digitised: the same instant on a digital camera, and the
// scan date for a scanned print. DateTime and ModifyDate are the file's last modification, which an
// edit or a re-encode moves, so they come last and can never displace a real capture date.
//
const EXIF_DATE_TAGS_IN_PRIORITY_ORDER = [_][]const u8{
    "DateTimeOriginal",
    "DateTimeDigitized",
    "DateTime",
    "ModifyDate",
};

//
// Reads the two-digit (or four-digit) number at a position of a date string.
//
fn digitsAt(text: []const u8, start: usize, count: usize) ?i64 {
    var value: i64 = 0;
    for (text[start .. start + count]) |character| {
        if (!std.ascii.isDigit(character)) {
            return null;
        }
        value = value * 10 + (character - '0');
    }
    return value;
}

//
// Turns one EXIF date string into an ISO timestamp, or undefined when it is not a date.
//
// Matches the EXIF date format, "YYYY:MM:DD HH:mm:ss" (TypeScript: EXIF_DATE_PATTERN,
// /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/). A "T" is accepted in place of the space, and
// anything trailing (a sub-second field, a timezone offset) is ignored.
//
// EXIF carries no timezone, so the value is read as UTC, which is what this has always done. A
// photo's stored date does not shift because the reader changed.
//
pub fn parseExifDate(allocator: std.mem.Allocator, rawValue: ?BsonValue) !?[]const u8 {
    const value = rawValue orelse return null;
    const untrimmed = switch (value) {
        .string => |text| text,
        else => return null,
    };

    const text = utils.js_string.trim(untrimmed);
    if (text.len < 19 or text[4] != ':' or text[7] != ':' or (text[10] != ' ' and text[10] != 'T') or text[13] != ':' or text[16] != ':') {
        return null;
    }
    const year = digitsAt(text, 0, 4) orelse return null;
    const month = digitsAt(text, 5, 2) orelse return null;
    const day = digitsAt(text, 8, 2) orelse return null;
    const hour = digitsAt(text, 11, 2) orelse return null;
    const minute = digitsAt(text, 14, 2) orelse return null;
    const second = digitsAt(text, 17, 2) orelse return null;

    // Cameras write an all-zero date when the clock has never been set. It matches the pattern and
    // is not a date, and left alone it files the photo in the year zero.
    if (year == 0 or month == 0 or day == 0) {
        return null;
    }

    // Date.UTC reads the years 0 to 99 as 1900 to 1999, so a year below 100 comes back as a different
    // year and the check that the date came back unchanged refuses it.
    if (year < 100) {
        return null;
    }

    if (month > 12 or day > 31 or hour > 23 or minute > 59 or second > 59) {
        return null;
    }

    // Date.UTC rolls a day past the end of its month into the next one, so a date that came back
    // different from what was asked for was never a real date.
    const daysInMonth = std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(month));
    if (day > daysInMonth) {
        return null;
    }

    const time = js_date.daysFromCivil(year, month, day) * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000;
    var output: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeIsoString(&output.writer, time);
    return output.written();
}

//
// Picks the date a photo was taken out of its EXIF tags, or undefined when they carry none.
//
// Undefined means the photo's metadata says nothing about when it was taken, and the caller falls
// back to the date of the file itself. Nothing is invented here.
//
pub fn pickExifDate(allocator: std.mem.Allocator, tags: ?BsonDocument) !?[]const u8 {
    const document = tags orelse return null;

    for (EXIF_DATE_TAGS_IN_PRIORITY_ORDER) |tagName| {
        if (try parseExifDate(allocator, document.get(tagName))) |parsed| {
            return parsed;
        }
    }

    return null;
}

//
// The current time in milliseconds (TypeScript: `Date.now()`).
//
fn dateNow(io: std.Io) f64 {
    return @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds());
}

//
// Gets the details of an image.
//
pub fn getImageDetails(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, tempDir: []const u8, contentType: []const u8, uuidGenerator: IUuidGenerator, logicalPath: []const u8) !IAssetDetails {
    _ = logicalPath;
    // filePath is always a valid file (already extracted if from zip)
    var imagePath = filePath;

    const metadataStartedAt = dateNow(io);
    const imageMetadata = try getImageMetadata(allocator, io, imagePath, contentType);
    const metadataMs = dateNow(io) - metadataStartedAt;
    const tags: ?BsonDocument = if (imageMetadata.metadata) |metadata| metadata.document else null;
    const imageTransformation = try getImageTransformation(allocator, tags);

    // The EXIF read above went through the JPEG's markers to find the tags, and the frame header
    // that gives the width and height is one of them, so for a photo that carries EXIF the size is
    // already in hand. Asking the image tool as well is a second read of the same file.
    //
    // Anything the parser could not answer for, which is every format that is not JPEG, still asks
    // the tool. That is also what still rejects a file this cannot make an image of.
    const probeStartedAt = dateNow(io);
    var resolution: IResolution = undefined;
    if (imageMetadata.dimensions) |dimensions| {
        resolution = dimensions;
    }
    else {
        const assetInfo = try getFileInfo(allocator, io, imagePath, contentType) orelse {
            return errors.throwError("Unsupported file type: {s}", .{contentType});
        };
        resolution = .{ .width = assetInfo.dimensions.width, .height = assetInfo.dimensions.height };
    }
    const probeMs = dateNow(io) - probeStartedAt;

    if (imageTransformation) |transformation| {
        // Flips orientation depending on exif data.
        imagePath = try transformImage(allocator, io, imagePath, tempDir, transformation, uuidGenerator);
        if (transformation.changeOrientation orelse false) {
            // (Zig: a copy is swapped, as assigning a literal to resolution would overwrite its width before the height reads it.)
            const unswapped = resolution;
            resolution = .{
                .width = unswapped.height,
                .height = unswapped.width,
            };
        }
    }

    // Produced largest first, each from the one before it rather than from the full size original.
    const displayStartedAt = dateNow(io);
    const displayPath = try resizeImage(allocator, io, imagePath, tempDir, resolution, DISPLAY_MIN_SIZE, uuidGenerator, DISPLAY_QUALITY);
    const displayMs = dateNow(io) - displayStartedAt;

    const thumbnailStartedAt = dateNow(io);
    const thumbnailPath = try resizeImage(allocator, io, displayPath, tempDir, resolution, THUMBNAIL_MIN_SIZE, uuidGenerator, THUMBNAIL_QUALITY);
    const thumbnailMs = dateNow(io) - thumbnailStartedAt;

    const microStartedAt = dateNow(io);
    const microPath = try resizeImage(allocator, io, thumbnailPath, tempDir, resolution, MICRO_MIN_SIZE, uuidGenerator, MICRO_QUALITY);
    const microMs = dateNow(io) - microStartedAt;

    return .{
        .resolution = resolution,
        .microPath = microPath,
        .thumbnailPath = thumbnailPath,
        .thumbnailContentType = "image/jpeg",
        .displayPath = displayPath,
        .displayContentType = "image/jpeg",
        .detailTimings = .{
            .metadataMs = metadataMs,
            .probeMs = probeMs,
            .microMs = microMs,
            .thumbnailMs = thumbnailMs,
            .displayMs = displayMs,
        },
        .metadata = imageMetadata.metadata,
        .coordinates = imageMetadata.coordinates,
        .photoDate = imageMetadata.photoDate,
    };
}

//
// What reading a photo's EXIF found.
//
pub const IImageMetadata = struct {
    // Every EXIF tag, as the parser read them (a JavaScript object).
    metadata: ?BsonValue = null,

    // Where the photo was taken, when the EXIF says so and the position is a real one.
    coordinates: ?ILocation = null,

    // When the photo was taken, from the first EXIF date field that carries one.
    photoDate: ?[]const u8 = null,

    // How big the image is, when the parser found the frame header that says so.
    dimensions: ?IResolution = null,
};

//
// The width and height an EXIF parse found, when it found a usable pair.
//
// The parser reports the size from the JPEG's frame header, which it reads on its way to the EXIF.
// A file whose header it did not reach, or reached and made no sense of, gives nothing here and the
// caller falls back to asking an image tool.
//
pub fn dimensionsFromExif(exif: ?exif_parser.ExifResult) ?IResolution {
    const result = exif orelse return null;
    const imageSize = result.imageSize orelse return null;

    const width: f64 = @floatFromInt(imageSize.width);
    const height: f64 = @floatFromInt(imageSize.height);
    if (width <= 0 or height <= 0) {
        return null;
    }

    return .{
        .width = width,
        .height = height,
    };
}

//
// Parses the EXIF of the bytes of a JPEG the way Photosphere calls exif-parser.
//
fn parseExif(allocator: std.mem.Allocator, fileData: []const u8) !exif_parser.ExifResult {
    var parser = exif_parser.Parser.create(fileData);
    _ = parser.enableSimpleValues(false);
    return parser.parse(allocator);
}

//
// JavaScript truthiness of a tag value (arrays and objects are truthy).
//
fn isTruthy(value: ?BsonValue) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .number, .double => |number| number != 0 and !std.math.isNan(number),
        .int32 => |number| number != 0,
        .string => |text| text.len > 0,
        .undefined, .null => false,
        .boolean => |boolean| boolean,
        else => true,
    };
}

//
// The body of the try block of getImageMetadata.
//
fn readImageMetadata(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IImageMetadata {
    var coordinates: ?ILocation = null;

    // Only the head of the file, not the whole photo.
    //
    // EXIF lives in the APP1 segment near the start of a JPEG. A photo whose EXIF does not fit in the
    // head falls back to the whole file below, so nothing is lost when this guess is wrong; it is only
    // slower for that photo.
    var fileData = try readFileHead(allocator, io, filePath, EXIF_HEAD_BYTES);
    var exif = try parseExif(allocator, fileData);

    if (exif.tags.fields.items.len == 0) {
        fileData = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
        exif = try parseExif(allocator, fileData);
    }
    if (isTruthy(exif.tags.get("GPSLatitude")) and isTruthy(exif.tags.get("GPSLongitude"))) {
        coordinates = try convertExifCoordinates(exif.tags);
        if (!isLocationInRange(coordinates.?)) {
            log.@"error"(try std.fmt.allocPrint(allocator, "Ignoring out of range GPS coordinates: {s}, for asset {s}.", .{ try locationJson(allocator, coordinates.?), filePath }));
            coordinates = null;
        }
    }

    const photoDate = try pickExifDate(allocator, exif.tags);

    return .{
        .metadata = .{ .document = exif.tags },
        .coordinates = coordinates,
        .photoDate = photoDate,
        .dimensions = dimensionsFromExif(exif),
    };
}

//
// Formats a location like `JSON.stringify(coordinates)`.
//
pub fn locationJson(allocator: std.mem.Allocator, location: ILocation) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.writeAll("{\"lat\":");
    try writeJsonNumber(&output.writer, location.lat);
    try output.writer.writeAll(",\"lng\":");
    try writeJsonNumber(&output.writer, location.lng);
    try output.writer.writeAll("}");
    return output.written();
}

//
// Writes a number as JSON.stringify does: as JavaScript prints the number, and null for NaN and the infinities.
//
fn writeJsonNumber(writer: *std.Io.Writer, number: f64) !void {
    if (std.math.isFinite(number)) {
        try serialization_zig.js_number.writeNumber(writer, number);
    }
    else {
        try writer.writeAll("null");
    }
}

//
// Gets the metadata from the image.
//
pub fn getImageMetadata(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: []const u8) !IImageMetadata {
    if (std.mem.eql(u8, contentType, "image/jpeg") or std.mem.eql(u8, contentType, "image/jpg")) {
        return readImageMetadata(allocator, io, filePath) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Failed to get exif data from {s}", .{filePath}), err);

            return .{};
        };
    }
    else {
        return .{};
    }
}

//
// JavaScript's `Math.round`: rounds half up.
//
fn jsRound(value: f64) f64 {
    return @floor(value + 0.5);
}

//
// Resize an image.
// (TypeScript default: quality = 90; callers pass it.)
//
pub fn resizeImage(allocator: std.mem.Allocator, io: std.Io, inputPath: []const u8, tempDir: []const u8, resolution: IResolution, minSize: f64, uuidGenerator: IUuidGenerator, quality: f64) ![]const u8 {

    var width: f64 = undefined;
    var height: f64 = undefined;

    if (resolution.width > resolution.height) {
        height = minSize;
        width = @trunc((resolution.width / resolution.height) * minSize);
    }
    else {
        height = @trunc((resolution.height / resolution.width) * minSize);
        width = minSize;
    }

    var image = Image.init(inputPath);
    return image.resize(allocator, io, .{ .width = width, .height = height, .quality = jsRound(quality), .format = "jpeg", .ext = "jpg" }, tempDir, uuidGenerator);
}

//
// Transforms an image.
//
pub fn transformImage(allocator: std.mem.Allocator, io: std.Io, inputPath: []const u8, tempDir: []const u8, options: IImageTransformation, uuidGenerator: IUuidGenerator) ![]const u8 {
    var image = Image.init(inputPath);
    return image.transform(allocator, io, options, tempDir, uuidGenerator);
}

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const tools = @import("tools-zig");
const media_file_database = @import("media-file-database.zig");
const image = @import("image.zig");
const errors = utils.errors;
const log = &utils.log.log;
const ILocation = utils.reverse_geocode.ILocation;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const getVideoTransformation = utils.image.getVideoTransformation;
const parseFloat = utils.js_number.parseFloat;
const parseInt = tools.image.parseInt;
const pathExists = node_utils.fs.pathExists;
const path = node_utils.path;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const jsonParse = serialization_zig.json_parse.jsonParse;
const js_date = serialization_zig.js_date;
const getFileInfo = tools.getFileInfo;
const Video = tools.Video;
const IAssetDetails = media_file_database.IAssetDetails;
const IResolution = media_file_database.IResolution;
const MICRO_MIN_SIZE = media_file_database.MICRO_MIN_SIZE;
const MICRO_QUALITY = media_file_database.MICRO_QUALITY;
const THUMBNAIL_MIN_SIZE = media_file_database.THUMBNAIL_MIN_SIZE;
const resizeImage = image.resizeImage;
const transformImage = image.transformImage;

//
// The current time in milliseconds (TypeScript: `Date.now()`).
//
fn dateNow(io: std.Io) f64 {
    return @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds());
}

//
// `date.toISOString()` for a JavaScript time value: throws "Invalid time value" (a RangeError) for an Invalid Date.
// (No TypeScript counterpart.)
//
fn toISOString(allocator: std.mem.Allocator, time: f64) ![]const u8 {
    if (std.math.isNan(time) or !js_date.isValidTime(@intFromFloat(time))) {
        return errors.throwError("Invalid time value", .{});
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeIsoString(&output.writer, @intFromFloat(time));
    return output.written();
}

//
// Gets the details of a video.
//
pub fn getVideoDetails(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, tempDir: []const u8, contentType: []const u8, uuidGenerator: IUuidGenerator, logicalPath: []const u8) !IAssetDetails {
    _ = logicalPath;
    // filePath is always a valid file (already extracted if from zip)
    const videoPath = filePath;

    const metadataStartedAt = dateNow(io);
    const assetInfo = try getFileInfo(allocator, io, videoPath, contentType) orelse {
        return errors.throwError("Unsupported file type: {s}", .{contentType});
    };
    const metadataMs = dateNow(io) - metadataStartedAt;

    // Extract screenshot at 1 second or middle of video
    var video = Video.init(allocator, io, videoPath);
    const screenshotPath = try path.join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "thumb_{s}.jpg", .{try uuidGenerator.generate(allocator, io)}) });
    const duration = assetInfo.duration;
    const screenshotTime = @min(if (duration != null and isTruthy(duration.?)) duration.? / 2 else 1, 300); // Max 5 minutes
    const screenshotStartedAt = dateNow(io);
    _ = try video.extractScreenshot(allocator, io, screenshotPath, screenshotTime);
    const screenshotMs = dateNow(io) - screenshotStartedAt;

    var resolution: IResolution = .{
        .width = assetInfo.dimensions.width,
        .height = assetInfo.dimensions.height,
    };
    const thumbnailStartedAt = dateNow(io);
    var thumbnailPath = try resizeImage(allocator, io, screenshotPath, tempDir, resolution, THUMBNAIL_MIN_SIZE, uuidGenerator, 90);

    const metadataDocument: ?BsonDocument = if (assetInfo.metadata) |metadata| (if (metadata == .document) metadata.document else null) else null;
    const imageTransformation = try getVideoTransformation(allocator, metadataDocument);
    if (imageTransformation) |transformation| {
        // Flips orientation depending on exif data.
        thumbnailPath = try transformImage(allocator, io, thumbnailPath, tempDir, transformation, uuidGenerator);
        if (transformation.changeOrientation orelse false) {
            resolution = .{
                .width = resolution.height,
                .height = resolution.width,
            };
        }
    }

    const thumbnailMs = dateNow(io) - thumbnailStartedAt;

    const microStartedAt = dateNow(io);
    const microPath = try resizeImage(allocator, io, thumbnailPath, tempDir, resolution, MICRO_MIN_SIZE, uuidGenerator, MICRO_QUALITY);
    const microMs = dateNow(io) - microStartedAt;

    var photoDate: ?[]const u8 = if (assetInfo.createdAt) |createdAt| try toISOString(allocator, createdAt) else null;

    if (photoDate == null) {
        //
        // See if we can get photo date from the JSON file.
        //
        const jsonFilePath = try std.fmt.allocPrint(allocator, "{s}.json", .{filePath});
        if (pathExists(io, jsonFilePath)) {
            const jsonFileData = try std.Io.Dir.cwd().readFileAlloc(io, jsonFilePath, allocator, .unlimited);
            const photoData = try jsonParse(allocator, jsonFileData);
            const timestamp = try photoTakenTimestamp(photoData);
            if (isValueTruthy(timestamp)) {
                const timestampText = try jsString(allocator, timestamp);
                const seconds = parseInt(timestampText);
                if (toISOString(allocator, seconds * 1000)) |parsedDate| {
                    photoDate = parsedDate;
                    log.verbose(try std.fmt.allocPrint(allocator, "Parsed date {s} from timestamp {s} in JSON file {s}", .{ parsedDate, try jsNumberString(allocator, seconds), jsonFilePath }));
                }
                else |err| {
                    log.exception(try std.fmt.allocPrint(allocator, "Failed to parse date {s} from JSON file {s}", .{ timestampText, jsonFilePath }), err);
                }
            }
        }
    }

    // Extract GPS coordinates from video metadata
    var coordinates: ?ILocation = null;
    if (metadataDocument) |metadata| {
        if (metadata.get("location")) |location| {
            if (isValueTruthy(location)) {
                coordinates = parseVideoLocation(try jsString(allocator, location));
            }
        }
    }

    return .{
        .resolution = resolution,
        .microPath = microPath,
        .thumbnailPath = thumbnailPath,
        .thumbnailContentType = "image/jpeg",
        .metadata = assetInfo.metadata,
        .coordinates = coordinates,
        .photoDate = photoDate,
        .duration = assetInfo.duration,
        .detailTimings = .{
            // The frame extraction is counted as metadata rather than as one of the derivative
            // images, because it is not one: it is what a video has to do before there is any image
            // to resize at all, and it is the expensive part of taking a video in.
            .metadataMs = metadataMs + screenshotMs,
            .probeMs = 0,
            .microMs = microMs,
            .thumbnailMs = thumbnailMs,
            .displayMs = 0,
        },
    };
}

//
// `photoData.photoTakenTime?.timestamp` for the value parsed from the JSON file. Reading a property of null or
// undefined throws a TypeError, as it does in JavaScript. (No TypeScript counterpart.)
//
fn photoTakenTimestamp(photoData: BsonValue) !BsonValue {
    switch (photoData) {
        .null, .undefined => {
            return errors.throwError("null is not an object (evaluating 'photoData.photoTakenTime')", .{});
        },
        .document => |document| {
            const photoTakenTime = document.get("photoTakenTime") orelse {
                return .undefined;
            };
            return switch (photoTakenTime) {
                .document => |taken| taken.get("timestamp") orelse .undefined,
                else => .undefined,
            };
        },
        else => {
            return .undefined;
        },
    }
}

//
// JavaScript truthiness of a number. (No TypeScript counterpart.)
//
fn isTruthy(value: f64) bool {
    return value != 0 and !std.math.isNan(value);
}

//
// JavaScript truthiness of a value. (No TypeScript counterpart.)
//
fn isValueTruthy(value: BsonValue) bool {
    return switch (value) {
        .null, .undefined => false,
        .boolean => |boolean| boolean,
        .string => |text| text.len > 0,
        .number, .double => |number| isTruthy(number),
        .int32 => |number| number != 0,
        .int64 => |number| number != 0,
        else => true,
    };
}

//
// `String(value)` for the strings and numbers JSON holds. (No TypeScript counterpart.)
//
fn jsString(allocator: std.mem.Allocator, value: BsonValue) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number, .double => |number| jsNumberString(allocator, number),
        .int32 => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .int64 => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .boolean => |boolean| if (boolean) "true" else "false",
        else => errors.throwError("Unsupported JSON value", .{}),
    };
}

//
// `String(number)` for a JavaScript number. (No TypeScript counterpart.)
//
fn jsNumberString(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    if (std.math.isNan(number)) {
        return "NaN";
    }
    if (number == @floor(number) and @abs(number) < 1e21) {
        return std.fmt.allocPrint(allocator, "{d}", .{@as(i128, @intFromFloat(number))});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{number});
}

//
// Matches /([+-]\d+\.\d+)([+-]\d+\.\d+)/ at a position: the length of the `[+-]\d+\.\d+` there, or null.
// (No TypeScript counterpart: TypeScript runs the regular expression.)
//
fn matchSignedDecimal(text: []const u8, start: usize) ?usize {
    var index = start;
    if (index >= text.len or (text[index] != '+' and text[index] != '-')) {
        return null;
    }
    index += 1;
    const integerStart = index;
    while (index < text.len and std.ascii.isDigit(text[index])) {
        index += 1;
    }
    if (index == integerStart or index >= text.len or text[index] != '.') {
        return null;
    }
    index += 1;
    const fractionStart = index;
    while (index < text.len and std.ascii.isDigit(text[index])) {
        index += 1;
    }
    if (index == fractionStart) {
        return null;
    }
    return index - start;
}

//
// Parses the location of the video.
//
fn parseVideoLocation(location: []const u8) ?ILocation {
    // const videoLocationRegex = /([+-]\d+\.\d+)([+-]\d+\.\d+)/; the first position where both groups match wins.
    // (\d+ is greedy, but a shorter match of the first group never leaves a sign for the second to start with, so
    // the longest first group is the only one that can match.)
    var start: usize = 0;
    while (start < location.len) : (start += 1) {
        const latitudeLength = matchSignedDecimal(location, start) orelse {
            continue;
        };
        const longitudeLength = matchSignedDecimal(location, start + latitudeLength) orelse {
            continue;
        };
        return .{
            .lat = parseFloat(location[start .. start + latitudeLength]),
            .lng = parseFloat(location[start + latitudeLength .. start + latitudeLength + longitudeLength]),
        };
    }

    return null;
}

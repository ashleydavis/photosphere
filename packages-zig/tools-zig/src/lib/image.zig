const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const image_magick = @import("media-tools-zig").image_magick;
const pathExists = node_utils.fs.pathExists;
const join = node_utils.path.join;
const errors = utils.errors;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IImageTransformation = utils.image.IImageTransformation;
const js_date = @import("serialization-zig").js_date;
const types = @import("types.zig");
const AssetInfo = types.AssetInfo;
const Dimensions = types.Dimensions;
const ResizeOptions = types.ResizeOptions;

//
// The result of Image.verifyImageMagick.
//
pub const ImageMagickStatus = struct {
    // True when ImageMagick can be run.
    available: bool,

    // The ImageMagick version, when available.
    version: ?[]const u8 = null,

    // Why ImageMagick is not available.
    @"error": ?[]const u8 = null,
};

//
// Wraps ImageMagick.
//
pub const Image = struct {
    // The file the image is read from.
    filePath: []const u8,

    // The information read from the file, once it has been read.
    _info: ?AssetInfo = null,

    //
    // Creates an image for a file.
    //
    pub fn init(filePath: []const u8) Image {
        return .{ .filePath = filePath };
    }

    //
    // Verify that ImageMagick is available: that it starts with its security policy. It checks on every call, so a failure is never
    // remembered for a later call.
    //
    pub fn verifyImageMagick(allocator: std.mem.Allocator) !ImageMagickStatus {
        image_magick.check() catch |err| {
            return imageMagickFailed(allocator, err);
        };
        return .{
            .available = true,
            .version = image_magick.version(),
        };
    }

    //
    // The status of ImageMagick when it failed with the error: not available, with the error.
    //
    pub fn imageMagickFailed(allocator: std.mem.Allocator, err: anyerror) !ImageMagickStatus {
        return .{
            .available = false,
            .@"error" = try std.fmt.allocPrint(allocator, "The ImageMagick built into the program did not run: {s}", .{try utils.errors.errorToString(allocator, err)}),
        };
    }

    //
    // Reads the dimensions of the image, and its date from the EXIF when it has one.
    //
    fn getImageInfo(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !AssetInfo {
        if (self._info) |info| {
            return info;
        }

        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Get format, dimensions
        const read = image_magick.readImageInfo(allocator, log, self.filePath) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Failed to read the size of {s}", .{self.filePath}), err);
            return err;
        };
        const dimensions: Dimensions = .{
            .width = @floatFromInt(read.width),
            .height = @floatFromInt(read.height),
        };

        // Get EXIF data for created date
        //
        // An EXIF date and time is "2023:12:25 14:30:00", which becomes "2023-12-25 14:30:00". js_date.parseDate reads
        // the space where the ISO 8601 form has a "T" (the Date Time String Format of ECMA-262 allows both) as local
        // time.
        var createdAt: ?f64 = null;
        if (self.getExifData(allocator, io, log)) |exifData| {
            if (exifData.get("DateTimeOriginal")) |dateTimeOriginal| {
                if (dateTimeOriginal.len > 0) {
                    // Parse EXIF date format: "2023:12:25 14:30:00"
                    createdAt = js_date.parseDate(try exifDateToDashes(allocator, dateTimeOriginal));
                }
            }
        }
        else |_| {
            // Ignore EXIF errors
        }

        self._info = .{
            .filePath = self.filePath,

            .dimensions = dimensions,

            .createdAt = createdAt,

            // Images don't have these properties
            .duration = null,
            .fps = null,
            .bitrate = null,
            .hasAudio = false,
        };

        return self._info.?;
    }

    //
    // Gets the width and height of the image.
    //
    pub fn getDimensions(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !Dimensions {
        const info = try self.getImageInfo(allocator, io, log);
        return info.dimensions;
    }

    //
    // Gets the information about the image.
    //
    pub fn getInfo(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !AssetInfo {
        return self.getImageInfo(allocator, io, log);
    }

    //
    // Get EXIF data from the image: each tag's name ("Make", "DateTimeOriginal") and its value.
    //
    pub fn getExifData(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !std.StringArrayHashMapUnmanaged([]const u8) {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        return image_magick.readExif(allocator, log, self.filePath) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Failed to read the EXIF of {s}", .{self.filePath}), err);
            return errors.throwError("Failed to get EXIF data: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
    }

    //
    // Resizes the image into a new file in tempDir and returns its path. Only the first frame of an image of several is resized.
    //
    pub fn resize(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog, options: ResizeOptions, tempDir: []const u8, uuidGenerator: IUuidGenerator) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        const maintainAspectRatio = options.maintainAspectRatio orelse true;
        const outputPath = try std.mem.concat(allocator, u8, &.{ try join(allocator, &.{ tempDir, try std.mem.concat(allocator, u8, &.{ "temp_resize_", try uuidGenerator.generate(allocator, io) }) }), ".", options.ext });

        if (pathExists(io, outputPath)) {
            return errors.throwError("Output file already exists: {s}", .{outputPath});
        }

        // A width or a height of 0 (or NaN) is not given, and the other side follows the aspect ratio.
        const width: ?usize = if (isTruthy(options.width)) try pixelCount("width", options.width) else null;
        const height: ?usize = if (isTruthy(options.height)) try pixelCount("height", options.height) else null;

        var quality: ?u8 = null;
        if (options.quality) |value| {
            if (value < 0 or value > 100) {
                return errors.throwError("Quality must be between 0 and 100", .{});
            }
            if (value != @floor(value)) {
                return errors.throwError("Quality must be a whole number, not {d}", .{value});
            }
            quality = @intFromFloat(value);
        }

        // The format is the one asked for, or else the one the extension names (ImageMagick knows "jpg", "png" and the like as
        // formats).
        const format = if (options.format != null and options.format.?.len > 0) options.format.? else options.ext;

        image_magick.resizeImage(allocator, io, log, .{
            .input_path = self.filePath,
            .output_path = outputPath,
            .width = width,
            .height = height,
            .exact = !maintainAspectRatio and width != null and height != null,
            .quality = quality,
            .format = format,
        }) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Failed to resize {s} into {s}", .{ self.filePath, outputPath }), err);
            return err;
        };
        return outputPath;
    }

    //
    // Extract the dominant color from the image using ImageMagick
    // Returns RGB values as [r, g, b] array
    //
    pub fn getDominantColor(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) ![3]f64 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // The image resized to 1x1 pixel (fastest, good for average color).
        const color = image_magick.dominantColor(allocator, log, self.filePath) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Failed to read the mean colour of {s}", .{self.filePath}), err);
            return errors.throwError("Failed to extract dominant color: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
        return .{ @floatFromInt(color[0]), @floatFromInt(color[1]), @floatFromInt(color[2]) };
    }

    //
    // Transform an image with rotation and flip operations: mirrored left to right first, when flipX says so, then turned clockwise
    // by the rotation.
    //
    pub fn transform(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IImageTransformation, tempDir: []const u8, uuidGenerator: IUuidGenerator) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        var turn: image_magick.ITurn = .{
            .flop = options.flipX orelse false,
        };
        if (options.rotate) |rotate| {
            if (isTruthy(rotate)) {
                turn.rotate_degrees = rotate;
            }
        }

        if (turn.isNone()) {
            // No transformations needed, just return the original file.
            return self.filePath;
        }

        // Transform to a temporary file and return the path.
        const outputPath = try join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "temp_transform_output_{s}.jpg", .{try uuidGenerator.generate(allocator, io)}) });
        image_magick.transformImage(allocator, io, log, .{
            .input_path = self.filePath,
            .output_path = outputPath,
            .turn = turn,
            .format = "JPEG",
        }) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Failed to turn {s} into {s}", .{ self.filePath, outputPath }), err);
            return err;
        };
        return outputPath;
    }
};

//
// JavaScript truthiness of a number.
//
fn isTruthy(value: f64) bool {
    return value != 0 and !std.math.isNan(value);
}

//
// A side of a resize as a number of pixels, which must be a whole number above 0.
//
pub fn pixelCount(side: []const u8, value: f64) !usize {
    if (!(value >= 1) or value != @floor(value) or value > 1e9) {
        return errors.throwError("The {s} to resize to must be a whole number of pixels above 0, not {d}", .{ side, value });
    }
    return @intFromFloat(value);
}

//
// Turns the date of an EXIF date and time into dashes ("2023:12:25 14:30:00" becomes "2023-12-25 14:30:00").
//
pub fn exifDateToDashes(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len >= 10 and std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[1]) and std.ascii.isDigit(text[2]) and std.ascii.isDigit(text[3]) and text[4] == ':' and std.ascii.isDigit(text[5]) and std.ascii.isDigit(text[6]) and text[7] == ':' and std.ascii.isDigit(text[8]) and std.ascii.isDigit(text[9])) {
        const result = try allocator.dupe(u8, text);
        result[4] = '-';
        result[7] = '-';
        return result;
    }
    return text;
}

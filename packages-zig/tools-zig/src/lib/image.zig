const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const version_match = @import("version-match.zig");
const exec = node_utils.exec.exec;
const execLogged = node_utils.exec.execLogged;
const pathExists = node_utils.fs.pathExists;
const join = node_utils.path.join;
const errors = utils.errors;
const parseInt = utils.js_number.parseInt;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IImageTransformation = utils.image.IImageTransformation;
const js_date = @import("serialization-zig").js_date;
const types = @import("types.zig");
const AssetInfo = types.AssetInfo;
const Dimensions = types.Dimensions;
const ResizeOptions = types.ResizeOptions;

//
// The kind of ImageMagick installation found (TypeScript: 'modern' | 'legacy' | 'none').
//
pub const ImageMagickType = enum {
    // ImageMagick 7: the `magick` command.
    modern,

    // ImageMagick 6: the `convert` and `identify` commands.
    legacy,

    // ImageMagick was not found.
    none,
};

//
// The result of Image.verifyImageMagick
// (TypeScript: `{ available: boolean; version?: string; error?: string; type?: 'modern' | 'legacy' }`).
//
pub const ImageMagickStatus = struct {
    // True when ImageMagick can be run.
    available: bool,

    // The ImageMagick version, when available.
    version: ?[]const u8 = null,

    // Why ImageMagick is not available.
    @"error": ?[]const u8 = null,

    // The kind of installation, when available.
    @"type": ?ImageMagickType = null,
};

//
// Gets the version from `magick -version` / `convert -version` output
// (`stdout.match(/Version: ImageMagick ([\d.-]+)/)`), or 'unknown'.
//
fn imageMagickVersion(stdout: []const u8) []const u8 {
    return version_match.matchAfter(stdout, "Version: ImageMagick ", version_match.isVersionNumberCharacter) orelse "unknown";
}

//
// Wraps ImageMagick. Only the tool verification is ported.
//
pub const Image = struct {
    // The command used to convert images.
    var convertCommand: []const u8 = "magick";

    // The command used to identify images.
    var identifyCommand: []const u8 = "magick identify";

    // True once initializeCommands has run (or the commands were configured).
    var isInitialized: bool = false;

    // The kind of ImageMagick installation found.
    var imageMagickType: ImageMagickType = .none;

    // The file the image is read from.
    filePath: []const u8,

    // The information read from the file, once it has been read.
    _info: ?AssetInfo = null,

    //
    // Creates an image for a file (TypeScript: `new Image(filePath)`).
    //
    pub fn init(filePath: []const u8) Image {
        return .{ .filePath = filePath };
    }

    // Not ported: configure (Photosphere does not configure custom binaries).

    //
    // Initialize ImageMagick commands by checking system PATH
    //
    fn initializeCommands(allocator: std.mem.Allocator, io: std.Io) !void {
        if (isInitialized) {
            return;
        }

        // First try modern ImageMagick (magick command)
        if (exec(allocator, io, "magick -version")) |result| {
            // If we get here, modern magick command works
            convertCommand = "magick";
            identifyCommand = "magick identify";
            imageMagickType = .modern;
            isInitialized = true;

            // Get version info
            const version = imageMagickVersion(result.stdout);

            utils.log.log.verbose("Using modern ImageMagick: magick");
            utils.log.log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick version: {s}", .{version}));
            return;
        }
        else |_| {}

        // Try legacy ImageMagick (convert/identify commands)
        const convertResult = exec(allocator, io, "convert -version") catch {
            // Neither modern nor legacy ImageMagick found
            imageMagickType = .none;
            isInitialized = true;
            return;
        };
        _ = exec(allocator, io, "identify -version") catch {
            // Neither modern nor legacy ImageMagick found
            imageMagickType = .none;
            isInitialized = true;
            return;
        };

        // If we get here, legacy commands work
        convertCommand = "convert";
        identifyCommand = "identify";
        imageMagickType = .legacy;
        isInitialized = true;

        // Get version info from convert command
        const version = imageMagickVersion(convertResult.stdout);

        utils.log.log.verbose("Using legacy ImageMagick: convert/identify");
        utils.log.log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick version: {s}", .{version}));
    }

    //
    // Verify that ImageMagick is available
    //
    pub fn verifyImageMagick(allocator: std.mem.Allocator, io: std.Io) !ImageMagickStatus {
        // Initialize commands if not already done
        try initializeCommands(allocator, io);

        if (imageMagickType == .modern) {
            const result = exec(allocator, io, "magick -version") catch |err| {
                return .{
                    .available = false,
                    .@"error" = try std.fmt.allocPrint(allocator, "Modern ImageMagick 'magick' command failed: {s}", .{try utils.errors.errorToString(allocator, err)}),
                };
            };
            return .{
                .available = true,
                .version = imageMagickVersion(result.stdout),
                .@"type" = .modern,
            };
        }
        else if (imageMagickType == .legacy) {
            const result = exec(allocator, io, "convert -version") catch |err| {
                return .{
                    .available = false,
                    .@"error" = try std.fmt.allocPrint(allocator, "Legacy ImageMagick 'convert' command failed: {s}", .{try utils.errors.errorToString(allocator, err)}),
                };
            };
            return .{
                .available = true,
                .version = imageMagickVersion(result.stdout),
                .@"type" = .legacy,
            };
        }
        else {
            return .{
                .available = false,
                .@"error" = "ImageMagick not found. Please install ImageMagick and ensure either 'magick' or 'convert'/'identify' commands are available.",
            };
        }
    }

    //
    // Get the type of ImageMagick installation
    //
    pub fn getImageMagickType() ImageMagickType {
        return imageMagickType;
    }

    //
    // Reads the dimensions of the image, and its date from the EXIF when it has one.
    //
    fn getImageInfo(self: *Image, allocator: std.mem.Allocator, io: std.Io) !AssetInfo {
        if (self._info) |info| {
            return info;
        }

        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Ensure ImageMagick commands are initialized before using them
        try initializeCommands(allocator, io);

        // Get format, dimensions
        const command = try std.fmt.allocPrint(allocator, "{s} -format \"%w %h\" \"{s}\"", .{ identifyCommand, self.filePath });
        const result = try execLogged(allocator, io, "magick", command, null);

        var parts = std.mem.splitScalar(u8, utils.js_string.trim(result.stdout), ' ');
        const width = parseInt(parts.next() orelse "undefined", null);
        const height = parseInt(parts.next() orelse "undefined", null);

        // Get EXIF data for created date
        var createdAt: ?f64 = null;
        if (self.getExifData(allocator, io)) |exifData| {
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

            .dimensions = .{ .width = width, .height = height },

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
    pub fn getDimensions(self: *Image, allocator: std.mem.Allocator, io: std.Io) !Dimensions {
        const info = try self.getImageInfo(allocator, io);
        return info.dimensions;
    }

    //
    // Gets the information about the image.
    //
    pub fn getInfo(self: *Image, allocator: std.mem.Allocator, io: std.Io) !AssetInfo {
        return self.getImageInfo(allocator, io);
    }

    //
    // Get EXIF data from the image
    //
    pub fn getExifData(self: *Image, allocator: std.mem.Allocator, io: std.Io) !std.StringArrayHashMapUnmanaged([]const u8) {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Ensure ImageMagick commands are initialized before using them
        try initializeCommands(allocator, io);

        const command = try std.fmt.allocPrint(allocator, "{s} -format \"%[EXIF:*]\" \"{s}\"", .{ identifyCommand, self.filePath });
        const result = execLogged(allocator, io, "magick", command, null) catch |err| {
            return errors.throwError("Failed to get EXIF data: {s}", .{try utils.errors.errorToString(allocator, err)});
        };

        return parseExifOutput(allocator, result.stdout);
    }

    //
    // Reads the EXIF tags out of the output of `identify -format "%[EXIF:*]"` (the loop over its lines in getExifData).
    //
    pub fn parseExifOutput(allocator: std.mem.Allocator, stdout: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
        var exifData: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, utils.js_string.trim(stdout), '\n');

        while (lines.next()) |line| {
            // TypeScript: `line.match(/exif:([^=]+)=(.*)/)`. The first "exif:" followed by at least one character that
            // is not "=" and then "=" matches, and the value runs to the first line terminator, which `.` does not match.
            var searchStart: usize = 0;
            while (std.mem.indexOfPos(u8, line, searchStart, "exif:")) |start| {
                const rest = line[start + 5 ..];
                const equals = std.mem.indexOfScalar(u8, rest, '=') orelse {
                    break;
                };
                if (equals == 0) {
                    searchStart = start + 1;
                    continue;
                }
                var value = rest[equals + 1 ..];
                for ([_][]const u8{ "\r", "\u{2028}", "\u{2029}" }) |terminator| {
                    if (std.mem.indexOf(u8, value, terminator)) |terminatorIndex| {
                        value = value[0..terminatorIndex];
                    }
                }
                try exifData.put(allocator, rest[0..equals], value);
                break;
            }
        }

        return exifData;
    }

    //
    // The state the resize validation reads (TypeScript: the closure over actualOutputPath).
    //
    const IResizeValidation = struct {
        // The first output path ImageMagick may write.
        outputPath1: []const u8,

        // The second output path ImageMagick may write (for a multi-frame image).
        outputPath2: []const u8,

        // The path the output was found at.
        actualOutputPath: []const u8,

        //
        // Validate output file exists
        //
        fn validate(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8 {
            const state: *IResizeValidation = @ptrCast(@alignCast(context));
            if (!pathExists(io, state.actualOutputPath)) {
                state.actualOutputPath = state.outputPath2;
                if (!pathExists(io, state.actualOutputPath)) {
                    return try std.fmt.allocPrint(allocator, "Resize failed, expect to create {s} or {s}", .{ state.outputPath1, state.outputPath2 });
                }
            }
            return null;
        }
    };

    //
    // Resizes the image into a new file in tempDir and returns its path.
    //
    pub fn resize(self: *Image, allocator: std.mem.Allocator, io: std.Io, options: ResizeOptions, tempDir: []const u8, uuidGenerator: IUuidGenerator) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        const width = options.width;
        const height = options.height;
        const maintainAspectRatio = options.maintainAspectRatio orelse true;
        const baseOutputPath = try join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "temp_resize_{s}", .{try uuidGenerator.generate(allocator, io)}) });
        const outputPath1 = try std.mem.concat(allocator, u8, &.{ baseOutputPath, ".", options.ext });
        const outputPath2 = try std.mem.concat(allocator, u8, &.{ baseOutputPath, "-0.", options.ext });

        if (pathExists(io, outputPath1)) {
            return errors.throwError("Output file already exists: {s}", .{outputPath1});
        }

        if (pathExists(io, outputPath2)) {
            return errors.throwError("Output file already exists: {s}", .{outputPath2});
        }

        // Ensure ImageMagick commands are initialized before using them
        try initializeCommands(allocator, io);

        // Build the resize geometry string
        var geometry: []const u8 = "";
        if (isTruthy(width) and isTruthy(height)) {
            geometry = if (maintainAspectRatio)
                try std.fmt.allocPrint(allocator, "{s}x{s}", .{ try numberText(allocator, width), try numberText(allocator, height) })
            else
                try std.fmt.allocPrint(allocator, "{s}x{s}!", .{ try numberText(allocator, width), try numberText(allocator, height) });
        }
        else if (isTruthy(width)) {
            geometry = try std.fmt.allocPrint(allocator, "{s}x", .{try numberText(allocator, width)});
        }
        else if (isTruthy(height)) {
            geometry = try std.fmt.allocPrint(allocator, "x{s}", .{try numberText(allocator, height)});
        }

        // Build the convert command.
        //
        // The XMP block is dropped from the copy. A resize otherwise carries the original's profiles
        // into it, and a photo from a modern phone brings an XMP block of tens of kilobytes: the
        // forty pixel thumbnail stored inside every asset record was coming out at fifty kilobytes of
        // somebody else's metadata, which the database then wrote into both of its sort index pages
        // and rewrote whole on every commit. The original is stored untouched and keeps everything.
        //
        // Stripped rather than picked at, because on the ImageMagick bundled for Android the
        // surgical forms do not work. The cost is that a derivative loses its colour profile too,
        // which is why the original is stored untouched and keeps everything.
        var command: std.ArrayList(u8) = .empty;
        try command.print(allocator, "{s} \"{s}\" -resize {s} -strip", .{ convertCommand, self.filePath, geometry });

        // Add quality if specified
        if (options.quality) |quality| {
            if (quality < 0 or quality > 100) {
                return errors.throwError("Quality must be between 0 and 100", .{});
            }
            try command.print(allocator, " -quality {s}", .{try numberText(allocator, quality)});
        }

        // Add format specification and output file
        if (options.format != null and options.format.?.len > 0) {
            // For explicit format conversion, specify the format before the output path
            try command.print(allocator, " {s}:\"{s}\"", .{ options.format.?, outputPath1 });
        }
        else {
            try command.print(allocator, " \"{s}\"", .{outputPath1});
        }

        var validation: IResizeValidation = .{
            .outputPath1 = outputPath1,
            .outputPath2 = outputPath2,
            .actualOutputPath = outputPath1,
        };

        _ = try execLogged(allocator, io, "magick", command.items, .{ .context = &validation, .function = IResizeValidation.validate });

        return validation.actualOutputPath;
    }

    // Not ported: saveAs, getDominantColorHistogram, getDominantColors, getPath (not used by psi add).

    //
    // Extract the dominant color from the image using ImageMagick
    // Returns RGB values as [r, g, b] array
    //
    pub fn getDominantColor(self: *Image, allocator: std.mem.Allocator, io: std.Io) ![3]f64 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Ensure ImageMagick commands are initialized before using them
        try initializeCommands(allocator, io);

        return self.getDominantColorInner(allocator, io) catch |err| {
            return errors.throwError("Failed to extract dominant color: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
    }

    //
    // The body of the try block of getDominantColor.
    //
    fn getDominantColorInner(self: *Image, allocator: std.mem.Allocator, io: std.Io) ![3]f64 {
        // Method 1: Simple resize to 1x1 pixel (fastest, good for average color)
        const command = try std.fmt.allocPrint(allocator, "{s} \"{s}\" -resize 1x1! -format \"%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]\" info:", .{ convertCommand, self.filePath });
        const result = try execLogged(allocator, io, "magick", command, null);

        const rgbString = utils.js_string.trim(result.stdout);
        var rgbValues: std.ArrayList(f64) = .empty;
        var values = std.mem.splitScalar(u8, rgbString, ',');
        while (values.next()) |value| {
            try rgbValues.append(allocator, parseInt(utils.js_string.trim(value), null));
        }

        var valid = rgbValues.items.len == 3;
        for (rgbValues.items) |value| {
            if (std.math.isNan(value) or value < 0 or value > 255) {
                valid = false;
            }
        }
        if (valid) {
            return .{ rgbValues.items[0], rgbValues.items[1], rgbValues.items[2] };
        }
        return errors.throwError("Invalid RGB values: {s}", .{rgbString});
    }

    //
    // Transform an image with rotation and flip operations
    //
    pub fn transform(self: *Image, allocator: std.mem.Allocator, io: std.Io, options: IImageTransformation, tempDir: []const u8, uuidGenerator: IUuidGenerator) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Ensure ImageMagick commands are initialized before using them
        try initializeCommands(allocator, io);

        var transformCommand: std.ArrayList(u8) = .empty;

        if (options.flipX orelse false) {
            try transformCommand.appendSlice(allocator, " -flop");
        }

        if (options.rotate) |rotate| {
            if (isTruthy(rotate)) {
                try transformCommand.print(allocator, " -rotate {s}", .{try numberText(allocator, rotate)});
            }
        }

        if (transformCommand.items.len > 0) {
            // Transform to a temporary file and return the path.
            const outputPath = try join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "temp_transform_output_{s}.jpg", .{try uuidGenerator.generate(allocator, io)}) });
            const command = try std.fmt.allocPrint(allocator, "{s} \"{s}\" {s} \"{s}\"", .{ convertCommand, self.filePath, transformCommand.items, outputPath });
            _ = try execLogged(allocator, io, "magick", command, null);

            // Check if the output file was created successfully.
            if (!pathExists(io, outputPath)) {
                return errors.throwError("Image transformation failed, output file not created: {s}", .{outputPath});
            }
            return outputPath;
        }
        else {
            // No transformations needed, just return the original file.
            return self.filePath;
        }
    }

    //
    // Forgets the detected installation so the next verifyImageMagick detects it again
    // (no TypeScript counterpart: used by tests, which cannot reload the module).
    //
    pub fn resetInitialization() void {
        convertCommand = "magick";
        identifyCommand = "magick identify";
        isInitialized = false;
        imageMagickType = .none;
    }
};

//
// JavaScript truthiness of a number.
//
fn isTruthy(value: f64) bool {
    return value != 0 and !std.math.isNan(value);
}

//
// Turns the date of an EXIF date and time into dashes (TypeScript:
// `.replace(/^(\d{4}):(\d{2}):(\d{2})/, '$1-$2-$3')`).
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

//
// `${number}` in a template string: the number as JavaScript writes it.
//
fn numberText(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try utils.js_number.writeNumber(&output.writer, number);
    return output.written();
}

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const version_match = @import("version-match.zig");
const tool_run = @import("media-tools-zig").tool_run;
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
// Gets the version from `magick -version` output
// (`stdout.match(/Version: ImageMagick ([\d.-]+)/)`), or 'unknown'.
//
fn imageMagickVersion(stdout: []const u8) []const u8 {
    return version_match.matchAfter(stdout, "Version: ImageMagick ", version_match.isVersionNumberCharacter) orelse "unknown";
}

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
    // Verify that ImageMagick is available. It runs `magick -version` on every call, so a failure is never remembered for a
    // later call.
    //
    pub fn verifyImageMagick(allocator: std.mem.Allocator, io: std.Io, log: ILog) !ImageMagickStatus {
        const result = tool_run.runChecked(allocator, io, log, .magick, &.{"-version"}) catch |err| {
            return imageMagickFailed(allocator, err);
        };
        return imageMagickRan(result);
    }

    //
    // The status of ImageMagick when its `-version` failed with the error: not available, with the error.
    //
    pub fn imageMagickFailed(allocator: std.mem.Allocator, err: anyerror) !ImageMagickStatus {
        return .{
            .available = false,
            .@"error" = try std.fmt.allocPrint(allocator, "The ImageMagick built into the program did not run: {s}", .{try utils.errors.errorToString(allocator, err)}),
        };
    }

    //
    // The status of ImageMagick when its `-version` printed the output: available, with the version, or "unknown" when the output
    // names none.
    //
    pub fn imageMagickRan(versionOutput: []const u8) ImageMagickStatus {
        return .{
            .available = true,
            .version = imageMagickVersion(versionOutput),
        };
    }

    //
    // The width and height in what `identify -format "%w %h\n"` printed, each read with parseInt, so a part that is missing or not a
    // number is NaN. Only the first line is read, because an animated image prints a line per frame.
    //
    pub fn dimensionsFromIdentify(output: []const u8) Dimensions {
        var lines = std.mem.splitScalar(u8, utils.js_string.trim(output), '\n');
        var parts = std.mem.splitScalar(u8, lines.first(), ' ');
        const width = parseInt(parts.next() orelse "undefined", null);
        const height = parseInt(parts.next() orelse "undefined", null);
        return .{
            .width = width,
            .height = height,
        };
    }

    //
    // Reads the dimensions of the image, and its date from the EXIF when it has one.
    //
    fn getImageInfo(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !AssetInfo {
        if (self._info) |info| {
            return info;
        }

        const dimensions = try self.readDimensions(allocator, io, log);

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
    // Reads the width and height of the image with one `identify -format "%w %h\n"`, and nothing else. An animated image prints a line
    // per frame, so only the first line is read: without the newline the frames run together and 43x17 reads as 43 by 1743.
    //
    fn readDimensions(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !Dimensions {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Get format, dimensions
        const result = try tool_run.runLogged(allocator, io, log, .magick, &.{ "identify", "-format", "%w %h\n", self.filePath }, null);
        return dimensionsFromIdentify(result);
    }

    //
    // Gets the width and height of the image. When getInfo has already read the image its answer is used; otherwise only the
    // size is asked for, because the EXIF identify getInfo also runs is a second pass over the file that a caller wanting the
    // size alone has no use for.
    //
    pub fn getDimensions(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !Dimensions {
        if (self._info) |info| {
            return info.dimensions;
        }
        return self.readDimensions(allocator, io, log);
    }

    //
    // Gets the information about the image.
    //
    pub fn getInfo(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !AssetInfo {
        return self.getImageInfo(allocator, io, log);
    }

    //
    // Get EXIF data from the image
    //
    pub fn getExifData(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) !std.StringArrayHashMapUnmanaged([]const u8) {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        const result = tool_run.runLogged(allocator, io, log, .magick, &.{ "identify", "-format", "%[EXIF:*]", self.filePath }, null) catch |err| {
            return errors.throwError("Failed to get EXIF data: {s}", .{try utils.errors.errorToString(allocator, err)});
        };

        return parseExifOutput(allocator, result);
    }

    //
    // Reads the EXIF tags out of the output of `identify -format "%[EXIF:*]"` (the loop over its lines in getExifData).
    //
    pub fn parseExifOutput(allocator: std.mem.Allocator, stdout: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
        var exifData: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, utils.js_string.trim(stdout), '\n');

        while (lines.next()) |line| {
            // The pattern is `exif:([^=]+)=(.*)`. The first "exif:" followed by at least one character that
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
    // The state the resize validation reads.
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
    pub fn resize(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog, options: ResizeOptions, tempDir: []const u8, uuidGenerator: IUuidGenerator) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        const width = options.width;
        const height = options.height;
        const maintainAspectRatio = options.maintainAspectRatio orelse true;
        const baseOutputPath = try join(allocator, &.{ tempDir, try std.mem.concat(allocator, u8, &.{ "temp_resize_", try uuidGenerator.generate(allocator, io) }) });
        const outputPath1 = try std.mem.concat(allocator, u8, &.{ baseOutputPath, ".", options.ext });
        const outputPath2 = try std.mem.concat(allocator, u8, &.{ baseOutputPath, "-0.", options.ext });

        if (pathExists(io, outputPath1)) {
            return errors.throwError("Output file already exists: {s}", .{outputPath1});
        }

        if (pathExists(io, outputPath2)) {
            return errors.throwError("Output file already exists: {s}", .{outputPath2});
        }

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
        var arguments: std.ArrayList([]const u8) = .empty;
        try arguments.appendSlice(allocator, &.{ self.filePath, "-resize", geometry, "-strip" });

        // Add quality if specified
        if (options.quality) |quality| {
            if (quality < 0 or quality > 100) {
                return errors.throwError("Quality must be between 0 and 100", .{});
            }
            try arguments.appendSlice(allocator, &.{ "-quality", try numberText(allocator, quality) });
        }

        // Add format specification and output file
        if (options.format != null and options.format.?.len > 0) {
            // For explicit format conversion, specify the format before the output path
            try arguments.append(allocator, try std.mem.concat(allocator, u8, &.{ options.format.?, ":", outputPath1 }));
        }
        else {
            try arguments.append(allocator, outputPath1);
        }

        var validation: IResizeValidation = .{
            .outputPath1 = outputPath1,
            .outputPath2 = outputPath2,
            .actualOutputPath = outputPath1,
        };

        _ = try tool_run.runLogged(allocator, io, log, .magick, arguments.items, .{ .context = &validation, .function = IResizeValidation.validate });

        return validation.actualOutputPath;
    }

    //
    // Extract the dominant color from the image using ImageMagick
    // Returns RGB values as [r, g, b] array
    //
    pub fn getDominantColor(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog) ![3]f64 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        // Method 1: Simple resize to 1x1 pixel (fastest, good for average color)
        const result = tool_run.runLogged(allocator, io, log, .magick, &.{ self.filePath, "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" }, null) catch |err| {
            return errors.throwError("Failed to extract dominant color: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
        return dominantColorFromOutput(allocator, result);
    }

    //
    // The colour in what getDominantColor's ImageMagick command printed, "r,g,b". Fails with "Failed to extract dominant color: " and
    // the reason when that is not three whole numbers from 0 to 255.
    //
    pub fn dominantColorFromOutput(allocator: std.mem.Allocator, output: []const u8) ![3]f64 {
        return dominantColorFromOutputInner(allocator, output) catch |err| {
            return errors.throwError("Failed to extract dominant color: {s}", .{try utils.errors.errorToString(allocator, err)});
        };
    }

    //
    // The body of the try block of dominantColorFromOutput.
    //
    fn dominantColorFromOutputInner(allocator: std.mem.Allocator, output: []const u8) ![3]f64 {
        const rgbString = utils.js_string.trim(output);
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
    pub fn transform(self: *Image, allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IImageTransformation, tempDir: []const u8, uuidGenerator: IUuidGenerator) ![]const u8 {
        if (!pathExists(io, self.filePath)) {
            return errors.throwError("File not found: {s}", .{self.filePath});
        }

        var operations: std.ArrayList([]const u8) = .empty;

        if (options.flipX orelse false) {
            try operations.append(allocator, "-flop");
        }

        if (options.rotate) |rotate| {
            if (isTruthy(rotate)) {
                try operations.appendSlice(allocator, &.{ "-rotate", try numberText(allocator, rotate) });
            }
        }

        if (operations.items.len > 0) {
            // Transform to a temporary file and return the path.
            const outputPath = try join(allocator, &.{ tempDir, try std.fmt.allocPrint(allocator, "temp_transform_output_{s}.jpg", .{try uuidGenerator.generate(allocator, io)}) });
            var arguments: std.ArrayList([]const u8) = .empty;
            try arguments.append(allocator, self.filePath);
            try arguments.appendSlice(allocator, operations.items);
            try arguments.append(allocator, outputPath);
            _ = try tool_run.runLogged(allocator, io, log, .magick, arguments.items, null);

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
};

//
// JavaScript truthiness of a number.
//
fn isTruthy(value: f64) bool {
    return value != 0 and !std.math.isNan(value);
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

//
// The text of a number as it goes into a command: the number as JavaScript writes it.
//
fn numberText(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try utils.js_number.writeNumber(&output.writer, number);
    return output.written();
}

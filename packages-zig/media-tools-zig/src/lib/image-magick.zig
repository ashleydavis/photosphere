const std = @import("std");
const utils = @import("utils-zig");
const ILog = utils.log.ILog;
// The C interface of ImageMagick (MagickCore, through MagickWand.h), for code and tests that need more of it than the functions here.
pub const c = @import("magick");

//
// ImageMagick, built into the program and called through MagickCore, its C library: each function here reads, changes or writes an
// image with typed arguments, on whichever thread calls it, with no setup and no teardown.
//
// No setup, no global and no lock of the program's own:
//
//   * ImageMagick's state for the whole process is started by MagickCoreGenesis, which every function here calls first.
//     MagickCoreGenesis is ImageMagick's own once-only step: it takes a mutex ImageMagick initialises statically (a pthread mutex
//     made with PTHREAD_MUTEX_INITIALIZER, or an interlocked flag on Windows, in MagickCore/mutex.h), and returns at once when the
//     state is already started. Nothing stops ImageMagick: the process's end frees what it holds.
//   * Each call gives ImageMagick an ExceptionInfo of its own and reads the warnings and errors back out of it. ImageMagick's warning
//     and error handlers, which are the process's, are left as they are: MagickCore only calls them through CatchException, which
//     nothing here calls.
//   * The security policy is ImageMagick's own state too, and is applied by the same first step (see applySecurityPolicy).
//

//
// The security policy. The library is built with zero configuration, so it reads no policy.xml and applies no policy of its own.
// The policy denies:
//
//   * The coders that reach outside the file being read or run a script: the URL coders (HTTP, HTTPS, FTP), MSL, MVG, MSVG, TEXT and
//     TXT (which read a text description as an image), EPHEMERAL (which deletes the file it reads), and the display coders SHOW, WIN
//     and X. Every other coder stays allowed, because the import reads whatever image type the user has.
//   * Every delegate, since none is meant to run a program.
//   * Indirect reads, `@file`, which read a list of other paths from a file.
//
const security_policy =
    \\<policymap>
    \\  <policy domain="coder" rights="none" pattern="{URL,HTTP,HTTPS,FTP,MSL,MVG,MSVG,TEXT,TXT,EPHEMERAL,SHOW,WIN,X}"/>
    \\  <policy domain="delegate" rights="none" pattern="*"/>
    \\  <policy domain="path" rights="none" pattern="@*"/>
    \\</policymap>
;

//
// The version of ImageMagick built into the program, as `magick -version` names it ("7.1.2-33").
//
pub fn version() []const u8 {
    return c.MagickLibVersionText ++ c.MagickLibAddendum;
}

//
// The quantum depth and HDRI of the ImageMagick built into the program ("Q16-HDRI"), as `magick -version` names them.
//
pub fn quantum() []const u8 {
    return c.MagickQuantumDepth ++ c.MagickHDRISupport;
}

//
// The delegate libraries ImageMagick is built with ("jpeg png webp zlib"), as `magick -version` lists them.
//
pub fn delegates() ![]const u8 {
    try startImageMagick();
    return std.mem.span(c.GetMagickDelegates());
}

//
// Checks that ImageMagick starts, with its security policy, starting it when it is not started yet. Nothing needs to call it before
// using ImageMagick; it is for reporting whether the ImageMagick built into the program works.
//
pub fn check() !void {
    try startImageMagick();
}

//
// Starts ImageMagick for the process when it is not started yet, and applies the security policy when it is not applied yet. Every
// function here calls it first, so whichever is called first, on whichever thread, starts ImageMagick.
//
fn startImageMagick() !void {
    c.MagickCoreGenesis(null, c.MagickFalse);
    try applySecurityPolicy();
}

//
// Applies the security policy unless ImageMagick already has it.
//
// The policy is read back from ImageMagick rather than remembered in the program: it is in place when MVG, which it denies and which
// ImageMagick allows with no policy, may not be read. ImageMagick loads a policy into its policy list in one step under its own
// policy semaphore (SetMagickSecurityPolicy), and reads the list under the same semaphore (IsRightsAuthorized), so a thread sees
// either none of the policy or all of it. Two threads that both find it missing both apply it, and the list then holds its rules
// twice, which denies exactly what it denied once; after that every call finds it in place.
//
fn applySecurityPolicy() !void {
    if (c.IsRightsAuthorized(c.CoderPolicyDomain, c.ReadPolicyRights, "MVG") == c.MagickFalse) {
        return;
    }
    const exception = c.AcquireExceptionInfo();
    defer _ = c.DestroyExceptionInfo(exception);
    if (c.SetMagickSecurityPolicy(security_policy, exception) != c.MagickTrue) {
        const reason: []const u8 = if (exception.*.reason != null) std.mem.span(exception.*.reason) else "no reason given";
        const description: []const u8 = if (exception.*.description != null) std.mem.span(exception.*.description) else "";
        return utils.errors.throwError("The ImageMagick security policy could not be set: {s} {s}", .{ reason, description });
    }
}

//
// The size and format of an image.
//
pub const IImageInfo = struct {
    // The width, in pixels.
    width: usize,

    // The height, in pixels.
    height: usize,

    // ImageMagick's name of the format the file holds ("JPEG", "PNG", "WEBP").
    format: []const u8,
};

//
// Reads the size and format of the first frame of the image at the path, without decoding its pixels (ImageMagick's ping, which
// `identify` uses). The path is given to ImageMagick as a file name, so a prefix such as `png:` names the format.
//
pub fn readImageInfo(allocator: std.mem.Allocator, log: ILog, path: []const u8) !IImageInfo {
    log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick: reading the size of {s}", .{path}));
    var call = try Call.start(allocator, log, "read the size of", path);
    defer call.end();
    const image = try call.read(path, .ping);
    defer _ = c.DestroyImageList(image);
    try call.finish();
    return .{
        .width = image.*.columns,
        .height = image.*.rows,
        .format = try allocator.dupe(u8, std.mem.sliceTo(&@as(*c.Image, image).magick, 0)),
    };
}

//
// Reads the EXIF tags of the first frame of the image at the path, without decoding its pixels: each tag's name (without ImageMagick's
// `exif:` prefix, so "Make" or "DateTimeOriginal") and its value as ImageMagick writes it. An image with no EXIF has none.
//
pub fn readExif(allocator: std.mem.Allocator, log: ILog, path: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick: reading the EXIF of {s}", .{path}));
    var call = try Call.start(allocator, log, "read the EXIF of", path);
    defer call.end();
    const image = try call.read(path, .ping);
    defer _ = c.DestroyImageList(image);
    // ImageMagick makes the exif: properties from the image's EXIF profile when one of them is asked for.
    _ = c.GetImageProperty(image, "exif:*", call.exception);
    var tags: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    c.ResetImagePropertyIterator(image);
    while (c.GetNextImageProperty(image)) |name_pointer| {
        const name = std.mem.span(name_pointer);
        if (name.len <= "exif:".len or !std.ascii.eqlIgnoreCase(name[0.."exif:".len], "exif:")) {
            continue;
        }
        const value = c.GetImageProperty(image, name_pointer, call.exception) orelse continue;
        try tags.put(allocator, try allocator.dupe(u8, name["exif:".len..]), try allocator.dupe(u8, std.mem.span(value)));
    }
    try call.finish();
    return tags;
}

//
// A size to resize an image to.
//
pub const IResizeOptions = struct {
    // The image to read; only its first frame is resized.
    input_path: []const u8,

    // The file to write, which is made or replaced.
    output_path: []const u8,

    // The width to resize to, or null to take it from the height, keeping the aspect ratio. One of width and height is given.
    width: ?usize,

    // The height to resize to, or null to take it from the width, keeping the aspect ratio.
    height: ?usize,

    // When both width and height are given: true makes the image exactly that size, false fits it inside them keeping its aspect
    // ratio.
    exact: bool,

    // The quality to write at, from 0 to 100, or null for the format's default (for a JPEG, the quality of the JPEG read).
    quality: ?u8,

    // ImageMagick's name of the format to write ("JPEG", "PNG", "WEBP").
    format: []const u8,
};

//
// The width and height an image of the given size is resized to: what ImageMagick's `-resize` makes of the geometry the options
// name ("WxH", "WxH!", "Wx" or "xH"), as ParseMetaGeometry in MagickCore/geometry.c works it out.
//
pub fn resizeSize(columns: usize, rows: usize, width: ?usize, height: ?usize, exact: bool) !IImageSize {
    if (width == null and height == null) {
        return utils.errors.throwError("A resize needs a width or a height.", .{});
    }
    const target_width = width orelse columns;
    const target_height = height orelse rows;
    if (exact or (target_width == columns and target_height == rows)) {
        return .{
            .width = target_width,
            .height = target_height,
        };
    }
    var scale: f64 = 1.0;
    if (columns != 0 and rows != 0) {
        if (width != null and height != null) {
            scale = @as(f64, @floatFromInt(target_width)) / @as(f64, @floatFromInt(columns));
            const height_scale = @as(f64, @floatFromInt(target_height)) / @as(f64, @floatFromInt(rows));
            if (scale > height_scale) {
                scale = height_scale;
            }
        }
        else if (width != null) {
            scale = @as(f64, @floatFromInt(target_width)) / @as(f64, @floatFromInt(columns));
        }
        else {
            scale = @as(f64, @floatFromInt(target_height)) / @as(f64, @floatFromInt(rows));
        }
    }
    return .{
        .width = @intFromFloat(@max(@floor(scale * @as(f64, @floatFromInt(columns)) + 0.5), 1.0)),
        .height = @intFromFloat(@max(@floor(scale * @as(f64, @floatFromInt(rows)) + 0.5), 1.0)),
    };
}

//
// A width and a height, in pixels.
//
pub const IImageSize = struct {
    // The width.
    width: usize,

    // The height.
    height: usize,
};

//
// Resizes the first frame of the image as the options say, removes every profile and comment from it (the EXIF, the XMP and the
// colour profile, which is what `-strip` does), and writes it to the output path in the format the options name.
//
// The profiles are dropped because a resize otherwise carries the original's profiles into it, and a photo from a modern phone brings
// an XMP block of tens of kilobytes: the forty pixel thumbnail stored inside every asset record was coming out at fifty kilobytes of
// somebody else's metadata, which the database then wrote into both of its sort index pages and rewrote whole on every commit. The
// original is stored untouched and keeps everything, including the colour profile a derivative loses.
//
pub fn resizeImage(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IResizeOptions) !void {
    log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick: resizing {s} to {?d}x{?d} ({s}) as {s} at quality {?d}, into {s}", .{
        options.input_path,
        options.width,
        options.height,
        if (options.exact) "exactly" else "keeping the aspect ratio",
        options.format,
        options.quality,
        options.output_path,
    }));
    var call = try Call.start(allocator, log, "resize", options.input_path);
    defer call.end();
    const image = try call.read(options.input_path, .first_frame);
    defer _ = c.DestroyImageList(image);
    const size = try resizeSize(image.*.columns, image.*.rows, options.width, options.height, options.exact);
    const resized = c.ResizeImage(image, size.width, size.height, image.*.filter, call.exception) orelse {
        return call.fail();
    };
    defer _ = c.DestroyImageList(resized);
    if (c.StripImage(resized, call.exception) != c.MagickTrue) {
        return call.fail();
    }
    try call.write(io, resized, options.output_path, options.format, options.quality);
    try call.finish();
}

//
// A turn and a mirroring of an image, each applied when it is set, in the order of the fields.
//
pub const ITurn = struct {
    // Mirror the image left to right (ImageMagick's flop).
    flop: bool = false,

    // Mirror the image top to bottom (ImageMagick's flip).
    flip: bool = false,

    // Mirror the image in its diagonal from the top left to the bottom right (ImageMagick's transpose).
    transpose: bool = false,

    // Mirror the image in its diagonal from the top right to the bottom left (ImageMagick's transverse).
    transverse: bool = false,

    // Turn the image clockwise by this many degrees; 0 leaves it.
    rotate_degrees: f64 = 0,

    //
    // Whether the turn changes the image at all.
    //
    pub fn isNone(self: ITurn) bool {
        return !self.flop and !self.flip and !self.transpose and !self.transverse and self.rotate_degrees == 0;
    }
};

//
// Options for transformImage.
//
pub const ITransformOptions = struct {
    // The image to read; only its first frame is turned.
    input_path: []const u8,

    // The file to write, which is made or replaced.
    output_path: []const u8,

    // The turn to apply.
    turn: ITurn,

    // ImageMagick's name of the format to write ("JPEG").
    format: []const u8,
};

//
// Turns and mirrors the first frame of the image as the options say and writes it to the output path in the format they name, at
// the format's default quality (for a JPEG read, the quality it was written at), keeping its profiles.
//
pub fn transformImage(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: ITransformOptions) !void {
    log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick: turning {s} (flop {}, flip {}, transpose {}, transverse {}, rotate {d} degrees) as {s}, into {s}", .{
        options.input_path,
        options.turn.flop,
        options.turn.flip,
        options.turn.transpose,
        options.turn.transverse,
        options.turn.rotate_degrees,
        options.format,
        options.output_path,
    }));
    var call = try Call.start(allocator, log, "turn", options.input_path);
    defer call.end();
    const image = try call.read(options.input_path, .first_frame);
    const turned = try call.applyTurn(image, options.turn);
    defer _ = c.DestroyImageList(turned);
    try call.write(io, turned, options.output_path, options.format, null);
    try call.finish();
}

//
// The mean colour of the first frame of the image at the path: the image resized to one pixel (`-resize 1x1!`), and each of that
// pixel's red, green and blue as a whole number from 0 to 255, rounded down (`%[fx:int(mean.r*255)]`).
//
pub fn dominantColor(allocator: std.mem.Allocator, log: ILog, path: []const u8) ![3]u8 {
    log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick: reading the mean colour of {s}", .{path}));
    var call = try Call.start(allocator, log, "read the mean colour of", path);
    defer call.end();
    const image = try call.read(path, .first_frame);
    defer _ = c.DestroyImageList(image);
    const pixel_image = c.ResizeImage(image, 1, 1, image.*.filter, call.exception) orelse {
        return call.fail();
    };
    defer _ = c.DestroyImageList(pixel_image);
    var pixel: c.PixelInfo = undefined;
    if (c.GetOneVirtualPixelInfo(pixel_image, c.UndefinedVirtualPixelMethod, 0, 0, &pixel, call.exception) != c.MagickTrue) {
        return call.fail();
    }
    try call.finish();
    const quantum_range: f64 = c.QuantumRange;
    return .{
        try colorComponent(pixel.red / quantum_range),
        try colorComponent(pixel.green / quantum_range),
        try colorComponent(pixel.blue / quantum_range),
    };
}

//
// A colour component from 0 to 1 as a whole number from 0 to 255, rounded down. Fails for a component outside 0 to 1, which a
// high dynamic range image can hold.
//
pub fn colorComponent(component: f64) !u8 {
    const scaled = @floor(component * 255);
    if (std.math.isNan(scaled) or scaled < 0 or scaled > 255) {
        return utils.errors.throwError("The colour component {d} is outside 0 to 1.", .{component});
    }
    return @intFromFloat(scaled);
}

//
// Pixels of eight bit red, green and blue, one byte each, a row after another with no gap.
//
pub const IRgbPixels = struct {
    // The width, in pixels.
    width: usize,

    // The height, in pixels.
    height: usize,

    // The bytes, width * height * 3 of them.
    bytes: []const u8,
};

//
// Options for writeRgbImage.
//
pub const IWriteRgbOptions = struct {
    // What the pixels are of, for messages ("the frame at 3.9 seconds of video.mp4").
    source: []const u8,

    // The file to write, which is made or replaced.
    output_path: []const u8,

    // The turn to apply before writing.
    turn: ITurn,

    // ImageMagick's name of the format to write ("JPEG").
    format: []const u8,

    // The quality to write at, from 0 to 100.
    quality: u8,
};

//
// Makes an image of the pixels, turns it as the options say and writes it to the output path in their format and quality.
//
pub fn writeRgbImage(allocator: std.mem.Allocator, io: std.Io, log: ILog, pixels: IRgbPixels, options: IWriteRgbOptions) !void {
    if (pixels.bytes.len != pixels.width * pixels.height * 3) {
        return utils.errors.throwError("{d} bytes are not the {d}x{d} pixels of {s}.", .{ pixels.bytes.len, pixels.width, pixels.height, options.source });
    }
    log.verbose(try std.fmt.allocPrint(allocator, "ImageMagick: writing {s}, {d}x{d}, as {s} at quality {d}, into {s}", .{
        options.source,
        pixels.width,
        pixels.height,
        options.format,
        options.quality,
        options.output_path,
    }));
    var call = try Call.start(allocator, log, "write", options.source);
    defer call.end();
    const image = c.ConstituteImage(pixels.width, pixels.height, "RGB", c.CharPixel, pixels.bytes.ptr, call.exception) orelse {
        return call.fail();
    };
    const turned = try call.applyTurn(image, options.turn);
    defer _ = c.DestroyImageList(turned);
    try call.write(io, turned, options.output_path, options.format, options.quality);
    try call.finish();
}

//
// How much of a file a read decodes.
//
const IReadMode = enum {
    // The size, format and profiles of the first frame, without its pixels.
    ping,

    // The first frame, with its pixels.
    first_frame,
};

//
// One call into ImageMagick: the ExceptionInfo ImageMagick leaves the call's warnings and errors in, and what the call is, for its
// messages.
//
const Call = struct {
    // The allocator the call's messages are made with.
    allocator: std.mem.Allocator,

    // The log the call's warnings go to.
    log: ILog,

    // What the call does ("resize"), for messages.
    operation: []const u8,

    // The file the call reads, for messages.
    subject: []const u8,

    // The call's own ExceptionInfo.
    exception: [*c]c.ExceptionInfo,

    //
    // Starts ImageMagick when it is not started, and a call.
    //
    fn start(allocator: std.mem.Allocator, log: ILog, operation: []const u8, subject: []const u8) !Call {
        try startImageMagick();
        return .{
            .allocator = allocator,
            .log = log,
            .operation = operation,
            .subject = subject,
            .exception = c.AcquireExceptionInfo(),
        };
    }

    //
    // Frees the call's ExceptionInfo.
    //
    fn end(self: *Call) void {
        _ = c.DestroyExceptionInfo(self.exception);
    }

    //
    // Reads the file at the path, or fails with ImageMagick's messages. ImageMagick reads the path as a file name, so a `png:` prefix
    // names the format and a trailing `[...]` picks frames, as on the command line.
    //
    fn read(self: *Call, path: []const u8, mode: IReadMode) ![*c]c.Image {
        const image_info = c.AcquireImageInfo();
        defer _ = c.DestroyImageInfo(image_info);
        if (!setText(&@as(*c.ImageInfo, image_info).filename, path)) {
            return utils.errors.throwError("ImageMagick could not {s} {s}: the path is longer than the {d} bytes ImageMagick takes.", .{ self.operation, path, image_info.*.filename.len - 1 });
        }
        image_info.*.scene = 0;
        image_info.*.number_scenes = 1;
        const image = switch (mode) {
            .ping => c.PingImage(image_info, self.exception),
            .first_frame => c.ReadImage(image_info, self.exception),
        };
        if (image == null) {
            return self.fail();
        }
        if (self.failed()) {
            _ = c.DestroyImageList(image);
            return self.fail();
        }
        return image;
    }

    //
    // Applies the turn to the image and returns the turned image, freeing the image given, which is freed when the turn fails too.
    //
    fn applyTurn(self: *Call, image: [*c]c.Image, turn: ITurn) ![*c]c.Image {
        var current = image;
        errdefer _ = c.DestroyImageList(current);
        if (turn.flop) {
            current = try self.replace(current, c.FlopImage(current, self.exception));
        }
        if (turn.flip) {
            current = try self.replace(current, c.FlipImage(current, self.exception));
        }
        if (turn.transpose) {
            current = try self.replace(current, c.TransposeImage(current, self.exception));
        }
        if (turn.transverse) {
            current = try self.replace(current, c.TransverseImage(current, self.exception));
        }
        if (turn.rotate_degrees != 0) {
            current = try self.replace(current, c.RotateImage(current, turn.rotate_degrees, self.exception));
        }
        return current;
    }

    //
    // Frees the image an operation was given and returns the image the operation made, or fails when it made none.
    //
    fn replace(self: *Call, image: [*c]c.Image, made: [*c]c.Image) ![*c]c.Image {
        if (made == null) {
            return self.fail();
        }
        _ = c.DestroyImageList(image);
        return made;
    }

    //
    // Encodes the image in the format, at the quality when one is given, and writes it to the path. The image is encoded in memory and
    // the bytes written by the program, so ImageMagick reads nothing into the path: it may hold any character.
    //
    fn write(self: *Call, io: std.Io, image: [*c]c.Image, path: []const u8, format: []const u8, quality: ?u8) !void {
        const image_info = c.AcquireImageInfo();
        defer _ = c.DestroyImageInfo(image_info);
        // ImageToBlob encodes the image in the format the image names when the ImageInfo names none.
        if (!setText(&@as(*c.Image, image).magick, format)) {
            return utils.errors.throwError("ImageMagick has no format named {s}.", .{format});
        }
        if (quality) |value| {
            if (value > 100) {
                return utils.errors.throwError("Quality must be between 0 and 100", .{});
            }
            image_info.*.quality = value;
            // The JPEG and WebP coders read the quality of the image, which the `magick` program sets from its `-quality`.
            image.*.quality = value;
        }
        var length: usize = 0;
        const blob = c.ImageToBlob(image_info, image, &length, self.exception);
        defer if (blob != null) {
            _ = c.RelinquishMagickMemory(blob);
        };
        if (blob == null or self.failed()) {
            return self.fail();
        }
        const bytes: [*]const u8 = @ptrCast(blob.?);
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = bytes[0..length],
        }) catch |err| {
            return utils.errors.throwError("ImageMagick could not {s} {s}: writing {s} failed: {s}", .{ self.operation, self.subject, path, @errorName(err) });
        };
    }

    //
    // Whether ImageMagick has reported an error, rather than only warnings.
    //
    fn failed(self: *Call) bool {
        return self.exception.*.severity >= c.ErrorException;
    }

    //
    // Fails the call with ImageMagick's messages.
    //
    fn fail(self: *Call) error{ Thrown, OutOfMemory } {
        const messages = exceptionMessages(self.allocator, self.exception) catch return error.OutOfMemory;
        return utils.errors.throwError("ImageMagick could not {s} {s}: {s}", .{
            self.operation,
            self.subject,
            if (messages.len > 0) messages else "it gave no reason.",
        });
    }

    //
    // Ends a call that worked: fails it if ImageMagick reported an error after all, and otherwise sends its warnings to the log as
    // ImageMagick's output.
    //
    fn finish(self: *Call) !void {
        if (self.failed()) {
            return self.fail();
        }
        const messages = try exceptionMessages(self.allocator, self.exception);
        if (messages.len > 0) {
            self.log.tool("magick", .{
                .stdout = null,
                .stderr = try std.fmt.allocPrint(self.allocator, "{s} {s}: {s}", .{ self.operation, self.subject, messages }),
            });
        }
    }
};

//
// Puts the text in a field of ImageMagick's that holds a C string, ending it with a zero. False when the text does not fit.
//
fn setText(field: []u8, text: []const u8) bool {
    if (text.len >= field.len) {
        return false;
    }
    @memcpy(field[0..text.len], text);
    field[text.len] = 0;
    return true;
}

//
// ImageMagick's messages in the exception, each on a line of its own as ImageMagick's own handlers print one (MagickCore/
// exception.c): the reason and, in brackets, the description. Empty when there are none.
//
fn exceptionMessages(allocator: std.mem.Allocator, exception: [*c]c.ExceptionInfo) ![]const u8 {
    var messages: std.ArrayList(u8) = .empty;
    const list: ?*c.LinkedListInfo = @ptrCast(exception.*.exceptions);
    if (list == null) {
        return "";
    }
    c.ResetLinkedListIterator(list);
    while (c.GetNextValueInLinkedList(list)) |value| {
        const entry: *const c.ExceptionInfo = @ptrCast(@alignCast(value));
        if (entry.reason == null) {
            continue;
        }
        try messages.appendSlice(allocator, std.mem.span(entry.reason));
        if (entry.description != null) {
            try messages.print(allocator, " ({s})", .{std.mem.span(entry.description)});
        }
        try messages.appendSlice(allocator, ".\n");
    }
    return messages.items;
}

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const media_tools = @import("media-tools-zig");
const Image = tools.Image;
const MediaTools = media_tools.MediaTools;

//
// Generates the same ID every time, so the output paths are known.
//
const FixedUuidGenerator = struct {
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
        _ = ptr;
        _ = allocator;
        _ = io;
        return "fixed";
    }
};

//
// The absolute path of a test's temporary directory.
//
fn tempDirPath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path });
}

//
// Expects dominantColorFromOutput to refuse what ImageMagick printed when it is not three numbers between 0 and 255.
//
fn expectDominantColorRefusal(allocator: std.mem.Allocator, output: []const u8) !void {
    try std.testing.expectError(error.Thrown, Image.dominantColorFromOutput(allocator, output));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Failed to extract dominant color: Error: Invalid RGB values: {s}", .{output}), utils.errors.lastErrorMessage());
}

test "dimensionsFromIdentify reads a width and a height of NaN from output ImageMagick did not write" {
    // identify printing "100" with no height gives the width and finds nothing for the height.
    const widthOnly = Image.dimensionsFromIdentify("100");
    try std.testing.expectEqual(@as(f64, 100), widthOnly.width);
    try std.testing.expect(std.math.isNan(widthOnly.height));

    // Output with no width at all is NaN for both.
    const blank = Image.dimensionsFromIdentify("");
    try std.testing.expect(std.math.isNan(blank.width));
    try std.testing.expect(std.math.isNan(blank.height));
}

test "dimensionsFromIdentify reads only the first line, so the frames of an animated image do not run together" {
    // An animated image prints a line per frame. Reading past the first line would make 43x17 read as 43 by 1743.
    const animated = Image.dimensionsFromIdentify("43 17\n43 17\n43 17\n");
    try std.testing.expectEqual(@as(f64, 43), animated.width);
    try std.testing.expectEqual(@as(f64, 17), animated.height);
}

//
// A log that keeps the verbose messages tool_run.runLogged writes as it starts each command, so a test can see every command run,
// in order, and ignores everything else.
//
const CommandLog = struct {
    // Every "Executing ..." message the log was given, one per command run.
    commands: std.ArrayList([]const u8),

    // The allocator the messages are kept with.
    allocator: std.mem.Allocator,

    //
    // Keeps a verbose message that starts a command.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        const self: *CommandLog = @ptrCast(@alignCast(ptr));
        if (std.mem.startsWith(u8, message, "Executing ")) {
            self.commands.append(self.allocator, self.allocator.dupe(u8, message) catch @panic("out of memory keeping a command")) catch @panic("out of memory keeping a command");
        }
    }

    //
    // Ignores a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Ignores an error.
    //
    fn ignoreException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        _ = message;
        _ = @intFromError(err);
    }

    //
    // Ignores a tool's output.
    //
    fn ignoreTool(ptr: *anyopaque, tool_name: []const u8, data: utils.log.IToolOutput) void {
        _ = ptr;
        _ = tool_name;
        _ = data;
    }

    //
    // Verbose logging is on, since the commands are verbose messages.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    //
    // The log has no file.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return utils.log.noLogDetails;
    }

    //
    // This log writes no file.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        _ = ptr;
        return null;
    }

    // The ILog functions of the log.
    const vtable: utils.log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = verbose,
        .@"error" = ignoreMessage,
        .exception = ignoreException,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = ignoreTool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };

    //
    // The ILog of the log.
    //
    fn ilog(self: *CommandLog) utils.log.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "getDimensions runs only the size identify, and getInfo runs the EXIF identify as well" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();

    // The real ImageMagick reads the checked in test.png, which is 100x90.
    var sizeOnly: CommandLog = .{
        .commands = .empty,
        .allocator = allocator,
    };
    var image = Image.init("../test/test.png");
    const dimensions = try image.getDimensions(allocator, io, sizeOnly.ilog());
    try std.testing.expectEqual(@as(f64, 100), dimensions.width);
    try std.testing.expectEqual(@as(f64, 90), dimensions.height);
    try std.testing.expectEqual(@as(usize, 1), sizeOnly.commands.items.len);
    try std.testing.expectEqualStrings("Executing magick with command: \"magick identify -format %w %h\n ../test/test.png\"", sizeOnly.commands.items[0]);

    // getInfo still reads the EXIF for createdAt, after the size.
    var full: CommandLog = .{
        .commands = .empty,
        .allocator = allocator,
    };
    var withInfo = Image.init("../test/test.png");
    const info = try withInfo.getInfo(allocator, io, full.ilog());
    try std.testing.expectEqual(dimensions, info.dimensions);
    try std.testing.expectEqual(@as(usize, 2), full.commands.items.len);
    try std.testing.expectEqualStrings("Executing magick with command: \"magick identify -format %w %h\n ../test/test.png\"", full.commands.items[0]);
    try std.testing.expectEqualStrings("Executing magick with command: \"magick identify -format %[EXIF:*] ../test/test.png\"", full.commands.items[1]);

    // Once getInfo has read the image, getDimensions answers from it without running anything more.
    try std.testing.expectEqual(info.dimensions, try withInfo.getDimensions(allocator, io, full.ilog()));
    try std.testing.expectEqual(@as(usize, 2), full.commands.items.len);
}

test "getInfo reads the size identify prints and no date from an image with no EXIF" {
    // The real ImageMagick reads the checked in test.png, which is 100x90 and has no EXIF, so its EXIF output is empty and createdAt
    // stays null.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    var image = Image.init("../test/test.png");
    const info = try image.getInfo(arena.allocator(), std.testing.io, log);
    try std.testing.expectEqual(@as(f64, 100), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 90), info.dimensions.height);
    try std.testing.expect(info.createdAt == null);
}

test "dominantColorFromOutput refuses output that is not three values between 0 and 255" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Two values where three are needed.
    try expectDominantColorRefusal(allocator, "1,2");

    // A value past 255.
    try expectDominantColorRefusal(allocator, "256,0,0");

    // A value that is not a number at all.
    try expectDominantColorRefusal(allocator, "a,b,c");
}

test "imageMagickFailed reports an ImageMagick command that failed with no install advice, and verifyImageMagick remembers nothing of it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();

    // A real ImageMagick command that fails: reading a file that does not exist.
    const missing = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmp_dir), "missing.png" });
    const thrown = media_tools.tool_run.runChecked(allocator, io, log, .magick, &.{ "identify", missing });
    try std.testing.expectError(error.Thrown, thrown);
    const message = try allocator.dupe(u8, utils.errors.lastErrorMessage());
    try std.testing.expect(std.mem.startsWith(u8, message, try std.fmt.allocPrint(allocator, "Command failed: magick identify {s}\n", .{missing})));

    const failed = try Image.imageMagickFailed(allocator, error.Thrown);
    try std.testing.expect(!failed.available);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "The ImageMagick built into the program did not run: Error: {s}", .{message}), failed.@"error".?);
    try std.testing.expect(std.mem.indexOf(u8, failed.@"error".?, "install") == null);
    try std.testing.expect(failed.version == null);

    // Nothing is remembered from the failure, so the next check runs the built-in ImageMagick and finds it.
    const builtIn = try Image.verifyImageMagick(allocator, io, log);
    try std.testing.expect(builtIn.available);
    try std.testing.expect(builtIn.@"error" == null);
    try std.testing.expect(std.mem.startsWith(u8, builtIn.version.?, "7."));
}

test "resize and transform write their numbers as a template string writes a number" {
    // The real ImageMagick runs the commands, and the verbose log shows the command each one ran, argument by argument.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = true,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var mediaTools = try MediaTools.init();
    defer mediaTools.deinit();
    var uuids: FixedUuidGenerator = .{};
    var image = Image.init("../test/test.png");
    const tempDir = try tempDirPath(allocator, tmp_dir);

    // Both paths are passed as arguments of their own (`magick <file> -resize <geometry> -strip <output>`), unquoted. The output path is
    // joined with node-utils' path.join, as resize joins it.
    const resizeOutput = try std.mem.concat(allocator, u8, &.{ try node_utils.path.join(allocator, &.{ tempDir, "temp_resize_fixed" }), ".jpg" });
    const resizeCommand = try std.fmt.allocPrint(allocator, "Executing magick with command: \"magick ../test/test.png -resize 1e+21x -strip -quality 1e-7 {s}\"", .{resizeOutput});
    try std.testing.expectError(error.Thrown, image.resize(allocator, io, memory.log, .{ .width = 1e21, .height = 0, .quality = 1e-7, .format = null, .ext = "jpg" }, tempDir, uuids.uuidGenerator()));
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), resizeCommand) != null);

    const transformOutput = try node_utils.path.join(allocator, &.{ tempDir, "temp_transform_output_fixed.jpg" });
    const transformCommand = try std.fmt.allocPrint(allocator, "Executing magick with command: \"magick ../test/test.png -rotate 1e+21 {s}\"", .{transformOutput});
    try std.testing.expectEqualStrings(transformOutput, try image.transform(allocator, io, memory.log, .{ .rotate = 1e21 }, tempDir, uuids.uuidGenerator()));
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), transformCommand) != null);
}

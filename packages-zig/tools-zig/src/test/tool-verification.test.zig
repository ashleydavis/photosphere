const std = @import("std");
const utils = @import("utils-zig");
const MuteLog = utils.mute_log.MuteLog;
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const Image = tools.Image;
const Video = tools.Video;

//
// Calls the ImageMagick built into the program on a file that does not exist in the test's directory, which fails, so a status made
// from its error is the status of a tool that did not work. Returns the error's message.
//
fn failRealCall(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    const missing = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, "missing.png" });
    try std.testing.expectError(error.Thrown, media_tools.image_magick.readImageInfo(allocator, MuteLog.init(), missing));
    const message = try allocator.dupe(u8, utils.errors.lastErrorMessage());
    try std.testing.expect(std.mem.startsWith(u8, message, try std.fmt.allocPrint(allocator, "ImageMagick could not read the size of {s}: ", .{missing})));
    return message;
}

test "toolsStatus reports every tool with its version when ImageMagick, ffprobe and ffmpeg are available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const status = try tools.toolsStatus(arena.allocator(), .{
        .available = true,
        .version = "7.1.1-29",
    }, .{
        .available = true,
        .version = "6.1.1-3ubuntu5",
    }, .{
        .available = true,
        .version = "n7.0",
    });

    try std.testing.expect(status.allAvailable);
    try std.testing.expectEqual(@as(usize, 0), status.missingTools.len);
    try std.testing.expectEqualStrings("7.1.1-29", status.magick.version.?);
    try std.testing.expectEqualStrings("6.1.1-3ubuntu5", status.ffprobe.version.?);
    try std.testing.expectEqualStrings("n7.0", status.ffmpeg.version.?);
}

test "toolsStatus lists every missing tool when no tool is available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    _ = try failRealCall(allocator, tmp_dir);
    const magick = try Image.imageMagickFailed(allocator, error.Thrown);
    const status = try tools.toolsStatus(allocator, magick, .{
        .available = false,
        .@"error" = "The ffprobe built into the program did not run.",
    }, .{
        .available = false,
        .@"error" = "The ffmpeg built into the program did not run.",
    });

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 3), status.missingTools.len);
    try std.testing.expectEqualStrings("ImageMagick", status.missingTools[0]);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[1]);
    try std.testing.expectEqualStrings("ffmpeg", status.missingTools[2]);
    try std.testing.expect(std.mem.startsWith(u8, status.magick.@"error".?, "The ImageMagick built into the program did not run: "));
}

test "toolsStatus lists only the missing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const status = try tools.toolsStatus(allocator, .{
        .available = true,
        .version = "7.1.1-29",
    }, .{
        .available = false,
        .@"error" = "The ffprobe built into the program did not run.",
    }, .{
        .available = true,
        .version = "7.0",
    });

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 1), status.missingTools.len);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[0]);
    try std.testing.expect(status.magick.available);
    try std.testing.expect(status.ffmpeg.available);
}

test "imageMagickFailed reports an ImageMagick call that failed with no install advice, and verifyImageMagick remembers nothing of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const message = try failRealCall(allocator, tmp_dir);
    const failed = try Image.imageMagickFailed(allocator, error.Thrown);
    try std.testing.expect(!failed.available);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "The ImageMagick built into the program did not run: Error: {s}", .{message}), failed.@"error".?);
    try std.testing.expect(std.mem.indexOf(u8, failed.@"error".?, "install") == null);
    try std.testing.expect(failed.version == null);

    // Nothing is remembered from the failure, so the next check finds the built-in ImageMagick.
    const builtIn = try Image.verifyImageMagick(allocator);
    try std.testing.expect(builtIn.available);
    try std.testing.expect(builtIn.@"error" == null);
    try std.testing.expect(std.mem.startsWith(u8, builtIn.version.?, "7."));
}

test "verifyTools reports every tool built into the program available, with the versions of the libraries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const status = try tools.verifyTools(arena.allocator());

    try std.testing.expect(status.allAvailable);
    try std.testing.expectEqual(@as(usize, 0), status.missingTools.len);
    try std.testing.expectEqualStrings(media_tools.image_magick.version(), status.magick.version.?);
    try std.testing.expect(std.mem.startsWith(u8, status.magick.version.?, "7."));
    try std.testing.expect(status.magick.@"error" == null);
    try std.testing.expectEqualStrings(media_tools.ffmpeg.version(), status.ffprobe.version.?);
    try std.testing.expect(status.ffprobe.@"error" == null);
    try std.testing.expectEqualStrings(media_tools.ffmpeg.version(), status.ffmpeg.version.?);
    try std.testing.expect(status.ffmpeg.@"error" == null);
}

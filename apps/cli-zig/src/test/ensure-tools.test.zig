const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");

test "ensureMediaProcessingTools returns when the built-in tools run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try cli.ensure_tools.ensureMediaProcessingTools(arena.allocator());
}

test "requireAvailable throws with the tool's error when the built-in ImageMagick does not run" {
    // A real ImageMagick call that fails (reading the size of a file that does not exist) gives the error of the status of an ImageMagick
    // that did not run.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    const missing = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, "missing.png" });
    try std.testing.expectError(error.Thrown, media_tools.image_magick.readImageInfo(allocator, log, missing));
    const status = try tools.Image.imageMagickFailed(allocator, error.Thrown);

    const result = cli.ensure_tools.requireAvailable(status.available, status.@"error", "The built-in ImageMagick did not run.");
    try std.testing.expectError(error.Thrown, result);
    const message = utils.errors.errorMessage(error.Thrown);
    try std.testing.expect(std.mem.indexOf(u8, message, "The ImageMagick built into the program did not run") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, try std.fmt.allocPrint(allocator, "ImageMagick could not read the size of {s}: ", .{missing})) != null);
}

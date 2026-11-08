const std = @import("std");
const builtin = @import("builtin");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const utils = @import("utils-zig");
const tools = @import("tools-zig");
const heic = tools.heic;

// The HEIC the tests read, relative to the directory the tests run in: a 2x2 grid of 512 pixel tiles trimmed to 1000x700, made by
// scripts/make-heic-test-image.ts.
const test_heic = "../test/heic/tiled.heic";

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

test "isHeicContentType is true for HEIC and HEIF still pictures and nothing else" {
    try std.testing.expect(heic.isHeicContentType("image/heic"));
    try std.testing.expect(heic.isHeicContentType("image/heif"));
    try std.testing.expect(heic.isHeicContentType("IMAGE/HEIC"));
    try std.testing.expect(!heic.isHeicContentType("image/heic-sequence"));
    try std.testing.expect(!heic.isHeicContentType("image/jpeg"));
    try std.testing.expect(!heic.isHeicContentType("video/quicktime"));
}

test "getHeicInfo reads the size of a tiled HEIC with the bundled FFmpeg" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = try heic.getHeicInfo(arena.allocator(), std.testing.io, log, test_heic);
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);
}

test "decodeHeic joins and trims the tiles of a HEIC into a JPEG of the picture's size" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const outputPath = try tempFilePath(allocator, tmp_dir, "decoded.jpg");
    try heic.decodeHeic(allocator, std.testing.io, log, test_heic, outputPath);

    // The bundled ImageMagick reads the JPEG decoded from the HEIC, at the size of the whole picture, not of a tile.
    const info = (try tools.getFileInfo(allocator, std.testing.io, log, outputPath, "image/jpeg")).?;
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);

    // A second decode to the same path is refused rather than overwriting it.
    try std.testing.expectError(error.Thrown, heic.decodeHeic(allocator, std.testing.io, log, test_heic, outputPath));
}

test "getFileInfo reads a HEIC with FFmpeg rather than ImageMagick" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = (try tools.getFileInfo(arena.allocator(), std.testing.io, log, test_heic, "image/heic")).?;
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);
}

test "getHeicInfo and decodeHeic work on a HEIC whose name holds $, a backtick and a double quote" {
    // The goal is to show that a path holding a space, `$`, a backtick and `"` reaches FFmpeg unchanged, as the source
    // and as the output. The method is to copy the tiled HEIC under such a name, read its size, and decode it to a JPEG with such a
    // name.
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    errdefer std.debug.print("The last error: {s}\n", .{utils.errors.lastErrorMessage()});

    // `"` is a reserved character in Windows file names, so it is left out there.
    const specialName = if (builtin.os.tag == .windows) "Trip $5 `a`" else "Trip $5 `a` \"b\"";
    const heicPath = try tempFilePath(allocator, tmp_dir, specialName ++ ".heic");
    try std.Io.Dir.cwd().copyFile(test_heic, std.Io.Dir.cwd(), heicPath, std.testing.io, .{});

    const info = try heic.getHeicInfo(allocator, std.testing.io, log, heicPath);
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);

    const outputPath = try tempFilePath(allocator, tmp_dir, specialName ++ ".jpg");
    try heic.decodeHeic(allocator, std.testing.io, log, heicPath, outputPath);
    const decoded = (try tools.getFileInfo(allocator, std.testing.io, log, outputPath, "image/jpeg")).?;
    try std.testing.expectEqual(@as(f64, 1000), decoded.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), decoded.dimensions.height);
}

test "getHeicInfo and decodeHeic fail loudly on a file that holds no picture" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expectError(error.Thrown, heic.getHeicInfo(allocator, std.testing.io, log, "../test/demo-news.yaml"));
    try std.testing.expectEqualStrings("FFmpeg could not open ../test/demo-news.yaml: Invalid data found when processing input.", utils.errors.lastErrorMessage());

    const outputPath = try tempFilePath(allocator, tmp_dir, "never.jpg");
    try std.testing.expectError(error.Thrown, heic.decodeHeic(allocator, std.testing.io, log, "../test/demo-news.yaml", outputPath));
    try std.testing.expectEqualStrings("Failed to decode the HEIC ../test/demo-news.yaml: Error: FFmpeg could not open ../test/demo-news.yaml: Invalid data found when processing input.", utils.errors.lastErrorMessage());
}

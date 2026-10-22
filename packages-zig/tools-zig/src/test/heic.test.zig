const std = @import("std");
const tools = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const heic = tools.heic;

const MediaTools = media_tools.MediaTools;

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

test "dimensionsFromProbe takes the size of a tile grid, and of the one picture when there is no grid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // What ffprobe reports for a grid: its tiles as streams of their own size, and the grid as a stream group with the picture's size.
    const grid =
        \\{"streams":[{"codec_type":"video","width":512,"height":512}],
        \\ "stream_groups":[{"type":"Tile Grid","components":[{"nb_tiles":4,"coded_width":1024,"coded_height":1024,"width":1000,"height":700}]}]}
    ;
    try std.testing.expectEqual(tools.types.Dimensions{
        .width = 1000,
        .height = 700,
    }, try heic.dimensionsFromProbe(allocator, grid));

    const single =
        \\{"streams":[{"codec_type":"audio"},{"codec_type":"video","width":640,"height":480}],"stream_groups":[]}
    ;
    try std.testing.expectEqual(tools.types.Dimensions{
        .width = 640,
        .height = 480,
    }, try heic.dimensionsFromProbe(allocator, single));
}

test "dimensionsFromProbe fails loudly on a report it cannot take a size from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.Thrown, heic.dimensionsFromProbe(allocator, "not json"));
    try std.testing.expectError(error.Thrown, heic.dimensionsFromProbe(allocator, "{\"streams\":[]}"));
    try std.testing.expectError(error.Thrown, heic.dimensionsFromProbe(allocator, "{\"streams\":[{\"codec_type\":\"video\",\"width\":0,\"height\":480}]}"));
    try std.testing.expectError(error.Thrown, heic.dimensionsFromProbe(allocator, "{\"stream_groups\":[{\"type\":\"Tile Grid\",\"components\":[]}]}"));
}

test "getHeicInfo reads the size of a tiled HEIC with the bundled ffprobe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init(std.testing.io);
    defer mediaTools.deinit();

    const info = try heic.getHeicInfo(arena.allocator(), std.testing.io, mediaTools.runner(), test_heic);
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);
}

test "decodeHeic joins and trims the tiles of a HEIC into a JPEG of the picture's size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var mediaTools = try MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const outputPath = try tempFilePath(allocator, tmp_dir, "decoded.jpg");
    try heic.decodeHeic(allocator, std.testing.io, mediaTools.runner(), test_heic, outputPath);

    // The bundled ImageMagick reads the JPEG FFmpeg wrote, at the size of the whole picture, not of a tile.
    const info = (try tools.getFileInfo(allocator, std.testing.io, mediaTools.runner(), outputPath, "image/jpeg")).?;
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);

    // A second decode to the same path is refused rather than overwriting it.
    try std.testing.expectError(error.Thrown, heic.decodeHeic(allocator, std.testing.io, mediaTools.runner(), test_heic, outputPath));
}

test "getFileInfo reads a HEIC with ffprobe rather than ImageMagick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mediaTools = try MediaTools.init(std.testing.io);
    defer mediaTools.deinit();

    const info = (try tools.getFileInfo(arena.allocator(), std.testing.io, mediaTools.runner(), test_heic, "image/heic")).?;
    try std.testing.expectEqual(@as(f64, 1000), info.dimensions.width);
    try std.testing.expectEqual(@as(f64, 700), info.dimensions.height);
}

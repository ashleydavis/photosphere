const std = @import("std");
const node_api = @import("node-api-zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const heic_exif = node_api.heic_exif;
const image = node_api.image;
const exif_parser = node_api.exif_parser;

// The HEIC the tests read, relative to the directory the tests run in: a 2x2 grid of 512 pixel tiles trimmed to 1000x700, with an
// EXIF item, made by scripts/make-heic-test-image.ts.
const test_heic = "../test/heic/tiled.heic";

// A small EXIF block in TIFF form (big-endian): IFD0 with one tag, Make (0x010F, ASCII), whose value "Cam" fits in the entry itself.
const tiny_tiff = "MM\x00\x2A\x00\x00\x00\x08" ++ "\x00\x01" ++ "\x01\x0F\x00\x02\x00\x00\x00\x04Cam\x00" ++ "\x00\x00\x00\x00";

//
// Makes a box from its type and content.
//
fn box(allocator: std.mem.Allocator, boxType: []const u8, content: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(8 + content.len))));
    try bytes.appendSlice(allocator, boxType);
    try bytes.appendSlice(allocator, content);
    return bytes.items;
}

//
// Joins byte slices.
//
fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, parts);
}

//
// The big-endian bytes of a 16 bit number.
//
fn be16(value: u16) [2]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u16, value));
}

//
// The big-endian bytes of a 32 bit number.
//
fn be32(value: u32) [4]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u32, value));
}

//
// Makes a HEIF file whose meta box lists one item, of the given type, whose data is in the meta box's idat box (construction method
// 1, the way Apple stores small items). Version 1 of iloc is used, as construction methods need it.
//
fn heifWithIdatItem(allocator: std.mem.Allocator, itemType: []const u8, itemData: []const u8) ![]const u8 {
    const infe = try box(allocator, "infe", try join(allocator, &.{ "\x02\x00\x00\x00", &be16(7), &be16(0), itemType, "\x00" }));
    const iinf = try box(allocator, "iinf", try join(allocator, &.{ "\x00\x00\x00\x00", &be16(1), infe }));
    // Version 1, offset and length 4 bytes, no base offset, no index; one item: id 7, construction method 1, data reference 0, one
    // extent at offset 0 of idat, as long as the data.
    const iloc = try box(allocator, "iloc", try join(allocator, &.{ "\x01\x00\x00\x00", "\x44\x00", &be16(1), &be16(7), &be16(1), &be16(0), &be16(1), &be32(0), &be32(@intCast(itemData.len)) }));
    const idat = try box(allocator, "idat", itemData);
    const meta = try box(allocator, "meta", try join(allocator, &.{ "\x00\x00\x00\x00", iinf, iloc, idat }));
    const ftyp = try box(allocator, "ftyp", "heic\x00\x00\x00\x00mif1heic");
    return join(allocator, &.{ ftyp, meta });
}

//
// Parses the JPEG exifAsJpeg made, the way image.zig does.
//
fn parse(allocator: std.mem.Allocator, jpeg: []const u8) !exif_parser.ExifResult {
    var parser = exif_parser.Parser.create(jpeg);
    _ = parser.enableSimpleValues(false);
    return parser.parse(allocator);
}

test "getImageMetadata reads the date, the place and the tags of a HEIC from its EXIF item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();

    const metadata = try image.getImageMetadata(allocator, std.testing.io, test_heic, "image/heic");
    try std.testing.expectEqualStrings("2021-05-06T07:08:09.000Z", metadata.photoDate.?);
    try std.testing.expectApproxEqAbs(@as(f64, -27.4705), metadata.coordinates.?.lat, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f64, 153.026), metadata.coordinates.?.lng, 0.00001);
    const tags = metadata.metadata.?.document;
    try std.testing.expectEqualStrings("Photosphere", tags.get("Make").?.string);
    try std.testing.expectEqualStrings("HEIC test picture", tags.get("Model").?.string);
    // There is no JPEG frame header in a HEIC for the parser to take a size from, so the size is left to the image tools.
    try std.testing.expect(metadata.dimensions == null);
}

test "exifAsJpeg reads an EXIF item kept in idat with Apple's Exif header in front of the TIFF data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Apple's items start with an offset of 6, then "Exif\0\0", then the TIFF data.
    const item = try join(allocator, &.{ &be32(6), "Exif\x00\x00", tiny_tiff });
    const jpeg = (try heic_exif.exifAsJpeg(allocator, try heifWithIdatItem(allocator, "Exif", item))).?;
    const exif = try parse(allocator, jpeg);
    try std.testing.expectEqualStrings("Cam", exif.tags.get("Make").?.string);
}

test "exifAsJpeg gives nothing for a HEIF with no EXIF item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(try heic_exif.exifAsJpeg(allocator, try heifWithIdatItem(allocator, "mime", "not exif")) == null);
}

test "exifAsJpeg fails loudly on a file that is not HEIF and on EXIF that is not where it says" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No meta box at all.
    try std.testing.expectError(error.Thrown, heic_exif.exifAsJpeg(allocator, try box(allocator, "ftyp", "heic\x00\x00\x00\x00")));
    // A box that says it is longer than the file.
    try std.testing.expectError(error.Thrown, heic_exif.exifAsJpeg(allocator, &(be32(64) ++ "meta".*)));
    // An offset to the TIFF header past the end of the item.
    try std.testing.expectError(error.Thrown, heic_exif.exifAsJpeg(allocator, try heifWithIdatItem(allocator, "Exif", try join(allocator, &.{ &be32(100), tiny_tiff }))));
    // Data where the TIFF header should be that has no byte order mark.
    try std.testing.expectError(error.Thrown, heic_exif.exifAsJpeg(allocator, try heifWithIdatItem(allocator, "Exif", try join(allocator, &.{ &be32(0), "XX\x00\x2A" }))));
}

test "getImageMetadata goes on without the metadata of a HEIC whose EXIF cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();

    // The code under test logs the failure; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();

    // A YAML file is no HEIF, so the EXIF reader fails, as the parser does for a JPEG that is not one.
    const metadata = try image.getImageMetadata(allocator, std.testing.io, "../test/demo-news.yaml", "image/heic");
    try std.testing.expect(metadata.metadata == null);
    try std.testing.expect(metadata.photoDate == null);
    try std.testing.expect(metadata.coordinates == null);
}

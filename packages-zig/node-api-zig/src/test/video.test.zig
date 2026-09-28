const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const getVideoDetails = node_api.video.getVideoDetails;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;

//
// (Zig: there are no TypeScript tests of video.ts; these cover what getVideoDetails produces for the checked in
// test video.)
//

test "gets the resolution, duration and derived images of a video" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const tempDir = try helpers.makeTempDir(allocator, io, "video-details");
    defer helpers.removeTempDir(io, tempDir);
    var generator = try TestUuidGenerator.init(allocator);

    const details = try getVideoDetails(allocator, io, "../../test/multiple-files/test.mp4", tempDir, "video/mp4", generator.uuidGenerator(), "test.mp4");

    try std.testing.expect(details.resolution.width > 0);
    try std.testing.expect(details.resolution.height > 0);
    try std.testing.expect(details.duration.? > 0);
    try std.testing.expectEqualStrings("image/jpeg", details.thumbnailContentType);
    try std.testing.expect(details.displayPath == null);
    try std.testing.expect(helpers.fileExists(io, details.thumbnailPath));
    try std.testing.expect(helpers.fileExists(io, details.microPath));
}

test "reads the date of a video from the JSON file beside it when the video has none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const tempDir = try helpers.makeTempDir(allocator, io, "video-json-date");
    defer helpers.removeTempDir(io, tempDir);
    var generator = try TestUuidGenerator.init(allocator);
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/video.mp4", .{tempDir});
    try helpers.writeFile(io, videoPath, try helpers.readFile(allocator, io, "../../test/multiple-files/test.mp4"));
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}.json", .{videoPath}), "{\"photoTakenTime\":{\"timestamp\":\"1700000000\"}}");

    const details = try getVideoDetails(allocator, io, videoPath, tempDir, "video/mp4", generator.uuidGenerator(), "video.mp4");

    // The test video carries no date of its own, so the JSON file's is used.
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", details.photoDate.?);
}

//
// Gets the details of a copy of the test video with the given JSON file beside it.
//
fn detailsWithJson(allocator: std.mem.Allocator, name: []const u8, json: []const u8) !node_api.media_file_database.IAssetDetails {
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const tempDir = try helpers.makeTempDir(allocator, io, name);
    var generator = try TestUuidGenerator.init(allocator);
    const videoPath = try std.fmt.allocPrint(allocator, "{s}/video.mp4", .{tempDir});
    try helpers.writeFile(io, videoPath, try helpers.readFile(allocator, io, "../../test/multiple-files/test.mp4"));
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}.json", .{videoPath}), json);
    const details = getVideoDetails(allocator, io, videoPath, tempDir, "video/mp4", generator.uuidGenerator(), "video.mp4");
    helpers.removeTempDir(io, tempDir);
    return details;
}

test "a JSON timestamp is read as JavaScript's parseInt reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // parseInt(["1700000000"]) reads String(["1700000000"]), which is "1700000000".
    const fromArray = try detailsWithJson(allocator, "video-json-array", "{\"photoTakenTime\":{\"timestamp\":[\"1700000000\"]}}");
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", fromArray.photoDate.?);

    // parseInt("0x10") is 16.
    const fromHex = try detailsWithJson(allocator, "video-json-hex", "{\"photoTakenTime\":{\"timestamp\":\"0x10\"}}");
    try std.testing.expectEqualStrings("1970-01-01T00:00:16.000Z", fromHex.photoDate.?);
}

test "a JSON timestamp that is not a number leaves the video undated rather than failing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // parseInt({}) is NaN, and dayjs.unix(NaN).toISOString() throws, which is caught and logged.
    const details = try detailsWithJson(allocator, "video-json-object", "{\"photoTakenTime\":{\"timestamp\":{\"seconds\":1}}}");
    try std.testing.expect(details.photoDate == null);

    // A number of seconds too large for a Date is an Invalid Date too.
    const tooLate = try detailsWithJson(allocator, "video-json-too-late", "{\"photoTakenTime\":{\"timestamp\":\"99999999999999999999999\"}}");
    try std.testing.expect(tooLate.photoDate == null);
}

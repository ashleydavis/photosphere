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

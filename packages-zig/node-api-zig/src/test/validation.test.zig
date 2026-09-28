const std = @import("std");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const validateFile = node_api.validation.validateFile;

//
// (Zig: there are no TypeScript tests of validation.ts; these cover what validateFile decides.)
//

test "a zero-byte file is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    try std.testing.expectEqual(false, try validateFile(arena.allocator(), io, "../../test/test.png", "image/png", .{
        .length = 0,
        .lastModified = 0,
    }));
}

test "an image the media tools can measure is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, "../../test/test.png", "image/png", .{
        .length = 100,
        .lastModified = 0,
    }));
}

test "an image the media tools cannot read is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const dir = try helpers.makeTempDir(allocator, io, "validation");
    defer helpers.removeTempDir(io, dir);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/broken.png", .{dir});
    try helpers.writeFile(io, filePath, "not a png");

    try std.testing.expectEqual(false, try validateFile(allocator, io, filePath, "image/png", .{
        .length = 9,
        .lastModified = 0,
    }));
}

test "a video the media tools can measure is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, "../../test/multiple-files/test.mp4", "video/mp4", .{
        .length = 100,
        .lastModified = 0,
    }));
}

test "a Photoshop file is let through without being checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, "no-such-file.psd", "image/vnd.adobe.photoshop", .{
        .length = 10,
        .lastModified = 0,
    }));
}

test "a file that is neither an image nor a video is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    try std.testing.expectEqual(true, try validateFile(arena.allocator(), io, "no-such-file.bin", "application/octet-stream", .{
        .length = 10,
        .lastModified = 0,
    }));
}

//
// Runs validateFile with stderr captured, and returns whether the file was valid along with what was logged.
//
const IValidationOutcome = struct {
    // Whether validateFile let the file through.
    valid: bool,

    // What it wrote to stderr.
    logged: []const u8,
};

//
// Validates the file, capturing stderr.
//
fn validateCapturing(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: []const u8) !IValidationOutcome {
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    const valid = try validateFile(allocator, io, filePath, contentType, .{
        .length = 100,
        .lastModified = 0,
    });
    return .{ .valid = valid, .logged = stderr_capture.written() };
}

test "a content type that only starts with image or video gets no file info and is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    // getFileInfo only knows "image/" and "video/" types.
    const image = try validateCapturing(allocator, io, "../../test/test.png", "imagery");
    try std.testing.expectEqual(false, image.valid);
    try std.testing.expect(std.mem.indexOf(u8, image.logged, "Invalid image ../../test/test.png - failed to get file info") != null);

    const video = try validateCapturing(allocator, io, "../../test/multiple-files/test.mp4", "videotape");
    try std.testing.expectEqual(false, video.valid);
    try std.testing.expect(std.mem.indexOf(u8, video.logged, "Invalid video ../../test/multiple-files/test.mp4 - failed to get file info") != null);
}

test "a video the media tools cannot read is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);

    const dir = try helpers.makeTempDir(allocator, io, "validation-video");
    defer helpers.removeTempDir(io, dir);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/broken.mp4", .{dir});
    try helpers.writeFile(io, filePath, "not a video");

    const outcome = try validateCapturing(allocator, io, filePath, "video/mp4");

    try std.testing.expectEqual(false, outcome.valid);
    try std.testing.expect(std.mem.indexOf(u8, outcome.logged, try std.fmt.allocPrint(allocator, "Invalid video {s} - analysis failed", .{filePath})) != null);
}

const std = @import("std");
const node_api = @import("node-api-zig");
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

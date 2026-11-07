const std = @import("std");
const node_api = @import("node-api-zig");
const mime = node_api.mime.mime;

//
// (Zig: mime is an npm package with no tests in this repository; these cover the port of its getType, which is
// what the file scanner asks.)
//

test "gets the type of a file from its extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const types = try mime();

    try std.testing.expectEqualStrings("image/jpeg", (try types.getType(allocator, "photo.jpg")).?);
    try std.testing.expectEqualStrings("image/jpeg", (try types.getType(allocator, "photo.jpeg")).?);
    try std.testing.expectEqualStrings("image/png", (try types.getType(allocator, "/photos/holiday/photo.png")).?);
    try std.testing.expectEqualStrings("video/mp4", (try types.getType(allocator, "clip.mp4")).?);
    try std.testing.expectEqualStrings("application/zip", (try types.getType(allocator, "archive.zip")).?);
    try std.testing.expectEqualStrings("image/svg+xml", (try types.getType(allocator, "drawing.svg")).?);
    try std.testing.expectEqualStrings("video/mp2t", (try types.getType(allocator, "source.ts")).?);
}

test "ignores the case of the extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = try mime();

    try std.testing.expectEqualStrings("image/jpeg", (try types.getType(arena.allocator(), "PHOTO.JPG")).?);
}

test "answers a bare extension as well as a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = try mime();

    try std.testing.expectEqualStrings("image/png", (try types.getType(arena.allocator(), "png")).?);
    try std.testing.expectEqualStrings("image/png", (try types.getType(arena.allocator(), ".png")).?);
}

test "has no type for an extension it does not know, or for no extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = try mime();

    try std.testing.expect(try types.getType(arena.allocator(), "file.unknown") == null);
    try std.testing.expect(try types.getType(arena.allocator(), "/photos/README") == null);
}

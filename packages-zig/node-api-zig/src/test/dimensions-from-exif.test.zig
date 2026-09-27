const std = @import("std");
const node_api = @import("node-api-zig");
const dimensionsFromExif = node_api.image.dimensionsFromExif;

//
// Covers reading a photo's size out of what the EXIF parser already read (port of
// dimensions-from-exif.test.ts). The TypeScript cases with a negative, fractional or non-numeric side have no
// counterpart: the parser's image size holds 16-bit unsigned integers, so it cannot carry those values.
//

test "a parse that found the frame header gives its size" {
    const resolution = dimensionsFromExif(.{
        .tags = .{},
        .imageSize = .{
            .width = 4032,
            .height = 3024,
        },
    });
    try std.testing.expect(resolution != null);
    try std.testing.expectEqual(@as(f64, 4032), resolution.?.width);
    try std.testing.expectEqual(@as(f64, 3024), resolution.?.height);
}

test "a parse that found no frame header gives nothing" {
    try std.testing.expect(dimensionsFromExif(.{
        .tags = .{},
        .imageSize = null,
    }) == null);
}

test "nothing parsed at all gives nothing" {
    try std.testing.expect(dimensionsFromExif(null) == null);
}

test "a size with a zero side is not a size" {
    try std.testing.expect(dimensionsFromExif(.{
        .tags = .{},
        .imageSize = .{
            .width = 0,
            .height = 3024,
        },
    }) == null);
}

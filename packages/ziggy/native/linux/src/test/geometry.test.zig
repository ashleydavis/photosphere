const std = @import("std");
const geometry = @import("../lib/geometry.zig");

test "width and height only" {
    const parsed = geometry.parseGeometry("900x800").?;
    try std.testing.expectEqual(@as(c_int, 900), parsed.width);
    try std.testing.expectEqual(@as(c_int, 800), parsed.height);
}

test "width, height and position" {
    const parsed = geometry.parseGeometry("640x480+10+20").?;
    try std.testing.expectEqual(@as(c_int, 640), parsed.width);
    try std.testing.expectEqual(@as(c_int, 480), parsed.height);
}

test "negative position is accepted" {
    const parsed = geometry.parseGeometry("640x480-30+40").?;
    try std.testing.expectEqual(@as(c_int, 640), parsed.width);
    try std.testing.expectEqual(@as(c_int, 480), parsed.height);
}

test "malformed text is refused" {
    try std.testing.expectEqual(@as(?geometry.Geometry, null), geometry.parseGeometry("900"));
    try std.testing.expectEqual(@as(?geometry.Geometry, null), geometry.parseGeometry("ax800"));
    try std.testing.expectEqual(@as(?geometry.Geometry, null), geometry.parseGeometry("900xb"));
    try std.testing.expectEqual(@as(?geometry.Geometry, null), geometry.parseGeometry("900x800+10"));
    try std.testing.expectEqual(@as(?geometry.Geometry, null), geometry.parseGeometry("900x800+a+b"));
}

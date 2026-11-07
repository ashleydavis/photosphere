const std = @import("std");
const utils = @import("utils-zig");

test "stringify writes a struct as compact JSON with its fields in order" {
    const text = try utils.json.stringify(std.testing.allocator, .{
        .id = 1,
        .name = "a\\b",
        .ok = true,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"id\":1,\"name\":\"a\\\\b\",\"ok\":true}", text);
}

test "a Raw is written as it is, without being parsed and written again" {
    const text = try utils.json.stringify(std.testing.allocator, .{
        .id = 7,
        .data = utils.json.Raw{ .text = "{\"n\": 1.50,  \"k\":[1, 2]}" },
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"id\":7,\"data\":{\"n\": 1.50,  \"k\":[1, 2]}}", text);
}

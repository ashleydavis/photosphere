const std = @import("std");
const ziggy = @import("ziggy-core");

test "a Raw is written as it is, without being parsed and written again" {
    const text = try ziggy.json_util.stringify(std.testing.allocator, .{
        .id = 7,
        .data = ziggy.json_util.Raw{ .text = "{\"n\": 1.50,  \"k\":[1, 2]}" },
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"id\":7,\"data\":{\"n\": 1.50,  \"k\":[1, 2]}}", text);
}

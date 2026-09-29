const std = @import("std");
const cli = @import("cli-zig");
const check_for_updates = cli.check_for_updates;

test "tagName reads the release response as response.json() and the tag_name checks do" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("v1.2.3", check_for_updates.tagName(allocator, "{\"tag_name\":\"v1.2.3\"}").?);

    // JSON.parse keeps the last value of a repeated key.
    try std.testing.expectEqualStrings("v2.0.0", check_for_updates.tagName(allocator, "{\"tag_name\":\"v1.2.3\",\"tag_name\":\"v2.0.0\"}").?);

    // An empty tag, a tag that is not a string, a body that is not an object and a body that is not JSON give none.
    try std.testing.expect(check_for_updates.tagName(allocator, "{\"tag_name\":\"\"}") == null);
    try std.testing.expect(check_for_updates.tagName(allocator, "{\"tag_name\":5}") == null);
    try std.testing.expect(check_for_updates.tagName(allocator, "null") == null);
    try std.testing.expect(check_for_updates.tagName(allocator, "not json") == null);
}

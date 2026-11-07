const std = @import("std");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

test "check-tools replies with the status of each tool, and what is missing agrees with it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const reply = try app.requestOk("check-tools", "null");
    defer allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply, .{});
    defer parsed.deinit();
    const status = parsed.value.object;
    var missing: usize = 0;
    for ([_][]const u8{ "magick", "ffprobe", "ffmpeg" }) |tool_name| {
        const tool = status.get(tool_name).?.object;
        const available = tool.get("available").?.bool;
        if (!available) {
            missing += 1;
            try std.testing.expect(tool.get("error") != null);
        }
        else {
            try std.testing.expect(tool.get("version") != null);
        }
    }
    try std.testing.expectEqual(missing, status.get("missingTools").?.array.items.len);
    try std.testing.expectEqual(missing == 0, status.get("allAvailable").?.bool);
}

const std = @import("std");
const node_api = @import("node-api-zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

test "mark-update-shown records the version as the last one shown" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const reply = try app.requestOk("mark-update-shown", "\"1.2.3\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const shown = (try node_api.news_state.getLastShownUpdateVersion(arena.allocator(), std.testing.io)).?;
    try std.testing.expectEqualStrings("1.2.3", shown);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Marked update notification as shown: v1.2.3") != null);
}

test "mark-update-shown without a version is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("mark-update-shown", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The request needs the version of the update that was shown.", reply);
}

test "mark-news-shown adds the id to the news items shown, once" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("mark-news-shown", "\"news-one\""));
    allocator.free(try app.requestOk("mark-news-shown", "\"news-two\""));
    allocator.free(try app.requestOk("mark-news-shown", "\"news-one\""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const shown = try node_api.news_state.getShownNewsIds(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), shown.len);
    try std.testing.expectEqualStrings("news-one", shown[0]);
    try std.testing.expectEqualStrings("news-two", shown[1]);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Marked news notification as shown: news-two") != null);
}

test "mark-news-shown without an id is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("mark-news-shown", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The request needs the id of the news item that was shown.", reply);
}

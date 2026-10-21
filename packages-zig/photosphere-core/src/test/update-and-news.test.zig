const std = @import("std");
const node_api = @import("node-api-zig");
const update_and_news = @import("photosphere-core").update_and_news;
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
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
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
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "a failing mark-shown request logs the error with the message of its handler" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.queueFailingTask("mark-update-shown", "null");
    try std.testing.expect(std.mem.indexOf(u8, app.console_err.written(), "Error marking update notification as shown") != null);
    try app.queueFailingTask("mark-news-shown", "null");
    try std.testing.expect(std.mem.indexOf(u8, app.console_err.written(), "Error marking news notification as shown") != null);
}

//
// Writes a news feed into the directory the test owns and makes PHOTOSPHERE_NEWS_URL point at it, in test mode as the smoke tests run.
//
fn useNewsFeed(app: *TestApp, feed: []const u8) !void {
    const allocator = std.testing.allocator;
    const feed_path = try std.fs.path.join(allocator, &.{ app.tmp_path, "news.yaml" });
    defer allocator.free(feed_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = feed_path,
        .data = feed,
    });
    const url = try std.fmt.allocPrint(allocator, "file://{s}", .{feed_path});
    defer allocator.free(url);
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_NEWS_URL", url);
}

const two_item_feed =
    \\items:
    \\  - id: first
    \\    message: First news
    \\    color: success
    \\    duration: 5000
    \\  - id: second
    \\    message: Second news
    \\
;

test "checkForNews sends the first item that has not been shown, and logs it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try useNewsFeed(&app, two_item_feed);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try update_and_news.checkForNews(app.core, arena.allocator(), std.testing.io);
    try app.shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"First news\",\"color\":\"success\",\"duration\":5000,\"newsId\":\"first\"}}}");
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Showed news notification: first") != null);
}

test "checkForNews skips the items already shown, and gives an item without a color the primary one and no duration none" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try useNewsFeed(&app, two_item_feed);
    std.testing.allocator.free(try app.requestOk("mark-news-shown", "\"first\""));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try update_and_news.checkForNews(app.core, arena.allocator(), std.testing.io);
    try app.shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"Second news\",\"color\":\"primary\",\"duration\":0,\"newsId\":\"second\"}}}");
}

test "checkForNews sends nothing when every item has been shown" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try useNewsFeed(&app, two_item_feed);
    std.testing.allocator.free(try app.requestOk("mark-news-shown", "\"first\""));
    std.testing.allocator.free(try app.requestOk("mark-news-shown", "\"second\""));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try update_and_news.checkForNews(app.core, arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("show-notification"));
}

test "checkForNews logs that it was skipped when the feed cannot be read" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try useNewsFeed(&app, "items: nope\n");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try update_and_news.checkForNews(app.core, arena.allocator(), std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "News check skipped: Invalid news feed: missing items array") != null);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("show-notification"));
}

test "checkForNews does nothing in test mode unless PHOTOSPHERE_NEWS_URL is set" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    const logged_before = app.console_out.writer.buffered().len;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try update_and_news.checkForNews(app.core, arena.allocator(), std.testing.io);
    try std.testing.expectEqual(logged_before, app.console_out.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("show-notification"));
}

test "checkForUpdate does nothing for a dev or nightly build, or in test mode unless forced" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const logged_before = app.console_out.writer.buffered().len;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try update_and_news.checkForUpdate(app.core, arena.allocator(), std.testing.io, "dev");
    try update_and_news.checkForUpdate(app.core, arena.allocator(), std.testing.io, "1.2.3-nightly.4");
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try update_and_news.checkForUpdate(app.core, arena.allocator(), std.testing.io, "1.2.3");
    try std.testing.expectEqual(logged_before, app.console_out.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("update-available"));
}

test "main-command page-loaded checks the news feed, and does it once however often the page loads" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try useNewsFeed(&app, two_item_feed);
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("main-command", "{\"command\":\"page-loaded\"}"));
    try app.shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"First news\",\"color\":\"success\",\"duration\":5000,\"newsId\":\"first\"}}}");
    allocator.free(try app.requestOk("main-command", "{\"command\":\"page-loaded\"}"));
    app.shell.sleepMs(300);
    try std.testing.expectEqual(@as(usize, 1), app.shell.countContaining("show-notification"));
}

test "main-command page-loaded does not check the news in test mode when no feed is named" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    std.testing.allocator.free(try app.requestOk("main-command", "{\"command\":\"page-loaded\"}"));
    try app.shell.expectMessageContaining("\"type\":\"check-for-news\"");
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("show-notification"));
}

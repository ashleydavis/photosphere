const std = @import("std");
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");
const update_and_news = @import("photosphere-core").update_and_news;
const support = @import("test-support.zig");

const TestApp = support.TestApp;
const HandlerServices = @import("ziggy").core.HandlerServices;
const Timers = @import("ziggy").timers.Timers;

test "mark-update-shown records the version as the last one shown" {
    const log = ziggy.task_queue.utils.mute_log.MuteLog.init();
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const reply = try app.requestOk("mark-update-shown", "\"1.2.3\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const shown = (try node_api.news_state.getLastShownUpdateVersion(arena.allocator(), std.testing.io, log)).?;
    try std.testing.expectEqualStrings("1.2.3", shown);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Marked update notification as shown: v1.2.3") != null);
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
    const log = ziggy.task_queue.utils.mute_log.MuteLog.init();
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("mark-news-shown", "\"news-one\""));
    allocator.free(try app.requestOk("mark-news-shown", "\"news-two\""));
    allocator.free(try app.requestOk("mark-news-shown", "\"news-one\""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const shown = try node_api.news_state.getShownNewsIds(arena.allocator(), std.testing.io, log);
    try std.testing.expectEqual(@as(usize, 2), shown.len);
    try std.testing.expectEqualStrings("news-one", shown[0]);
    try std.testing.expectEqualStrings("news-two", shown[1]);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Marked news notification as shown: news-two") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error marking update notification as shown") != null);
    try app.queueFailingTask("mark-news-shown", "null");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error marking news notification as shown") != null);
}

//
// Runs checkForNews on the core's main thread, where it runs in the app, with the main thread's Io, and waits for it.
//
fn checkNewsOnMain(app: *TestApp) !void {
    const Call = struct {
        fn run(_: u8, services: HandlerServices, _: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
            const log = services.log;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try update_and_news.checkForNews(services, arena.allocator(), io, log);
        }
    };
    try app.onMainThread(@as(u8, 0), Call.run);
}

//
// Runs checkForUpdate for the version on the core's main thread, as checkNewsOnMain does checkForNews.
//
fn checkUpdateOnMain(app: *TestApp, comptime version: []const u8) !void {
    const Call = struct {
        fn run(_: u8, services: HandlerServices, _: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
            const log = services.log;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try update_and_news.checkForUpdate(services, arena.allocator(), io, log, version);
        }
    };
    try app.onMainThread(@as(u8, 0), Call.run);
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
    try app.prepare();
    try useNewsFeed(&app, two_item_feed);
    try app.launch();
    defer app.stop();
    try checkNewsOnMain(&app);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"First news\",\"color\":\"success\",\"duration\":5000,\"newsId\":\"first\"}}}");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Showed news notification: first") != null);
}

test "checkForNews skips the items already shown, and gives an item without a color the primary one and no duration none" {
    var app: TestApp = undefined;
    try app.prepare();
    try useNewsFeed(&app, two_item_feed);
    try app.launch();
    defer app.stop();
    std.testing.allocator.free(try app.requestOk("mark-news-shown", "\"first\""));
    try checkNewsOnMain(&app);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"Second news\",\"color\":\"primary\",\"duration\":0,\"newsId\":\"second\"}}}");
}

test "checkForNews sends nothing when every item has been shown" {
    var app: TestApp = undefined;
    try app.prepare();
    try useNewsFeed(&app, two_item_feed);
    try app.launch();
    defer app.stop();
    std.testing.allocator.free(try app.requestOk("mark-news-shown", "\"first\""));
    std.testing.allocator.free(try app.requestOk("mark-news-shown", "\"second\""));
    try checkNewsOnMain(&app);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "show-notification"));
}

test "checkForNews logs that it was skipped when the feed cannot be read" {
    var app: TestApp = undefined;
    try app.prepare();
    try useNewsFeed(&app, "items: nope\n");
    try app.launch();
    defer app.stop();
    try checkNewsOnMain(&app);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "News check skipped: Invalid news feed: missing items array") != null);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "show-notification"));
}

test "checkForNews does nothing in test mode unless PHOTOSPHERE_NEWS_URL is set" {
    var app: TestApp = undefined;
    try app.prepare();
    // The main thread reads a copy of the environment made when the core starts, so test mode is switched on before that.
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.launch();
    defer app.stop();
    const logged_before = (try app.consoleOut()).len;
    try checkNewsOnMain(&app);
    try std.testing.expectEqual(logged_before, (try app.consoleOut()).len);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "show-notification"));
}

test "checkForUpdate does nothing for a dev or nightly build" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const logged_before = (try app.consoleOut()).len;
    try checkUpdateOnMain(&app, "dev");
    try checkUpdateOnMain(&app, "1.2.3-nightly.4");
    try std.testing.expectEqual(logged_before, (try app.consoleOut()).len);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "update-available"));
}

test "checkForUpdate does nothing for a release in test mode unless forced" {
    var app: TestApp = undefined;
    try app.prepare();
    // The main thread reads a copy of the environment made when the core starts, so test mode is switched on before that.
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.launch();
    defer app.stop();
    const logged_before = (try app.consoleOut()).len;
    try checkUpdateOnMain(&app, "1.2.3");
    try std.testing.expectEqual(logged_before, (try app.consoleOut()).len);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "update-available"));
}

test "main-command page-loaded checks the news feed, and does it once however often the page loads" {
    var app: TestApp = undefined;
    try app.prepare();
    try useNewsFeed(&app, two_item_feed);
    try app.launch();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("main-command", "{\"command\":\"page-loaded\"}"));
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"First news\",\"color\":\"success\",\"duration\":5000,\"newsId\":\"first\"}}}");
    allocator.free(try app.requestOk("main-command", "{\"command\":\"page-loaded\"}"));
    ziggy.fake_native_app.sleepMs(std.testing.io, 300);
    // The page is shown a notification by the app event. The check runs as a task, whose events the page is also told of as task
    // events, which hold the same text.
    try std.testing.expectEqual(@as(usize, 1), app.native_app.countContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\""));
}

test "main-command page-loaded does not check the news in test mode when no feed is named" {
    var app: TestApp = undefined;
    try app.prepare();
    // The core's threads read copies of the environment made when it starts, so test mode is switched on before that.
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.launch();
    defer app.stop();
    std.testing.allocator.free(try app.requestOk("main-command", "{\"command\":\"page-loaded\"}"));
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"type\":\"check-for-news\"");
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "show-notification"));
}

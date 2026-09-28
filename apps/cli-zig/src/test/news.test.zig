const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");

//
// A news feed of three items: one with a link, one with an action and one with neither.
//
const three_item_feed =
    \\items:
    \\  - id: first
    \\    message: "Hello there"
    \\    link:
    \\      label: "Docs"
    \\      url: "https://example.com/docs"
    \\  - id: second
    \\    message: Second item
    \\    action:
    \\      label: Go
    \\      url: https://example.com/go
    \\  - id: third
    \\    message: Third
    \\
;

//
// Sets up a config dir and a news feed file in the root, and points the process environment at them.
//
fn setup(allocator: std.mem.Allocator, root: []const u8, feed: []const u8) !void {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    try map.put("PHOTOSPHERE_CONFIG_DIR", try std.fs.path.join(allocator, &.{ root, "config" }));
    const feedPath = try std.fs.path.join(allocator, &.{ root, "news.yaml" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = feedPath, .data = feed });
    try map.put("PHOTOSPHERE_NEWS_URL", try helpers.fileUrl(allocator, feedPath));
    node_utils.process_env.setEnvironMap(map);
}

//
// Reads the state file of the config dir.
//
fn readState(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ root, "config", "state.yaml" }), allocator, .unlimited);
}

test "newsCommand prints the whole feed newest first, marks the new items and records them as shown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&capture.writer, &capture.writer);
    defer utils.console.setCapture(null, null);

    // The first item was already shown by the notifications.
    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{"first"});
    try cli.news.newsCommand(allocator, std.testing.io);
    try std.testing.expectEqualStrings(
        \\
        \\📋 Photosphere News
        \\
        \\Running version: vdev
        \\
        \\★ Third (new)
        \\★ Second item (new)
        \\     Go: https://example.com/go
        \\• Hello there
        \\     Docs: https://example.com/docs
        \\
    , capture.written());
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - first\n    - second\n    - third\n", try readState(allocator, root));

    capture.clearRetainingCapacity();
    try cli.news.newsCommand(allocator, std.testing.io);
    try std.testing.expect(std.mem.endsWith(u8, capture.written(), "\n• Third\n• Second item\n     Go: https://example.com/go\n• Hello there\n     Docs: https://example.com/docs\n"));
}

test "newsCommand says there is no news when the feed is empty or cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&capture.writer, &capture.writer);
    defer utils.console.setCapture(null, null);
    defer node_utils.process_env.setEnvironMap(null);

    for ([_][]const u8{ "items: []\n", "items: [unclosed" }) |feed| {
        try setup(allocator, root, feed);
        capture.clearRetainingCapacity();
        try cli.news.newsCommand(allocator, std.testing.io);
        try std.testing.expectEqualStrings("\n📋 Photosphere News\n\nRunning version: vdev\n\nNo news items available.\n", capture.written());
    }
}

test "getAllNews pairs every item with whether it was shown, and is empty when the feed cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-all");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);

    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{"second"});
    const allNews = cli.check_for_news.getAllNews(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), allNews.len);
    try std.testing.expectEqualStrings("first", allNews[0].item.id);
    try std.testing.expect(!allNews[0].seen);
    try std.testing.expectEqualStrings("second", allNews[1].item.id);
    try std.testing.expect(allNews[1].seen);
    try std.testing.expectEqualStrings("third", allNews[2].item.id);
    try std.testing.expect(!allNews[2].seen);

    try setup(allocator, root, "items: [unclosed");
    try std.testing.expectEqual(@as(usize, 0), cli.check_for_news.getAllNews(allocator, std.testing.io).len);
}

test "markNewsAsShown records the ids, and nothing for no ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-mark");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);

    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{});
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try std.fs.path.join(allocator, &.{ root, "config", "state.yaml" })));
    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{"first"});
    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{ "second", "third" });
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - first\n    - second\n    - third\n", try readState(allocator, root));
}

test "getLatestVersion looks nothing up for the dev version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(cli.check_for_updates.getLatestVersion(arena.allocator(), std.testing.io) == null);
}

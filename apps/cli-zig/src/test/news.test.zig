const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const MockLog = @import("mock-log.zig").MockLog;

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

test "newsCommand always prints the running version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-version");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, "items: []\n");
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    try cli.news.newsCommand(allocator, std.testing.io);

    var found = false;
    for (mock.calls.items) |call| {
        if (call.method == .info and std.mem.indexOf(u8, call.message, "Running version") != null and std.mem.indexOf(u8, call.message, "vdev") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "newsCommand omits the latest release line when latest version is unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-no-latest");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, "items: []\n");
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    try cli.news.newsCommand(allocator, std.testing.io);

    try std.testing.expect(!mock.wasCalledContaining(.info, "Latest release"));
    try std.testing.expect(try node_api.news_state.getLastShownUpdateVersion(allocator, std.testing.io) == null);
}

test "newsCommand prints \"No news items available\" when the feed is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-no-news");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, "items: []\n");
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    try cli.news.newsCommand(allocator, std.testing.io);

    try std.testing.expect(mock.wasCalledContaining(.info, "No news items available"));
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try std.fs.path.join(allocator, &.{ root, "config", "state.yaml" })));
}

test "newsCommand renders both seen and unseen items and marks unseen ones as shown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-seen-unseen");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root,
        \\items:
        \\  - id: a
        \\    message: older seen item
        \\  - id: b
        \\    message: new item
        \\
    );
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();
    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{"a"});

    try cli.news.newsCommand(allocator, std.testing.io);

    try std.testing.expect(mock.wasCalledContaining(.info, "older seen item"));
    var newMarked = false;
    for (mock.calls.items) |call| {
        if (call.method == .info and std.mem.indexOf(u8, call.message, "new item") != null and std.mem.indexOf(u8, call.message, "(new)") != null) {
            newMarked = true;
        }
    }
    try std.testing.expect(newMarked);
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n    - b\n", try readState(allocator, root));
}

test "newsCommand renders items newest-first (reverse of feed order)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-order");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root,
        \\items:
        \\  - id: a
        \\    message: oldest
        \\  - id: b
        \\    message: middle
        \\  - id: c
        \\    message: newest
        \\
    );
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();
    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{ "a", "b", "c" });

    try cli.news.newsCommand(allocator, std.testing.io);

    var newestIndex: ?usize = null;
    var oldestIndex: ?usize = null;
    for (mock.calls.items, 0..) |call, index| {
        if (newestIndex == null and std.mem.indexOf(u8, call.message, "newest") != null) {
            newestIndex = index;
        }
        if (oldestIndex == null and std.mem.indexOf(u8, call.message, "oldest") != null) {
            oldestIndex = index;
        }
    }
    try std.testing.expect(newestIndex != null);
    try std.testing.expect(oldestIndex != null);
    try std.testing.expect(newestIndex.? < oldestIndex.?);
}

test "newsCommand renders link and action lines when present on items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-link-action");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root,
        \\items:
        \\  - id: a
        \\    message: Body
        \\    link:
        \\      label: Docs
        \\      url: https://example.com/docs
        \\    action:
        \\      label: Open
        \\      url: https://example.com/open
        \\
    );
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    try cli.news.newsCommand(allocator, std.testing.io);

    try std.testing.expect(mock.wasCalledContaining(.info, "Docs: https://example.com/docs"));
    try std.testing.expect(mock.wasCalledContaining(.info, "Open: https://example.com/open"));
}

test "newsCommand records nothing when every item is already seen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "news-command-all-seen");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root,
        \\items:
        \\  - id: a
        \\    message: a
        \\  - id: b
        \\    message: b
        \\
    );
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();
    cli.check_for_news.markNewsAsShown(allocator, std.testing.io, &.{ "a", "b" });
    const stateBefore = try readState(allocator, root);

    try cli.news.newsCommand(allocator, std.testing.io);

    try std.testing.expectEqualStrings(stateBefore, try readState(allocator, root));
}

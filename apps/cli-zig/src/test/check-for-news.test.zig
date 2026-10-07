const std = @import("std");
const cli = @import("cli-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const MockLog = @import("mock-log.zig").MockLog;
const checkForNews = cli.check_for_news.checkForNews;
const getAllNews = cli.check_for_news.getAllNews;
const markNewsAsShown = cli.check_for_news.markNewsAsShown;

//
// A feed of three items, in the order the TypeScript tests give them.
//
const three_item_feed =
    \\items:
    \\  - id: a
    \\    message: first
    \\  - id: b
    \\    message: second
    \\  - id: c
    \\    message: third
    \\
;

//
// Sets up a config dir and a news feed file in the root, and points the process environment at them (TypeScript: the
// mocked fetchNews of node-api, which here reads a real feed file through a file URL).
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
// The path of the state file in the config dir.
//
fn statePath(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root, "config", "state.yaml" });
}

test "checkForNews returns oldest unseen item and marks it shown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-oldest");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    const result = checkForNews(allocator, std.testing.io).?;

    try std.testing.expectEqualStrings("a", result.id);
    try std.testing.expectEqualStrings("first", result.message);
    const shownIds = try node_api.news_state.getShownNewsIds(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), shownIds.len);
    try std.testing.expectEqualStrings("a", shownIds[0]);
}

test "checkForNews skips items already in the shown set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-skips");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();
    markNewsAsShown(allocator, std.testing.io, &.{"a"});

    const result = checkForNews(allocator, std.testing.io).?;

    try std.testing.expectEqualStrings("b", result.id);
    try std.testing.expectEqualStrings("second", result.message);
    const shownIds = try node_api.news_state.getShownNewsIds(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), shownIds.len);
    try std.testing.expectEqualStrings("a", shownIds[0]);
    try std.testing.expectEqualStrings("b", shownIds[1]);
}

test "checkForNews returns undefined when there are no unseen items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-none-unseen");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root,
        \\items:
        \\  - id: a
        \\    message: first
        \\
    );
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();
    markNewsAsShown(allocator, std.testing.io, &.{"a"});
    const stateBefore = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try statePath(allocator, root), allocator, .unlimited);

    const result = checkForNews(allocator, std.testing.io);

    try std.testing.expect(result == null);
    const stateAfter = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try statePath(allocator, root), allocator, .unlimited);
    try std.testing.expectEqualStrings(stateBefore, stateAfter);
}

test "checkForNews returns undefined when the feed is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, "items: []\n");
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    const result = checkForNews(allocator, std.testing.io);

    try std.testing.expect(result == null);
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try statePath(allocator, root)));
}

test "checkForNews returns undefined and swallows errors when fetchNews throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-throws");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    // The feed file is removed, so reading it fails (the network being down).
    try std.Io.Dir.cwd().deleteFile(std.testing.io, try std.fs.path.join(allocator, &.{ root, "news.yaml" }));
    const result = checkForNews(allocator, std.testing.io);

    try std.testing.expect(result == null);
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try statePath(allocator, root)));
}

test "getAllNews returns all items with seen state derived from shown ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-all");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();
    markNewsAsShown(allocator, std.testing.io, &.{ "a", "c" });

    const result = getAllNews(allocator, std.testing.io);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0].item.id);
    try std.testing.expectEqualStrings("first", result[0].item.message);
    try std.testing.expect(result[0].seen);
    try std.testing.expectEqualStrings("b", result[1].item.id);
    try std.testing.expectEqualStrings("second", result[1].item.message);
    try std.testing.expect(!result[1].seen);
    try std.testing.expectEqualStrings("c", result[2].item.id);
    try std.testing.expectEqualStrings("third", result[2].item.message);
    try std.testing.expect(result[2].seen);
}

test "getAllNews does not mark anything as shown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-all-no-mark");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, "items:\n  - id: a\n    message: first\n");
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    _ = getAllNews(allocator, std.testing.io);

    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try statePath(allocator, root)));
}

test "getAllNews returns empty array on fetch failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-all-fails");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    try std.Io.Dir.cwd().deleteFile(std.testing.io, try std.fs.path.join(allocator, &.{ root, "news.yaml" }));
    const result = getAllNews(allocator, std.testing.io);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "markNewsAsShown records the supplied ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-mark");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    markNewsAsShown(allocator, std.testing.io, &.{ "a", "b" });

    const shownIds = try node_api.news_state.getShownNewsIds(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), shownIds.len);
    try std.testing.expectEqualStrings("a", shownIds[0]);
    try std.testing.expectEqualStrings("b", shownIds[1]);
}

test "markNewsAsShown is a no-op when given an empty array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-mark-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    markNewsAsShown(allocator, std.testing.io, &.{});

    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try statePath(allocator, root)));
}

test "markNewsAsShown swallows persistence errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-mark-fails");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setup(allocator, root, three_item_feed);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    // A file where the config dir should be, so the state file cannot be written (TypeScript: addShownNewsIds rejects with "disk full").
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ root, "config" }), .data = "not a directory" });
    markNewsAsShown(allocator, std.testing.io, &.{"a"});

    // Reaching here is the check: markNewsAsShown returned without an error.
    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try statePath(allocator, root)));
}

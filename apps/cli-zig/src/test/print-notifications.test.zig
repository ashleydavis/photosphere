const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");

//
// Sets up a config dir and a news feed file, and returns the environment.
//
fn setup(allocator: std.mem.Allocator, root: []const u8, feed: []const u8) !*std.process.Environ.Map {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    try map.put("PHOTOSPHERE_CONFIG_DIR", try std.fmt.allocPrint(allocator, "{s}/config", .{root}));
    const feedPath = try std.fmt.allocPrint(allocator, "{s}/news.yaml", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = feedPath, .data = feed });
    try map.put("PHOTOSPHERE_NEWS_URL", try helpers.fileUrl(allocator, feedPath));
    node_utils.process_env.setEnvironMap(map);
    return map;
}

test "checkForUpdates returns nothing for the dev version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(cli.check_for_updates.checkForUpdates(arena.allocator(), std.testing.io) == null);
}

test "printNotifications prints the next unseen news item once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "notifications");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    _ = try setup(allocator, root,
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
        \\
    );
    defer node_utils.process_env.setEnvironMap(null);
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&capture.writer, &capture.writer);
    defer utils.console.setCapture(null, null);

    try cli.print_notifications.printNotifications(allocator, std.testing.io);
    try std.testing.expectEqualStrings("\n\u{1F4F0} News:\n   Hello there\n   Docs: https://example.com/docs\n", capture.written());
    capture.clearRetainingCapacity();
    try cli.print_notifications.printNotifications(allocator, std.testing.io);
    try std.testing.expectEqualStrings("\n\u{1F4F0} News:\n   Second item\n   Go: https://example.com/go\n", capture.written());
    capture.clearRetainingCapacity();
    try cli.print_notifications.printNotifications(allocator, std.testing.io);
    try std.testing.expectEqualStrings("", capture.written());
    const state = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/config/news.yaml", .{root}), allocator, .unlimited);
    try std.testing.expectEqualStrings("shown_news_ids:\n  - first\n  - second\n", state);
}

test "checkForNews returns nothing when the feed cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "notifications-bad");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    _ = try setup(allocator, root, "items: [unclosed");
    defer node_utils.process_env.setEnvironMap(null);
    try std.testing.expect(cli.check_for_news.checkForNews(allocator, std.testing.io) == null);
}

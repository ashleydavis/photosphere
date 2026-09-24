const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("picocolors.zig");
const check_for_updates = @import("check-for-updates.zig");
const check_for_news = @import("check-for-news.zig");
const INewsItem = node_api.news_fetcher.INewsItem;
const checkForUpdates = check_for_updates.checkForUpdates;
const markUpdateAsShown = check_for_updates.markUpdateAsShown;
const checkForNews = check_for_news.checkForNews;
const log = &utils.log.log;

//
// Prints a single news item to stdout in the standard CLI presentation: a bold "📰 News:"
// heading, the message body, and the optional inline link and CTA action printed as
// label/URL pairs. Shared by printNotifications() and the `psi news` command so both
// surfaces look identical.
//
pub fn printNewsItem(allocator: std.mem.Allocator, item: INewsItem) !void {
    log.info("");
    log.info(try pc.bold(allocator, "\u{1F4F0} News:"));
    log.info(try std.fmt.allocPrint(allocator, "   {s}", .{item.message}));
    if (item.link) |link| {
        log.info(try pc.dim(allocator, try std.fmt.allocPrint(allocator, "   {s}: {s}", .{ link.label, link.url })));
    }
    if (item.action) |action| {
        log.info(try pc.dim(allocator, try std.fmt.allocPrint(allocator, "   {s}: {s}", .{ action.label, action.url })));
    }
}

//
// Prints any available update notification followed by the next unseen news item.
// Invoked as a commander preAction hook so that every CLI command surfaces these
// notifications before doing its own work. Network and parse errors are swallowed by
// the underlying check functions, so this call never blocks the user.
//
// The `psi news` command skips this hook and renders its own (always-on, full-feed)
// listing instead (see cmd/news.ts).
//
pub fn printNotifications(allocator: std.mem.Allocator, io: std.Io) !void {
    const updateVersion = checkForUpdates(allocator, io);
    if (updateVersion) |version| {
        log.info("");
        log.info(try pc.bold(allocator, try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{1F4E6} A new version is available: v{s}", .{version}))));
        log.info(try pc.dim(allocator, "   https://github.com/ashleydavis/photosphere/releases/latest"));
        markUpdateAsShown(allocator, io, version);
    }

    const news = checkForNews(allocator, io);
    if (news) |item| {
        try printNewsItem(allocator, item);
    }
}

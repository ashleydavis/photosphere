const std = @import("std");
const utils = @import("utils-zig");
const pc = @import("../lib/picocolors.zig");
const config = @import("../lib/config.zig");
const check_for_updates = @import("../lib/check-for-updates.zig");
const check_for_news = @import("../lib/check-for-news.zig");
const log = &utils.log.log;
const version = config.version;
const getLatestVersion = check_for_updates.getLatestVersion;
const markUpdateAsShown = check_for_updates.markUpdateAsShown;
const getAllNews = check_for_news.getAllNews;
const markNewsAsShown = check_for_news.markNewsAsShown;

//
// Formats a message into the allocator (TypeScript: a template literal).
//
fn text(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

//
// Command that always prints the latest update notification (if any) and the full news
// feed, regardless of which items have already been seen. After rendering, every shown
// item is recorded so the standard pre-command notification (oldest unseen news) does
// not re-display the same items on subsequent commands.
//
pub fn newsCommand(allocator: std.mem.Allocator, io: std.Io) !void {
    log.info("");
    log.info(try pc.bold(allocator, "\u{1F4CB} Photosphere News\n"));

    log.info(try text(allocator, "{s}: {s}", .{ try pc.bold(allocator, "Running version"), try pc.green(allocator, try text(allocator, "v{s}", .{version})) }));
    const latestVersion = getLatestVersion(allocator, io);
    if (latestVersion) |latest| {
        if (std.mem.eql(u8, latest, version)) {
            log.info(try text(allocator, "{s}:  {s} {s}", .{ try pc.bold(allocator, "Latest release"), try pc.green(allocator, try text(allocator, "v{s}", .{latest})), try pc.dim(allocator, "(up to date)") }));
        }
        else {
            log.info(try text(allocator, "{s}:  {s} {s}", .{ try pc.bold(allocator, "Latest release"), try pc.green(allocator, try text(allocator, "v{s}", .{latest})), try pc.bold(allocator, try pc.green(allocator, "(update available)")) }));
            log.info(try pc.dim(allocator, "   https://github.com/ashleydavis/photosphere/releases/latest"));
            markUpdateAsShown(allocator, io, latest);
        }
    }
    log.info("");

    const allNews = getAllNews(allocator, io);
    if (allNews.len == 0) {
        log.info(try pc.dim(allocator, "No news items available."));
        return;
    }

    // Render newest-first so the most recent items are seen first; news.yaml is ordered
    // oldest-first by publishing convention so we reverse here for display only.
    var index = allNews.len;
    while (index > 0) {
        index -= 1;
        const entry = allNews[index];
        const marker = if (entry.seen) try pc.dim(allocator, "\u{2022}") else try pc.green(allocator, "\u{2605}");
        const tag = if (entry.seen) "" else try pc.green(allocator, " (new)");
        log.info(try text(allocator, "{s} {s}{s}", .{ marker, entry.item.message, tag }));
        if (entry.item.link) |link| {
            log.info(try pc.dim(allocator, try text(allocator, "     {s}: {s}", .{ link.label, link.url })));
        }
        if (entry.item.action) |action| {
            log.info(try pc.dim(allocator, try text(allocator, "     {s}: {s}", .{ action.label, action.url })));
        }
    }

    var unseenIds: std.ArrayList([]const u8) = .empty;
    for (allNews) |entry| {
        if (!entry.seen) {
            try unseenIds.append(allocator, entry.item.id);
        }
    }
    markNewsAsShown(allocator, io, unseenIds.items);
}

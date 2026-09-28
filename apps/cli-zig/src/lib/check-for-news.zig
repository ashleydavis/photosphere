const std = @import("std");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const INewsItem = node_api.news_fetcher.INewsItem;
const fetchNews = node_api.news_fetcher.fetchNews;
const getShownNewsIds = node_api.news_state.getShownNewsIds;
const addShownNewsIds = node_api.news_state.addShownNewsIds;

//
// URL of the news feed published in the Photosphere GitHub repo. Overridable via
// PHOTOSPHERE_NEWS_URL for the local demo scripts (apps/cli/demo-news.sh and
// apps/desktop/demo-news.sh) so they can point at a checked-in test/demo-news.yaml.
// (TypeScript reads the environment when the module loads; Zig reads it when called.)
//
fn NEWS_URL() []const u8 {
    if (node_utils.process_env.getEnv("PHOTOSPHERE_NEWS_URL")) |url| {
        if (url.len > 0) {
            return url;
        }
    }
    return "https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml";
}

//
// The body of checkForNews inside its try block (errors become undefined).
//
fn checkForNewsUnsafe(allocator: std.mem.Allocator, io: std.Io) !?INewsItem {
    const items = try fetchNews(allocator, io, NEWS_URL());
    const shownIds = try getShownNewsIds(allocator, io);
    var nextItem: ?INewsItem = null;
    for (items) |item| {
        var shown = false;
        for (shownIds) |shownId| {
            if (std.mem.eql(u8, shownId, item.id)) {
                shown = true;
                break;
            }
        }
        if (!shown) {
            nextItem = item;
            break;
        }
    }
    const found = nextItem orelse return null;
    try addShownNewsIds(allocator, io, &.{found.id});
    return found;
}

//
// Fetches the news feed and returns the oldest item that has not yet been shown on this
// install. Marks the returned item as shown so it is not returned again. Returns undefined
// when all items have already been seen, or when the fetch or parse step fails.
//
pub fn checkForNews(allocator: std.mem.Allocator, io: std.Io) ?INewsItem {
    return checkForNewsUnsafe(allocator, io) catch null;
}

//
// A news item paired with whether it has already been shown on this install. Returned by
// getAllNews() so callers (like the `psi news` command) can render the full feed and
// indicate which items are new to the user.
//
pub const INewsItemWithState = struct {
    //
    // The news item as published in news.yaml.
    //
    item: INewsItem,

    //
    // True when the item's id is already recorded in shown_news_ids.
    //
    seen: bool,
};

//
// The body of getAllNews inside its try block (errors become an empty array).
//
fn getAllNewsUnsafe(allocator: std.mem.Allocator, io: std.Io) ![]const INewsItemWithState {
    const items = try fetchNews(allocator, io, NEWS_URL());
    const shownIds = try getShownNewsIds(allocator, io);
    const result = try allocator.alloc(INewsItemWithState, items.len);
    for (items, 0..) |item, index| {
        var seen = false;
        for (shownIds) |shownId| {
            if (std.mem.eql(u8, shownId, item.id)) {
                seen = true;
                break;
            }
        }
        result[index] = .{
            .item = item,
            .seen = seen,
        };
    }
    return result;
}

//
// Fetches the entire news feed (regardless of seen state) and pairs each item with a
// `seen` flag derived from the locally-persisted shown_news_ids list. Returns an
// empty array on fetch or parse failure so callers can render gracefully when offline.
//
pub fn getAllNews(allocator: std.mem.Allocator, io: std.Io) []const INewsItemWithState {
    return getAllNewsUnsafe(allocator, io) catch &.{};
}

//
// Records the supplied news item ids as shown, so they no longer surface via checkForNews()
// in subsequent CLI invocations. Used by `psi news` after rendering the full feed.
//
pub fn markNewsAsShown(allocator: std.mem.Allocator, io: std.Io, ids: []const []const u8) void {
    if (ids.len == 0) {
        return;
    }
    addShownNewsIds(allocator, io, ids) catch {
        // News persistence failures must never block the user.
    };
}

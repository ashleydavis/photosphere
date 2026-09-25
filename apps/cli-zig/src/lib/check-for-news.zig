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

// Not ported: INewsItemWithState, getAllNews, markNewsAsShown (only used by psi news).

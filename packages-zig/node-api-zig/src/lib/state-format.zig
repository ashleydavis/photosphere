const std = @import("std");
const node_utils = @import("node-utils-zig");
const errors = @import("utils-zig").errors;

//
// The on-disk contents of state.json and the conversions between it and the in-memory type.
//
// This is the sibling of config-format.zig, and the split between them is what each file is for.
// config.toml holds what the user chose: what automatic import watches, whether syncing
// runs. state.json holds what the app remembers on its own so the interface comes back the way it was
// left: the folder a dialog last opened at, which sidebar sections are collapsed, how the gallery was
// sorted, which news has already been shown, which databases were opened lately and which to reopen.
// The app alone writes state.json, and what it holds belongs to this machine, which is why it is
// documented here rather than for users the way config.toml is.
//
// It sits beside config.toml, in ~/.config/photosphere on the CLI and the desktop app and at the root
// of the storage sandbox on a mobile, and PHOTOSPHERE_CONFIG_DIR moves both together.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//
// (Zig: the YAML documents (IYamlStateFile and its sections) are std.json.Value objects, which is what
// node-utils-zig's YAML reader and writer work in, so they have no separate struct types. A value the
// interface keeps (IUiStateValue: boolean, number, string or string[]) is a std.json.Value of that kind.)
//

//
// One news item as the app has it in hand, which is the part of a published item a toast needs.
//
// Held here rather than reusing INewsItem from news-fetcher.zig because that module reads files and
// this one is bundled into the mobile worker, and because this is a cache of what was fetched rather
// than the published format itself.
//
pub const INewsFeedItem = struct {
    // Stable id used to track whether the item has been shown.
    id: []const u8,

    // The toast message.
    message: []const u8,

    // Optional toast colour variant.
    color: ?[]const u8 = null,

    // Optional auto-dismiss duration in ms (0 or absent means no auto-dismiss).
    duration: ?std.json.Value = null,

    // Optional link shown in the toast.
    link: ?[]const u8 = null,
};

//
// One cached news item as the state file holds it, with every field optional and named by its key.
//
pub const IStoredNewsFeedItem = struct {
    // Stable id used to track whether the item has been shown.
    id: ?[]const u8 = null,
    // The toast message.
    message: ?[]const u8 = null,
    // Optional toast colour variant.
    color: ?[]const u8 = null,
    // Optional auto-dismiss duration in ms.
    duration: ?f64 = null,
    // Optional link shown in the toast.
    link: ?[]const u8 = null,
};

//
// What the notification system has already shown, so it does not show it twice, and the feed it has
// in hand to show from.
//
// Shared between the desktop app and the CLI on the same machine: an item announced by one is not
// announced again by the other.
//
pub const INewsState = struct {
    //
    // Stable ids of news items already shown to the user, in the order they were first seen.
    //
    shownNewsIds: []const []const u8,

    //
    // The release version the user has already been told about. A newer release notifies again and
    // overwrites this.
    //
    lastShownUpdateVersion: ?[]const u8 = null,

    //
    // The feed the app last had in hand. The CLI and the desktop app fetch it each time and never
    // keep it, so this is only ever written on a mobile, where there is nothing else to hold it.
    //
    feed: []const INewsFeedItem,
};

//
// What the file dialogs and the developer tools remember. Only meaningful where there is a window.
//
pub const IStateDesktopSection = struct {
    //
    // The folder the file dialog reopens at.
    //
    lastFolder: ?[]const u8 = null,

    //
    // The folder the download dialog reopens at.
    //
    lastDownloadFolder: ?[]const u8 = null,

    //
    // Whether the native inspector was open when the app closed, so it can be reopened on startup.
    //
    devToolsOpen: ?bool = null,
};

//
// What the search sidebar remembers. The searches the user deliberately SAVED are a setting and live
// in config.toml; these are the ones they merely ran.
//
pub const ISearchesState = struct {
    //
    // Recently executed searches, most recent first, capped at MAX_RECENT_SEARCHES.
    //
    recentSearches: ?[]const []const u8 = null,
};

//
// How the gallery was last being looked at.
//
pub const IGalleryState = struct {
    //
    // The field the gallery was sorted by.
    //
    sort: ?[]const u8 = null,

    //
    // The height of a gallery row, in pixels, as the user last dragged it (a number value).
    //
    rowHeight: ?std.json.Value = null,
};

//
// Which databases were opened lately and which one to reopen. The databases themselves are
// configuration and live in databases.toml; this is only what the app remembered about using them.
//
pub const IDatabasesState = struct {
    //
    // Names of the databases opened most recently, most recent first, as they were written,
    // including a name whose record has since left databases.toml.
    //
    recentNames: []const []const u8 = &.{},

    //
    // Path of the database to reopen at the next start, absent when the last one open was closed.
    //
    lastOpenedPath: ?[]const u8 = null,
};

//
// Everything state.json holds, in memory, with camelCase fields.
//
pub const IStateFile = struct {
    //
    // What the file dialogs and the developer tools remember.
    //
    desktop: IStateDesktopSection,

    //
    // What the search sidebar remembers.
    //
    searches: ISearchesState,

    //
    // How the gallery was last being looked at.
    //
    gallery: IGalleryState,

    //
    // What the notification system has already shown, and the feed it has in hand.
    //
    news: INewsState,

    //
    // Which databases were opened lately and which one to reopen.
    //
    databases: IDatabasesState,
};

//
// The toast colours a cached news item is allowed to name. An item naming anything else loses its
// colour rather than passing it through, because the value reaches the interface and picking a style
// by a name nobody defined leaves a toast with no styling at all.
//
pub const ALLOWED_NEWS_COLORS = [_][]const u8{ "primary", "success", "warning", "danger", "neutral" };

//

//
// The cached feed as the state file holds it, from the items the app has in hand.
//
pub fn newsFeedToStored(allocator: std.mem.Allocator, feed: []const INewsFeedItem) ![]const IStoredNewsFeedItem {
    var stored: std.ArrayList(IStoredNewsFeedItem) = .empty;
    for (feed) |item| {
        var duration: ?f64 = null;
        if (item.duration) |value| {
            if (value == .integer) {
                duration = @floatFromInt(value.integer);
            }
            else if (value == .float) {
                duration = value.float;
            }
        }
        try stored.append(allocator, .{
            .id = item.id,
            .message = item.message,
            .color = item.color,
            .duration = duration,
            .link = item.link,
        });
    }
    return stored.items;
}

//
// The cached feed the app has in hand, from the items the state file holds. An item with no id or no message is dropped, a colour
// nobody defined is dropped and a duration that is not finite is dropped, as the YAML reader did.
//
pub fn newsFeedFromStored(allocator: std.mem.Allocator, stored: ?[]const IStoredNewsFeedItem) ![]const INewsFeedItem {
    const present = stored orelse return &.{};
    var feed: std.ArrayList(INewsFeedItem) = .empty;
    for (present) |item| {
        const id = item.id orelse continue;
        const message = item.message orelse continue;
        var feedItem: INewsFeedItem = .{
            .id = id,
            .message = message,
        };
        if (item.color) |color| {
            for (ALLOWED_NEWS_COLORS) |allowedColor| {
                if (std.mem.eql(u8, color, allowedColor)) {
                    feedItem.color = color;
                }
            }
        }
        if (item.duration) |duration| {
            if (std.math.isFinite(duration)) {
                feedItem.duration = if (duration == @floor(duration))
                    .{ .integer = @intFromFloat(duration) }
                else
                    .{ .float = duration };
            }
        }
        feedItem.link = item.link;
        try feed.append(allocator, feedItem);
    }
    return feed.items;
}

//
pub fn defaultStateFile(allocator: std.mem.Allocator) !IStateFile {
    _ = allocator;
    return .{
        .desktop = .{},
        .searches = .{},
        .gallery = .{},
        .news = .{ .shownNewsIds = &.{}, .feed = &.{} },
        .databases = .{},
    };
}

//

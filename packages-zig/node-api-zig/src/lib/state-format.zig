const std = @import("std");

//
// The on-disk contents of state.yaml and the conversions between it and the in-memory type.
//
// This is the sibling of config-format.ts, and the split between them is what each file is for.
// config.yaml holds what the user chose: the theme, what automatic import watches, whether syncing
// runs. state.yaml holds what the app remembers on its own so the interface comes back the way it was
// left: the folder a dialog last opened at, which sidebar sections are collapsed, how the gallery was
// sorted, which news has already been shown. Nobody edits state.yaml, and nothing in it is worth
// carrying to another machine, which is why it is not documented for users the way config.yaml is.
//
// It sits beside config.yaml, in ~/.config/photosphere on the CLI and the desktop app and at the root
// of the storage sandbox on a phone, and PHOTOSPHERE_CONFIG_DIR moves both together.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//
// (Zig: the YAML documents (IYamlStateFile and its sections) are std.json.Value objects, which is what
// node-utils-zig's YAML stand-in reads and writes, so they have no separate struct types. A value the
// interface keeps (IUiStateValue: boolean, number, string or string[]) is a std.json.Value of that kind.)
//

//
// The interface's own keys, under the names the interface uses.
//
// Every other section of this file is named and typed here. This one is a map, because these keys
// cannot be declared in advance: a collapsible section builds its own key from its id, so a new one in
// a later release brings a new key with it. Before this section existed the desktop app accepted every
// one of these and then dropped it on the way to disk, so a collapsed sidebar never survived a restart.
// (Zig: each interface key and what was last stored under it, in insertion order.)
//
pub const IUiSection = std.json.ObjectMap;

//
// One news item as the app has it in hand, which is the part of a published item a toast needs.
//
// Held here rather than reusing INewsItem from news-fetcher.ts because that module reads files and
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
    // keep it, so this is only ever written on a phone, where there is nothing else to hold it.
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
// in config.yaml; these are the ones they merely ran.
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
// Everything state.yaml holds, in memory, with camelCase fields.
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
    // The interface's own working state, under the keys the interface uses.
    //
    ui: IUiSection,
};

//
// The toast colours a cached news item is allowed to name. An item naming anything else loses its
// colour rather than passing it through, because the value reaches the interface and picking a style
// by a name nobody defined leaves a toast with no styling at all.
//
pub const ALLOWED_NEWS_COLORS = [_][]const u8{ "primary", "success", "warning", "danger", "neutral" };

//
// True when the value is an object we can read keys off, and not an array or null.
//
// Every section is read through this because a hand-edited file can put a string or a list where a
// section belongs, and reading keys off one of those gives undefined for everything, which would
// silently look like an empty section rather than a malformed one.
//
fn isSection(value: ?std.json.Value) bool {
    return value != null and value.? == .object;
}

//
// Gets a string field of a section (`typeof section.key === "string"`). (No TypeScript counterpart.)
//
fn stringField(section: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = section.get(key) orelse {
        return null;
    };
    return if (value == .string) value.string else null;
}

//
// True when the value is a number (`typeof value === "number"`). (No TypeScript counterpart.)
//
fn isNumber(value: std.json.Value) bool {
    return value == .integer or value == .float or value == .number_string;
}

//
// True when the value is a finite number (`typeof value === "number" && Number.isFinite(value)`).
// (No TypeScript counterpart.)
//
fn isFiniteNumber(value: std.json.Value) bool {
    return switch (value) {
        .integer => true,
        .float => |float| std.math.isFinite(float),
        .number_string => true,
        else => false,
    };
}

//
// The strings of an array (`array.filter(entry => typeof entry === "string")`). (No TypeScript counterpart.)
//
fn stringsOf(allocator: std.mem.Allocator, array: std.json.Array) ![]const []const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    for (array.items) |entry| {
        if (entry == .string) {
            try strings.append(allocator, entry.string);
        }
    }
    return strings.items;
}

//
// True when the value is one an interface key is allowed to hold.
//
pub fn isUiStateValue(value: std.json.Value) bool {
    if (value == .bool or isNumber(value) or value == .string) {
        return true;
    }
    if (value != .array) {
        return false;
    }
    for (value.array.items) |entry| {
        if (entry != .string) {
            return false;
        }
    }
    return true;
}

//
// Turns the `desktop` section into its in-memory form, dropping anything of the wrong type.
//
fn yamlToStateDesktopSection(section: ?std.json.Value) IStateDesktopSection {
    if (!isSection(section)) {
        return .{};
    }

    const object = section.?.object;
    var desktop: IStateDesktopSection = .{};
    if (stringField(object, "last_folder")) |lastFolder| {
        desktop.lastFolder = lastFolder;
    }
    if (stringField(object, "last_download_folder")) |lastDownloadFolder| {
        desktop.lastDownloadFolder = lastDownloadFolder;
    }
    if (object.get("dev_tools_open")) |devToolsOpen| {
        if (devToolsOpen == .bool) {
            desktop.devToolsOpen = devToolsOpen.bool;
        }
    }
    return desktop;
}

//
// Turns the `searches` section into its in-memory form.
//
fn yamlToSearchesState(allocator: std.mem.Allocator, section: ?std.json.Value) !ISearchesState {
    if (!isSection(section)) {
        return .{};
    }

    var searches: ISearchesState = .{};
    if (section.?.object.get("recent")) |recent| {
        if (recent == .array) {
            searches.recentSearches = try stringsOf(allocator, recent.array);
        }
    }
    return searches;
}

//
// Turns the `gallery` section into its in-memory form.
//
fn yamlToGalleryState(section: ?std.json.Value) IGalleryState {
    if (!isSection(section)) {
        return .{};
    }

    const object = section.?.object;
    var gallery: IGalleryState = .{};
    if (stringField(object, "sort")) |sort| {
        gallery.sort = sort;
    }
    if (object.get("row_height")) |rowHeight| {
        if (isFiniteNumber(rowHeight)) {
            gallery.rowHeight = rowHeight;
        }
    }
    return gallery;
}

//
// Turns one cached news item into its in-memory form, or undefined when it has nothing to show.
//
// An item with no id or no message is dropped: the id is how the app knows whether it has been shown,
// and the message is the whole toast, so an item missing either would either be announced forever or
// announced as an empty box.
//
fn yamlToNewsFeedItem(item: std.json.Value) ?INewsFeedItem {
    if (!isSection(item)) {
        return null;
    }
    const object = item.object;
    const id = stringField(object, "id") orelse {
        return null;
    };
    const message = stringField(object, "message") orelse {
        return null;
    };

    var feedItem: INewsFeedItem = .{
        .id = id,
        .message = message,
    };
    if (stringField(object, "color")) |color| {
        for (ALLOWED_NEWS_COLORS) |allowedColor| {
            if (std.mem.eql(u8, color, allowedColor)) {
                feedItem.color = color;
            }
        }
    }
    if (object.get("duration")) |duration| {
        if (isFiniteNumber(duration)) {
            feedItem.duration = duration;
        }
    }
    if (stringField(object, "link")) |link| {
        feedItem.link = link;
    }
    return feedItem;
}

//
// Turns the `news` section into its in-memory form.
//
// A malformed section comes back as an empty state rather than throwing, because the user must never
// be blocked from starting the app by what the notification system has recorded.
//
fn yamlToNewsState(allocator: std.mem.Allocator, section: ?std.json.Value) !INewsState {
    if (!isSection(section)) {
        return .{
            .shownNewsIds = &.{},
            .feed = &.{},
        };
    }

    const object = section.?.object;
    var feed: std.ArrayList(INewsFeedItem) = .empty;
    if (object.get("feed")) |rawFeed| {
        if (rawFeed == .array) {
            for (rawFeed.array.items) |rawItem| {
                if (yamlToNewsFeedItem(rawItem)) |item| {
                    try feed.append(allocator, item);
                }
            }
        }
    }

    var news: INewsState = .{
        .shownNewsIds = &.{},
        .feed = feed.items,
    };
    if (object.get("shown_news_ids")) |shownNewsIds| {
        if (shownNewsIds == .array) {
            news.shownNewsIds = try stringsOf(allocator, shownNewsIds.array);
        }
    }
    if (stringField(object, "last_shown_update_version")) |version| {
        if (version.len > 0) {
            news.lastShownUpdateVersion = version;
        }
    }
    return news;
}

//
// Turns the `ui` section into its in-memory form, dropping any key holding something it could not have
// been written with.
//
// A dropped key reads as never having been set, which the interface already handles: a collapsible
// section with no stored state opens at its default.
//
fn yamlToUiSection(allocator: std.mem.Allocator, section: ?std.json.Value) !IUiSection {
    if (!isSection(section)) {
        return .empty;
    }

    var ui: IUiSection = .empty;
    var iterator = section.?.object.iterator();
    while (iterator.next()) |entry| {
        if (isUiStateValue(entry.value_ptr.*)) {
            try ui.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return ui;
}

//
// Turns the parsed document into the state the app works with.
//
// A section that is malformed falls back to that section's own defaults without discarding the
// sections that did parse, and a key nothing recognises is ignored rather than rejected.
//
pub fn yamlToStateFile(allocator: std.mem.Allocator, document: ?std.json.Value) !IStateFile {
    const parsed: std.json.ObjectMap = if (isSection(document)) document.?.object else .empty;

    return .{
        .desktop = yamlToStateDesktopSection(parsed.get("desktop")),
        .searches = try yamlToSearchesState(allocator, parsed.get("searches")),
        .gallery = yamlToGalleryState(parsed.get("gallery")),
        .news = try yamlToNewsState(allocator, parsed.get("news")),
        .ui = try yamlToUiSection(allocator, parsed.get("ui")),
    };
}

//
// Makes a YAML sequence of strings. (No TypeScript counterpart: TypeScript writes the array itself.)
//
fn stringArray(allocator: std.mem.Allocator, strings: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (strings) |text| {
        try array.append(.{ .string = text });
    }
    return .{ .array = array };
}

//
// Converts one cached news item to its on-disk contents, writing only the fields it has.
//
fn newsFeedItemToYaml(allocator: std.mem.Allocator, item: INewsFeedItem) !std.json.Value {
    var yamlItem: std.json.ObjectMap = .empty;
    try yamlItem.put(allocator, "id", .{ .string = item.id });
    try yamlItem.put(allocator, "message", .{ .string = item.message });
    if (item.color) |color| {
        try yamlItem.put(allocator, "color", .{ .string = color });
    }
    if (item.duration) |duration| {
        try yamlItem.put(allocator, "duration", duration);
    }
    if (item.link) |link| {
        try yamlItem.put(allocator, "link", .{ .string = link });
    }
    return .{ .object = yamlItem };
}

//
// Writes a section into the document, or leaves the document without it when it holds nothing, so a
// file never carries an empty section the next reader has to work out means nothing.
//
fn writeSection(allocator: std.mem.Allocator, document: *std.json.ObjectMap, name: []const u8, section: std.json.ObjectMap) !void {
    if (section.count() > 0) {
        try document.put(allocator, name, .{ .object = section });
        return;
    }
    _ = document.orderedRemove(name);
}

//
// Turns the state into the document written to disk.
//
// An absent optional field stays absent rather than being written as null, so a file the app wrote
// holds only what it actually remembers.
//
pub fn stateFileToYaml(allocator: std.mem.Allocator, state: IStateFile) !std.json.Value {
    var document: std.json.ObjectMap = .empty;

    var desktop: std.json.ObjectMap = .empty;
    if (state.desktop.lastFolder) |lastFolder| {
        try desktop.put(allocator, "last_folder", .{ .string = lastFolder });
    }
    if (state.desktop.lastDownloadFolder) |lastDownloadFolder| {
        try desktop.put(allocator, "last_download_folder", .{ .string = lastDownloadFolder });
    }
    if (state.desktop.devToolsOpen) |devToolsOpen| {
        try desktop.put(allocator, "dev_tools_open", .{ .bool = devToolsOpen });
    }
    try writeSection(allocator, &document, "desktop", desktop);

    var searches: std.json.ObjectMap = .empty;
    if (state.searches.recentSearches) |recentSearches| {
        try searches.put(allocator, "recent", try stringArray(allocator, recentSearches));
    }
    try writeSection(allocator, &document, "searches", searches);

    var gallery: std.json.ObjectMap = .empty;
    if (state.gallery.sort) |sort| {
        try gallery.put(allocator, "sort", .{ .string = sort });
    }
    if (state.gallery.rowHeight) |rowHeight| {
        try gallery.put(allocator, "row_height", rowHeight);
    }
    try writeSection(allocator, &document, "gallery", gallery);

    var news: std.json.ObjectMap = .empty;
    if (state.news.shownNewsIds.len > 0) {
        try news.put(allocator, "shown_news_ids", try stringArray(allocator, state.news.shownNewsIds));
    }
    if (state.news.lastShownUpdateVersion) |version| {
        try news.put(allocator, "last_shown_update_version", .{ .string = version });
    }
    if (state.news.feed.len > 0) {
        var feed = std.json.Array.init(allocator);
        for (state.news.feed) |item| {
            try feed.append(try newsFeedItemToYaml(allocator, item));
        }
        try news.put(allocator, "feed", .{ .array = feed });
    }
    try writeSection(allocator, &document, "news", news);

    try writeSection(allocator, &document, "ui", try state.ui.clone(allocator));

    return .{ .object = document };
}

// Not ported: defaultStateFile, IParsedStateFile, parseStateYamlChecked, buildStateYaml (the desktop app and the
// mobile worker, not psi replicate or psi verify).

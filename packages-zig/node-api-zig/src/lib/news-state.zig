const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const state_file = @import("state-file.zig");
const state_format = @import("state-format.zig");
const errors = utils.errors;
const config_state = @import("ziggy").config_state;

//
// Per-install state for the notification system, held in the `news` section of state.json
// ($PHOTOSPHERE_CONFIG_DIR/state.json, defaulting to ~/.config/photosphere/state.json) and shared
// between the desktop app and the CLI on the same machine, so a news item or update version surfaced
// on one surface is suppressed on the other.
//
// It is in the state file rather than the config file because nobody chose any of it: it is what the
// app has already told the user, recorded so it does not tell them twice.
//
// Not to be confused with the news.yaml in the root of the Photosphere repository, which is the
// published feed fetched over the network and has nothing to do with this.
//
pub const INewsState = state_format.INewsState;

//
// The body of loadNewsState inside its try block. (Zig: a function of its own, because a Zig catch handles the error of
// one expression and the try block holds several statements.)
//
fn loadNewsStateUnsafe(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8) !INewsState {
    return .{
        .shownNewsIds = (try config_state.state.get(?[]const []const u8, allocator, io, state_path, "news.shown_news_ids")) orelse &.{},
        .lastShownUpdateVersion = try config_state.state.get(?[]const u8, allocator, io, state_path, "news.last_shown_update_version"),
        .feed = try state_format.newsFeedFromStored(allocator, try config_state.state.get(?[]const state_format.IStoredNewsFeedItem, allocator, io, state_path, "news.feed")),
    };
}

//
// Loads the news state. Returns an empty state when the state file is missing, empty, or malformed.
// The user must never be blocked by news-state failures.
//
// A file that cannot be read is reported rather than swallowed: it means something else has written a
// broken file, and the notifications going quiet is the only symptom anyone would otherwise see.
//
pub fn loadNewsState(allocator: std.mem.Allocator, io: std.Io, log: ILog, state_path: []const u8) !INewsState {
    return loadNewsStateUnsafe(allocator, io, state_path) catch |err| {
        log.err(try std.fmt.allocPrint(allocator, "The news state could not be read, carrying on with an empty one: {s}: {s}", .{
            if (err == error.Thrown or err == error.FatalError) errors.lastErrorName() else "Error",
            errors.errorMessage(err),
        }));
        return .{
            .shownNewsIds = &.{},
            .feed = &.{},
        };
    };
}

//
// The change saveNewsState runs: replaces the news keys, leaving every other key as it is.
//
const SaveNewsStateChange = struct {
    // The state to save.
    state: INewsState,

    //
    // Writes the three news keys.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config_state.state.Values) !void {
        try values.set("news.shown_news_ids", self.state.shownNewsIds);
        try values.set("news.last_shown_update_version", self.state.lastShownUpdateVersion);
        try values.set("news.feed", try state_format.newsFeedToStored(arena, self.state.feed));
    }
};

//
// Saves the news state into the `news` keys of the state file, leaving every other key exactly as it is.
//
pub fn saveNewsState(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, state: INewsState) !void {
    try config_state.state.update(allocator, io, state_path, SaveNewsStateChange{ .state = state });
}

//
// Returns the list of news item ids that have already been shown on this install.
//
pub fn getShownNewsIds(allocator: std.mem.Allocator, io: std.Io, log: ILog, state_path: []const u8) ![]const []const u8 {
    const state = try loadNewsState(allocator, io, log, state_path);
    return state.shownNewsIds;
}

//
// The change addShownNewsIds runs: reads the list and writes it back under one lock.
//
const AddShownNewsIdsChange = struct {
    // The ids to add.
    ids: []const []const u8,

    //
    // Appends the ids that are not already in the list.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config_state.state.Values) !void {
        const existing = (try values.get(?[]const []const u8, "news.shown_news_ids")) orelse &.{};
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (existing) |id| {
            try seen.put(arena, id, {});
        }
        var merged: std.ArrayList([]const u8) = .empty;
        try merged.appendSlice(arena, existing);
        for (self.ids) |id| {
            if (!seen.contains(id)) {
                try seen.put(arena, id, {});
                try merged.append(arena, id);
            }
        }
        try values.set("news.shown_news_ids", merged.items);
    }
};

//
// Appends the given news item ids to the persisted set, deduping the union of
// existing + new ids while preserving the order in which ids were first seen.
//
pub fn addShownNewsIds(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, ids: []const []const u8) !void {
    if (ids.len == 0) {
        return;
    }
    try config_state.state.update(allocator, io, state_path, AddShownNewsIdsChange{ .ids = ids });
}

//
// Returns the latest update version the user has already been notified about,
// or null when no update has been shown yet.
//
pub fn getLastShownUpdateVersion(allocator: std.mem.Allocator, io: std.Io, log: ILog, state_path: []const u8) !?[]const u8 {
    const state = try loadNewsState(allocator, io, log, state_path);
    return state.lastShownUpdateVersion;
}

//
// Records the given update version as having been shown to the user. Subsequent
// checkForUpdates() calls that return the same version will suppress their
// notification; a newer GitHub release will re-trigger the notification and
// overwrite this field.
//
pub fn setLastShownUpdateVersion(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, version: []const u8) !void {
    try config_state.state.set(allocator, io, state_path, "news.last_shown_update_version", version);
}

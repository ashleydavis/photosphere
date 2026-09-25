const std = @import("std");
const utils = @import("utils-zig");
const state_file = @import("state-file.zig");
const state_format = @import("state-format.zig");
const errors = utils.errors;
const log = &utils.log.log;
const loadStateFile = state_file.loadStateFile;
const updateStateFile = state_file.updateStateFile;
const IStateFile = state_format.IStateFile;

//
// Per-install state for the notification system, held in the `news` section of state.yaml
// ($PHOTOSPHERE_CONFIG_DIR/state.yaml, defaulting to ~/.config/photosphere/state.yaml) and shared
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
// The body of loadNewsState inside its try block.
//
fn loadNewsStateUnsafe(allocator: std.mem.Allocator, io: std.Io) !INewsState {
    const news = (try loadStateFile(allocator, io)).news;
    var state: INewsState = .{
        .shownNewsIds = try allocator.dupe([]const u8, news.shownNewsIds),
        .feed = try allocator.dupe(state_format.INewsFeedItem, news.feed),
    };
    if (news.lastShownUpdateVersion) |version| {
        state.lastShownUpdateVersion = version;
    }
    return state;
}

//
// Loads the news state. Returns an empty state when the state file is missing, empty, or malformed.
// The user must never be blocked by news-state failures.
//
// A file that cannot be read is reported rather than swallowed: it means something else has written a
// broken file, and the notifications going quiet is the only symptom anyone would otherwise see.
//
pub fn loadNewsState(allocator: std.mem.Allocator, io: std.Io) !INewsState {
    return loadNewsStateUnsafe(allocator, io) catch |err| {
        log.@"error"(try std.fmt.allocPrint(allocator, "The news state could not be read, carrying on with an empty one: {s}: {s}", .{
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
// The mutator of saveNewsState (the arrow function in TypeScript).
//
const SaveNewsStateMutator = struct {
    // The state to save.
    state: INewsState,

    //
    // Replaces the `news` section with the state.
    //
    pub fn run(self: *const SaveNewsStateMutator, allocator: std.mem.Allocator, stateFile: *IStateFile) !void {
        _ = allocator;
        stateFile.news = .{
            .shownNewsIds = self.state.shownNewsIds,
            .feed = self.state.feed,
        };
        if (self.state.lastShownUpdateVersion) |version| {
            stateFile.news.lastShownUpdateVersion = version;
        }
    }
};

//
// Saves the news state into the `news` section of the state file, leaving every other section exactly
// as it is. It goes through updateStateFile rather than a load-then-save so anything changed between
// this read and this write is not discarded.
//
pub fn saveNewsState(allocator: std.mem.Allocator, io: std.Io, state: INewsState) !void {
    const mutator: SaveNewsStateMutator = .{ .state = state };
    try updateStateFile(allocator, io, &mutator);
}

//
// Returns the list of news item ids that have already been shown on this install.
//
pub fn getShownNewsIds(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const state = try loadNewsState(allocator, io);
    return state.shownNewsIds;
}

//
// The mutator of addShownNewsIds (the arrow function in TypeScript).
//
const AddShownNewsIdsMutator = struct {
    // The ids to add.
    ids: []const []const u8,

    //
    // Appends the ids that are not already in the list.
    //
    pub fn run(self: *const AddShownNewsIdsMutator, allocator: std.mem.Allocator, stateFile: *IStateFile) !void {
        const existing = stateFile.news.shownNewsIds;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (existing) |id| {
            try seen.put(allocator, id, {});
        }
        var merged: std.ArrayList([]const u8) = .empty;
        try merged.appendSlice(allocator, existing);
        for (self.ids) |id| {
            if (!seen.contains(id)) {
                try seen.put(allocator, id, {});
                try merged.append(allocator, id);
            }
        }
        stateFile.news.shownNewsIds = merged.items;
    }
};

//
// Appends the given news item ids to the persisted set, deduping the union of
// existing + new ids while preserving the order in which ids were first seen.
//
pub fn addShownNewsIds(allocator: std.mem.Allocator, io: std.Io, ids: []const []const u8) !void {
    if (ids.len == 0) {
        return;
    }

    const mutator: AddShownNewsIdsMutator = .{ .ids = ids };
    try updateStateFile(allocator, io, &mutator);
}

//
// Returns the latest update version the user has already been notified about,
// or undefined when no update has been shown yet.
//
pub fn getLastShownUpdateVersion(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const state = try loadNewsState(allocator, io);
    return state.lastShownUpdateVersion;
}

//
// The mutator of setLastShownUpdateVersion (the arrow function in TypeScript).
//
const SetLastShownUpdateVersionMutator = struct {
    // The version to record.
    version: []const u8,

    //
    // Records the version.
    //
    pub fn run(self: *const SetLastShownUpdateVersionMutator, allocator: std.mem.Allocator, stateFile: *IStateFile) !void {
        _ = allocator;
        stateFile.news.lastShownUpdateVersion = self.version;
    }
};

//
// Records the given update version as having been shown to the user. Subsequent
// checkForUpdates() calls that return the same version will suppress their
// notification; a newer GitHub release will re-trigger the notification and
// overwrite this field.
//
pub fn setLastShownUpdateVersion(allocator: std.mem.Allocator, io: std.Io, version: []const u8) !void {
    const mutator: SetLastShownUpdateVersionMutator = .{ .version = version };
    try updateStateFile(allocator, io, &mutator);
}

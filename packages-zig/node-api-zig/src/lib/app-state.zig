const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const state_file = @import("state-file.zig");
const app_state_format = @import("app-state-format.zig");
const fs = node_utils.fs;
const errors = utils.errors;

const ziggy = @import("ziggy");
const config_state = ziggy.config_state;
const ILog = @import("utils-zig").log.ILog;

//
// The state store the shared UI reads and writes through, backed by state.json.
//
// The sibling of app-config.zig. That one holds what the user chose; this one holds what the app
// remembered so the interface comes back the way it was left: the folder a dialog last opened at, the
// searches that were merely run, how the gallery was sorted, which sidebar sections are collapsed.
//
// What the state keys mean is not decided here. app-state-format.zig owns that, and is where the flat
// view and its conversions live, so the mobile's worker can be handed the same definition without
// dragging the filesystem in with it. This module is the file half: loading it, and changing it.
//

// (Zig has no re-export of everything, so each name is re-exported.)
pub const IAppState = app_state_format.IAppState;
pub const IAppStateValue = app_state_format.IAppStateValue;
pub const MAX_RECENT_SEARCHES = app_state_format.MAX_RECENT_SEARCHES;

//
// Loads the whole state from disk. Every leaf is read on its own, so a missing or partial file gives every key its default and one
// wrong value gives only its own key its default.
//
pub fn loadAppState(allocator: std.mem.Allocator, io: std.Io, log: ILog, state_path: []const u8) !IAppState {
    const row_height = try state_file.readStateSetting(?f64, allocator, io, log, .{ .statePath = state_path, .keyPath = "gallery.row_height" });
    return .{
        .lastFolder = try state_file.readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "desktop.last_folder" }),
        .lastDownloadFolder = try state_file.readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "desktop.last_download_folder" }),
        .devToolsOpen = try state_file.readStateSetting(?bool, allocator, io, log, .{ .statePath = state_path, .keyPath = "desktop.dev_tools_open" }),
        .recentSearches = try state_file.readStateSetting(?[]const []const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "searches.recent" }),
        .gallerySort = try state_file.readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "gallery.sort" }),
        .galleryRowHeight = if (row_height) |height| .{ .float = height } else null,
    };
}

//
// The state keys that remember a folder chosen in a folder picker.
//
pub const FolderStateKey = enum {
    lastFolder,
    lastDownloadFolder,
};

//
// Every state key a folder picker is allowed to read from and write back to.
//
pub const FOLDER_STATE_KEYS = [_]FolderStateKey{
    .lastFolder,
    .lastDownloadFolder,
};

//
// Narrows a folder key to one the state actually holds, throwing when it is not one of them.
//
// The key arrives from the renderer as a plain string, so without this an unrecognised key would be
// written under a name nothing ever reads, and the picker would silently forget the folder every time.
//
pub fn asFolderStateKey(folderKey: []const u8) !FolderStateKey {
    for (FOLDER_STATE_KEYS) |candidate| {
        if (std.mem.eql(u8, @tagName(candidate), folderKey)) {
            return candidate;
        }
    }
    // (Zig: the message is built at compile time from FOLDER_STATE_KEYS.)
    const expectedKeys = comptime blk: {
        var joined: []const u8 = "";
        for (FOLDER_STATE_KEYS, 0..) |candidate, candidateIndex| {
            joined = joined ++ (if (candidateIndex > 0) ", " else "") ++ @tagName(candidate);
        }
        break :blk joined;
    };
    return errors.throwError("Unknown folder state key \"{s}\". Expected one of: {s}.", .{
        folderKey,
        expectedKeys,
    });
}

//
// Gets the folder remembered under a folder picker's key, used as the dialog's starting directory.
// Returns undefined when no folder has been remembered under that key yet.
//
pub fn getFolderPath(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, folderKey: []const u8) !?[]const u8 {
    // Checked before the file is read, so an unrecognised key is refused without a read.
    const key = try asFolderStateKey(folderKey);
    const path = switch (key) {
        .lastFolder => "desktop.last_folder",
        .lastDownloadFolder => "desktop.last_download_folder",
    };
    return config_state.state.get(?[]const u8, allocator, io, state_path, path);
}

//
// The mutator of updateFolderPath.
//
const UpdateFolderPathMutator = struct {
    // The key the folder is stored under.
    key: FolderStateKey,

    // The folder to remember.
    folderPath: []const u8,

    //
    // Sets the field the key names.
    //
    pub fn run(self: *const UpdateFolderPathMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        _ = allocator;
        switch (self.key) {
            .lastFolder => state.lastFolder = self.folderPath,
            .lastDownloadFolder => state.lastDownloadFolder = self.folderPath,
        }
    }
};

//
// Remembers the folder a user chose under a folder picker's key.
//
// Only that one key is written, and it is written against the file's CURRENT contents. A folder
// picker stays open for as long as the user takes to choose, so a state read before the dialog opened
// is stale by the time it closes, and writing that whole state back would undo anything changed in
// the meantime.
//
pub fn updateFolderPath(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, folderKey: []const u8, folderPath: []const u8) !void {
    const key = try asFolderStateKey(folderKey);
    const path = switch (key) {
        .lastFolder => "desktop.last_folder",
        .lastDownloadFolder => "desktop.last_download_folder",
    };
    try config_state.state.set(allocator, io, state_path, path, folderPath);
}

//
// The mutator of updateLastFolder.
//
const UpdateLastFolderMutator = struct {
    // The folder to remember.
    folderPath: []const u8,

    //
    // Sets lastFolder.
    //
    pub fn run(self: *const UpdateLastFolderMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        _ = allocator;
        state.lastFolder = self.folderPath;
    }
};

//
// Updates the last folder that was opened in the file dialog.
//
pub fn updateLastFolder(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, folderPath: []const u8) !void {
    try config_state.state.set(allocator, io, state_path, "desktop.last_folder", folderPath);
}

//
// The mutator of updateLastDownloadFolder.
//
const UpdateLastDownloadFolderMutator = struct {
    // The folder to remember.
    folderPath: []const u8,

    //
    // Sets lastDownloadFolder.
    //
    pub fn run(self: *const UpdateLastDownloadFolderMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        _ = allocator;
        state.lastDownloadFolder = self.folderPath;
    }
};

//
// Updates the last folder used when downloading assets.
//
pub fn updateLastDownloadFolder(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, folderPath: []const u8) !void {
    try config_state.state.set(allocator, io, state_path, "desktop.last_download_folder", folderPath);
}

//
// Gets the recent searches list.
//
pub fn getRecentSearches(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8) ![]const []const u8 {
    return (try config_state.state.get(?[]const []const u8, allocator, io, state_path, "searches.recent")) orelse &.{};
}

//
// The mutator of addRecentSearch.
//
const AddRecentSearchMutator = struct {
    // The search to add.
    searchText: []const u8,

    //
    // Puts the search first, dropping an earlier copy of it and anything past MAX_RECENT_SEARCHES.
    //
    pub fn run(self: *const AddRecentSearchMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        var searches: std.ArrayList([]const u8) = .empty;
        try searches.append(allocator, self.searchText);
        for (state.recentSearches orelse &.{}) |item| {
            if (!std.mem.eql(u8, item, self.searchText)) {
                try searches.append(allocator, item);
            }
        }
        state.recentSearches = searches.items[0..@min(searches.items.len, app_state_format.MAX_RECENT_SEARCHES)];
    }
};

//
// Adds a search to the recent searches list, deduplicating and capping at MAX_RECENT_SEARCHES.
//
pub fn addRecentSearch(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, searchText: []const u8) !void {
    try config_state.state.update(allocator, io, state_path, AddRecentSearchChange{ .searchText = searchText });
}

//
// The change addRecentSearch runs, reading the list and writing it back under one lock.
//
const AddRecentSearchChange = struct {
    // The search to add.
    searchText: []const u8,

    //
    // Puts the search first, dropping an earlier copy of it and anything past MAX_RECENT_SEARCHES.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config_state.state.Values) !void {
        var searches: std.ArrayList([]const u8) = .empty;
        try searches.append(arena, self.searchText);
        if (try values.get(?[]const []const u8, "searches.recent")) |existing| {
            for (existing) |item| {
                if (!std.mem.eql(u8, item, self.searchText)) {
                    try searches.append(arena, item);
                }
            }
        }
        try values.set("searches.recent", searches.items[0..@min(searches.items.len, app_state_format.MAX_RECENT_SEARCHES)]);
    }
};

//
// The mutator of removeRecentSearch.
//
const RemoveRecentSearchMutator = struct {
    // The search to remove.
    searchText: []const u8,

    //
    // Keeps every search but that one.
    //
    pub fn run(self: *const RemoveRecentSearchMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        var searches: std.ArrayList([]const u8) = .empty;
        for (state.recentSearches orelse &.{}) |item| {
            if (!std.mem.eql(u8, item, self.searchText)) {
                try searches.append(allocator, item);
            }
        }
        state.recentSearches = searches.items;
    }
};

//
// Removes a search from the recent searches list.
//
pub fn removeRecentSearch(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, searchText: []const u8) !void {
    try config_state.state.update(allocator, io, state_path, RemoveRecentSearchChange{ .searchText = searchText });
}

//
// The change removeRecentSearch runs, reading the list and writing it back under one lock.
//
const RemoveRecentSearchChange = struct {
    // The search to remove.
    searchText: []const u8,

    //
    // Keeps every search but that one.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config_state.state.Values) !void {
        var searches: std.ArrayList([]const u8) = .empty;
        if (try values.get(?[]const []const u8, "searches.recent")) |existing| {
            for (existing) |item| {
                if (!std.mem.eql(u8, item, self.searchText)) {
                    try searches.append(arena, item);
                }
            }
        }
        try values.set("searches.recent", searches.items);
    }
};

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const state_file = @import("state-file.zig");
const app_state_format = @import("app-state-format.zig");
const fs = node_utils.fs;
const errors = utils.errors;
const getStatePath = state_file.getStatePath;
pub const yamlToAppState = app_state_format.yamlToAppState;
pub const appStateToYaml = app_state_format.appStateToYaml;

//
// The state store the shared UI reads and writes through, backed by state.yaml.
//
// The sibling of app-config.ts. That one holds what the user chose; this one holds what the app
// remembered so the interface comes back the way it was left: the folder a dialog last opened at, the
// searches that were merely run, how the gallery was sorted, which sidebar sections are collapsed.
//
// What the state keys mean is not decided here. app-state-format.ts owns that, and is where the flat
// view and its conversions live, so the phone's worker can be handed the same definition without
// dragging the filesystem in with it. This module is the file half: loading it, and changing it.
//

// (TypeScript: `export * from "./app-state-format"`. Zig has no re-export of everything, so each name is re-exported.)
pub const IAppState = app_state_format.IAppState;
pub const IAppStateValue = app_state_format.IAppStateValue;
pub const MAX_RECENT_SEARCHES = app_state_format.MAX_RECENT_SEARCHES;
pub const DECLARED_APP_STATE_KEYS = app_state_format.DECLARED_APP_STATE_KEYS;
pub const getAppStateValue = app_state_format.getAppStateValue;
pub const setAppStateValue = app_state_format.setAppStateValue;
pub const appStateSettings = app_state_format.appStateSettings;

//
// Loads the whole state from disk.
// Returns an empty state when the file does not exist, so every key falls to its own default.
//
pub fn loadAppState(allocator: std.mem.Allocator, io: std.Io) !IAppState {
    const document = try fs.readYaml(allocator, io, try getStatePath(allocator));
    return yamlToAppState(allocator, document);
}

//
// The mutator updateAppState hands to updateYaml (the arrow function in TypeScript): it turns the document into the
// state, lets the caller change it and merges it back into the document.
//
fn AppStateMutator(comptime MutatorT: type) type {
    return struct {
        // The caller's mutator.
        mutator: MutatorT,

        //
        // Applies the caller's mutator to the state the document holds.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, document: std.json.Value) !std.json.Value {
            var state = try yamlToAppState(allocator, document);
            try self.mutator.run(allocator, &state);
            return appStateToYaml(allocator, state, document);
        }
    };
}

//
// Changes the state on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place, under the update lock
// beside the file, so two edits arriving together both survive rather than the second discarding the
// first.
//
// In Zig the mutator is a value with a method `run(self, allocator, state: *IAppState) !void`.
//
pub fn updateAppState(allocator: std.mem.Allocator, io: std.Io, mutator: anytype) !void {
    const appStateMutator: AppStateMutator(@TypeOf(mutator)) = .{
        .mutator = mutator,
    };
    try fs.updateYaml(allocator, io, try getStatePath(allocator), .{
        .object = .empty,
    }, &appStateMutator, 3);
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
    // (Zig: the message is built at compile time, so the list is joined from FOLDER_STATE_KEYS as the TypeScript does at
    // run time.)
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
pub fn getFolderPath(allocator: std.mem.Allocator, io: std.Io, folderKey: []const u8) !?[]const u8 {
    // Checked before the file is opened, so an unrecognised key is refused without a read.
    const key = try asFolderStateKey(folderKey);
    const state = try loadAppState(allocator, io);
    return switch (key) {
        .lastFolder => state.lastFolder,
        .lastDownloadFolder => state.lastDownloadFolder,
    };
}

//
// The mutator of updateFolderPath (the arrow function in TypeScript).
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
pub fn updateFolderPath(allocator: std.mem.Allocator, io: std.Io, folderKey: []const u8, folderPath: []const u8) !void {
    const key = try asFolderStateKey(folderKey);
    const mutator: UpdateFolderPathMutator = .{
        .key = key,
        .folderPath = folderPath,
    };
    try updateAppState(allocator, io, &mutator);
}

//
// The mutator of updateLastFolder (the arrow function in TypeScript).
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
pub fn updateLastFolder(allocator: std.mem.Allocator, io: std.Io, folderPath: []const u8) !void {
    const mutator: UpdateLastFolderMutator = .{
        .folderPath = folderPath,
    };
    try updateAppState(allocator, io, &mutator);
}

//
// The mutator of updateLastDownloadFolder (the arrow function in TypeScript).
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
pub fn updateLastDownloadFolder(allocator: std.mem.Allocator, io: std.Io, folderPath: []const u8) !void {
    const mutator: UpdateLastDownloadFolderMutator = .{
        .folderPath = folderPath,
    };
    try updateAppState(allocator, io, &mutator);
}

//
// Gets the recent searches list.
//
pub fn getRecentSearches(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const state = try loadAppState(allocator, io);
    return state.recentSearches orelse &.{};
}

//
// The mutator of addRecentSearch (the arrow function in TypeScript).
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
pub fn addRecentSearch(allocator: std.mem.Allocator, io: std.Io, searchText: []const u8) !void {
    const mutator: AddRecentSearchMutator = .{
        .searchText = searchText,
    };
    try updateAppState(allocator, io, &mutator);
}

//
// The mutator of removeRecentSearch (the arrow function in TypeScript).
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
pub fn removeRecentSearch(allocator: std.mem.Allocator, io: std.Io, searchText: []const u8) !void {
    const mutator: RemoveRecentSearchMutator = .{
        .searchText = searchText,
    };
    try updateAppState(allocator, io, &mutator);
}

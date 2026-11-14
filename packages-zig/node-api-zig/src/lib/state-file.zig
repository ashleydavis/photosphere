const std = @import("std");
const node_utils = @import("node-utils-zig");
const state_format = @import("state-format.zig");
const fs = node_utils.fs;
const ziggy = @import("ziggy");
const ILog = @import("utils-zig").log.ILog;
const IStateFile = state_format.IStateFile;

//
// One setting of one state file, as a struct so that the path and the key path cannot be swapped.
//
pub const IStateSettingTarget = struct {
    // The state file's path.
    statePath: []const u8,
    // The dotted key path of the setting.
    keyPath: []const u8,
};

//
// Reads one setting through the typed API. A value of the wrong type is logged, and the setting is given its default; every other
// error is returned.
//
pub fn readStateSetting(comptime T: type, arena: std.mem.Allocator, io: std.Io, log: ILog, target: IStateSettingTarget) !T {
    comptime {
        if (@typeInfo(T) != .optional) {
            @compileError("readStateSetting reads an optional type, so a bad setting can be told apart from an absent one.");
        }
    }
    return ziggy.config_state.state.get(T, arena, io, target.statePath, target.keyPath) catch |err| switch (err) {
        error.SettingWrongType => {
            log.@"error"(ziggy.utils.errors.lastErrorMessage());
            log.@"error"("The setting is at its default.");
            return null;
        },
        else => return err,
    };
}

//
// Reading and writing state.json where there is a filesystem: the CLI and the desktop app.
//
// The sibling of config-file.zig, and it works the same way. The mobile apps read and write the same
// document through worker tasks instead, because a mobile's WebView has no
// filesystem of its own. Both go through state-format.zig, so the file means the same thing whichever
// wrote it.
//
// Unlike config.toml this file is not documented for users. Nothing in it was chosen by anyone: it is
// what the app remembered so the interface comes back the way it was left.
//

//
// Loads the state from disk, returning the defaults when there is no file yet. Every leaf is read on its own, so a missing or partial
// file gives every field its default and one wrong value gives only its own field its default.
//
pub fn loadStateFile(allocator: std.mem.Allocator, io: std.Io, log: ILog, state_path: []const u8) !IStateFile {
    const row_height = try readStateSetting(?f64, allocator, io, log, .{ .statePath = state_path, .keyPath = "gallery.row_height" });
    return .{
        .desktop = .{
            .lastFolder = try readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "desktop.last_folder" }),
            .lastDownloadFolder = try readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "desktop.last_download_folder" }),
            .devToolsOpen = try readStateSetting(?bool, allocator, io, log, .{ .statePath = state_path, .keyPath = "desktop.dev_tools_open" }),
        },
        .searches = .{
            .recentSearches = try readStateSetting(?[]const []const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "searches.recent" }),
        },
        .gallery = .{
            .sort = try readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "gallery.sort" }),
            .rowHeight = if (row_height) |height| .{ .float = height } else null,
        },
        .news = .{
            .shownNewsIds = (try readStateSetting(?[]const []const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "news.shown_news_ids" })) orelse &.{},
            .lastShownUpdateVersion = try readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "news.last_shown_update_version" }),
            .feed = try state_format.newsFeedFromStored(allocator, try readStateSetting(?[]const state_format.IStoredNewsFeedItem, allocator, io, log, .{ .statePath = state_path, .keyPath = "news.feed" })),
        },
        .databases = .{
            .recentNames = (try readStateSetting(?[]const []const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "databases.recent_names" })) orelse &.{},
            .lastOpenedPath = try readStateSetting(?[]const u8, allocator, io, log, .{ .statePath = state_path, .keyPath = "databases.last_opened_path" }),
        },
    };
}

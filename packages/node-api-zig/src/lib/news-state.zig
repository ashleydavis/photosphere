const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const yaml = @import("yaml.zig");
const process_env = node_utils.process_env;

//
// Per-install state for the notification system. Stored as YAML at
// $PHOTOSPHERE_CONFIG_DIR/news.yaml (defaults to ~/.config/photosphere/news.yaml)
// and shared between the desktop app and the CLI on the same machine, so a news
// item or update version surfaced on one surface is suppressed on the other.
//
pub const INewsState = struct {
    //
    // Stable ids of news items that have already been shown to the user.
    //
    shownNewsIds: []const []const u8,

    //
    // Latest update version (e.g. "1.2.3") that the user has already been
    // notified about. When the GitHub-reported latest version equals this
    // value, the update notification is suppressed; when it differs the user
    // sees the notification again and this field is overwritten.
    //
    lastShownUpdateVersion: ?[]const u8 = null,
};

// Not ported: IYamlNewsState (the YAML is a std.json.Value here).

//
// The config directory (TypeScript: the module constant CONFIG_DIR, read when the module loads; Zig reads the
// environment on each call).
//
fn CONFIG_DIR(allocator: std.mem.Allocator) ![]const u8 {
    if (process_env.getEnv("PHOTOSPHERE_CONFIG_DIR")) |configDir| {
        if (configDir.len > 0) {
            return configDir;
        }
    }
    return std.fs.path.join(allocator, &.{ process_env.getEnv(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "", ".config", "photosphere" });
}

//
// The state file (TypeScript: the module constant STATE_FILE).
//
fn STATE_FILE(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ try CONFIG_DIR(allocator), "news.yaml" });
}

// Not ported: getNewsStatePath (not reached by psi replicate or psi verify)

//
// Loads the news state from disk. Returns an empty state when the file is missing,
// empty, or malformed. The user must never be blocked by news-state failures.
//
pub fn loadNewsState(allocator: std.mem.Allocator, io: std.Io) !INewsState {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, try STATE_FILE(allocator), allocator, .unlimited) catch {
        return .{ .shownNewsIds = &.{} };
    };

    const parsed = yaml.load(allocator, raw) catch {
        return .{ .shownNewsIds = &.{} };
    };

    const object = switch (parsed) {
        .object => |object| object,
        else => return .{ .shownNewsIds = &.{} },
    };

    var shownNewsIds: std.ArrayList([]const u8) = .empty;
    if (object.get("shown_news_ids")) |ids| {
        if (ids == .array) {
            for (ids.array.items) |id| {
                // (Zig keeps the string ids; other values cannot be news ids.)
                if (id == .string) {
                    try shownNewsIds.append(allocator, id.string);
                }
            }
        }
    }
    var state: INewsState = .{ .shownNewsIds = shownNewsIds.items };
    if (object.get("last_shown_update_version")) |version| {
        if (version == .string and version.string.len > 0) {
            state.lastShownUpdateVersion = version.string;
        }
    }
    return state;
}

//
// Saves the news state to disk, creating the config directory if needed.
//
pub fn saveNewsState(allocator: std.mem.Allocator, io: std.Io, state: INewsState) !void {
    var yamlShape: std.json.ObjectMap = .empty;
    var ids = std.json.Array.init(allocator);
    for (state.shownNewsIds) |id| {
        try ids.append(.{ .string = id });
    }
    try yamlShape.put(allocator, "shown_news_ids", .{ .array = ids });
    if (state.lastShownUpdateVersion) |version| {
        try yamlShape.put(allocator, "last_shown_update_version", .{ .string = version });
    }
    try std.Io.Dir.cwd().createDirPath(io, try CONFIG_DIR(allocator));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try STATE_FILE(allocator), .data = try yaml.dump(allocator, .{ .object = yamlShape }) });
}

//
// Returns the list of news item ids that have already been shown on this install.
//
pub fn getShownNewsIds(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const state = try loadNewsState(allocator, io);
    return state.shownNewsIds;
}

//
// Appends the given news item ids to the persisted set, deduping the union of
// existing + new ids while preserving the order in which ids were first seen.
//
pub fn addShownNewsIds(allocator: std.mem.Allocator, io: std.Io, ids: []const []const u8) !void {
    if (ids.len == 0) {
        return;
    }
    var state = try loadNewsState(allocator, io);
    const existing = state.shownNewsIds;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (existing) |id| {
        try seen.put(allocator, id, {});
    }
    var merged: std.ArrayList([]const u8) = .empty;
    try merged.appendSlice(allocator, existing);
    for (ids) |id| {
        if (!seen.contains(id)) {
            try seen.put(allocator, id, {});
            try merged.append(allocator, id);
        }
    }
    state.shownNewsIds = merged.items;
    try saveNewsState(allocator, io, state);
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
// Records the given update version as having been shown to the user. Subsequent
// checkForUpdates() calls that return the same version will suppress their
// notification; a newer GitHub release will re-trigger the notification and
// overwrite this field.
//
pub fn setLastShownUpdateVersion(allocator: std.mem.Allocator, io: std.Io, version: []const u8) !void {
    var state = try loadNewsState(allocator, io);
    state.lastShownUpdateVersion = version;
    try saveNewsState(allocator, io, state);
}

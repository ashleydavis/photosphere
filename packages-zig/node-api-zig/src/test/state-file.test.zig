const std = @import("std");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const state_file = node_api.state_file;

//
// Points PHOTOSPHERE_STATE_DIR at a new directory and returns the state file's path.
//
fn freshStatePath(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const state_dir = try std.fs.path.join(allocator, &.{ dir, "state" });
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "state.json" });
}

//
// Writes the state file.
//
fn writeState(io: std.Io, state_path: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, state_path, text);
}

test "loadStateFile returns the defaults when the state file does not exist" {
    const log = MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "state-file-missing");

    const state = try state_file.loadStateFile(allocator, std.testing.io, log, state_path);
    try std.testing.expect(state.desktop.lastFolder == null);
    try std.testing.expect(state.desktop.devToolsOpen == null);
    try std.testing.expect(state.searches.recentSearches == null);
    try std.testing.expect(state.gallery.sort == null);
    try std.testing.expect(state.gallery.rowHeight == null);
    try std.testing.expectEqual(@as(usize, 0), state.news.shownNewsIds.len);
    try std.testing.expectEqual(@as(usize, 0), state.news.feed.len);
    try std.testing.expectEqual(@as(usize, 0), state.databases.recentNames.len);
    try std.testing.expect(state.databases.lastOpenedPath == null);
}

test "loadStateFile reads every key of state.json" {
    const log = MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "state-file-sections");
    try writeState(std.testing.io, state_path,
        \\{
        \\  "desktop": { "last_folder": "/home/me/photos", "dev_tools_open": true },
        \\  "searches": { "recent": ["beach", "dogs"] },
        \\  "gallery": { "sort": "date", "row_height": 220 },
        \\  "news": { "shown_news_ids": ["a"], "last_shown_update_version": "1.2.3", "feed": [{ "id": "a", "message": "hello", "color": "primary", "duration": 4000 }] },
        \\  "databases": { "recent_names": ["one"], "last_opened_path": "/db" }
        \\}
    );

    const state = try state_file.loadStateFile(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqualStrings("/home/me/photos", state.desktop.lastFolder.?);
    try std.testing.expect(state.desktop.devToolsOpen.?);
    try std.testing.expect(state.desktop.lastDownloadFolder == null);
    try std.testing.expectEqualStrings("beach", state.searches.recentSearches.?[0]);
    try std.testing.expectEqualStrings("date", state.gallery.sort.?);
    try std.testing.expectEqual(@as(f64, 220), state.gallery.rowHeight.?.float);
    try std.testing.expectEqual(@as(usize, 1), state.news.shownNewsIds.len);
    try std.testing.expectEqualStrings("1.2.3", state.news.lastShownUpdateVersion.?);
    try std.testing.expectEqualStrings("hello", state.news.feed[0].message);
    try std.testing.expectEqual(@as(usize, 1), state.databases.recentNames.len);
    try std.testing.expectEqualStrings("/db", state.databases.lastOpenedPath.?);
}

test "a partial state file gives every absent key its default" {
    const log = MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "state-file-partial");
    try writeState(std.testing.io, state_path, "{\"desktop\":{\"last_folder\":\"/p\"}}");

    const state = try state_file.loadStateFile(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqualStrings("/p", state.desktop.lastFolder.?);
    try std.testing.expect(state.desktop.devToolsOpen == null);
    try std.testing.expectEqual(@as(usize, 0), state.news.feed.len);
    try std.testing.expectEqual(@as(usize, 0), state.databases.recentNames.len);
}

test "one wrong-typed key gives only its own field its default, and the log names it" {
    const log = MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "state-file-wrong-type");
    try writeState(std.testing.io, state_path, "{\"gallery\":{\"sort\":\"date\",\"row_height\":\"tall\"}}");

    const state = try state_file.loadStateFile(allocator, std.testing.io, log, state_path);
    try std.testing.expect(state.gallery.rowHeight == null);
    try std.testing.expectEqualStrings("date", state.gallery.sort.?);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "row_height") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "a string") != null);
}

test "unreadable state text gives every field its default rather than throwing" {
    const log = MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "state-file-unreadable");
    try writeState(std.testing.io, state_path, "not json");

    const state = try state_file.loadStateFile(allocator, std.testing.io, log, state_path);
    try std.testing.expect(state.desktop.lastFolder == null);
    try std.testing.expectEqual(@as(usize, 0), state.news.shownNewsIds.len);
}

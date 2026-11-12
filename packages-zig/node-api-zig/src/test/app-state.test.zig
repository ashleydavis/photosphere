const std = @import("std");
const utils = @import("utils-zig");
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const app_state = node_api.app_state;

//
// A fresh directory of the test's own, and the state file's path under it.
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

//
// Reads the state file's text.
//
fn readState(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, state_path);
}

//
// Fails unless the state file's key path holds the string.
//
fn expectString(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, key_path: []const u8, expected: []const u8) !void {
    const text = try readState(allocator, io, state_path);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    var current = parsed;
    var keys = std.mem.splitScalar(u8, key_path, '.');
    while (keys.next()) |key| {
        current = current.object.get(key) orelse return error.KeyMissing;
    }
    try std.testing.expectEqualStrings(expected, current.string);
}

test "loadAppState returns an empty state when no file exists and writes nothing" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-missing");

    const state = try app_state.loadAppState(allocator, std.testing.io, log, state_path);
    try std.testing.expect(state.lastFolder == null);
    try std.testing.expect(state.recentSearches == null);
    try std.testing.expect(!test_files.fileExists(std.testing.io, state_path));
}

test "loadAppState reads every key of state.json" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-load");
    try writeState(std.testing.io, state_path,
        \\{"desktop":{"last_folder":"/folder","last_download_folder":"/downloads","dev_tools_open":true},
        \\ "searches":{"recent":["cats"]},
        \\ "gallery":{"sort":"name","row_height":240}}
    );

    const state = try app_state.loadAppState(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqualStrings("/folder", state.lastFolder.?);
    try std.testing.expectEqualStrings("/downloads", state.lastDownloadFolder.?);
    try std.testing.expect(state.devToolsOpen.?);
    try std.testing.expectEqualStrings("cats", state.recentSearches.?[0]);
    try std.testing.expectEqualStrings("name", state.gallerySort.?);
    try std.testing.expectEqual(@as(f64, 240), state.galleryRowHeight.?.float);
}

test "one wrong-typed key gives only its own field its default and the log names it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-wrong-type");
    try writeState(std.testing.io, state_path, "{\"gallery\":{\"sort\":\"name\",\"row_height\":\"tall\"}}");

    const state = try app_state.loadAppState(allocator, std.testing.io, log, state_path);
    try std.testing.expect(state.galleryRowHeight == null);
    try std.testing.expectEqualStrings("name", state.gallerySort.?);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "row_height") != null);
}

test "unreadable state text gives every field its default" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-unreadable");
    try writeState(std.testing.io, state_path, "not json");

    const state = try app_state.loadAppState(allocator, std.testing.io, log, state_path);
    try std.testing.expect(state.lastFolder == null);
    try std.testing.expect(state.recentSearches == null);
}

test "updateLastFolder and updateLastDownloadFolder write their keys and create the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-folders");

    try app_state.updateLastFolder(allocator, std.testing.io, state_path, "/new/folder");
    try app_state.updateLastDownloadFolder(allocator, std.testing.io, state_path, "/downloads");
    try expectString(allocator, std.testing.io, state_path, "desktop.last_folder", "/new/folder");
    try expectString(allocator, std.testing.io, state_path, "desktop.last_download_folder", "/downloads");
}

test "updateFolderPath writes the chosen folder under the key and leaves everything else alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-folder-keeps");
    try writeState(std.testing.io, state_path, "{\"gallery\":{\"sort\":\"name\"},\"news\":{\"shown_news_ids\":[\"release-1\"]}}");

    try app_state.updateFolderPath(allocator, std.testing.io, state_path, "lastFolder", "/new/photos");
    try expectString(allocator, std.testing.io, state_path, "desktop.last_folder", "/new/photos");
    try expectString(allocator, std.testing.io, state_path, "gallery.sort", "name");
    const text = try readState(allocator, std.testing.io, state_path);
    try std.testing.expect(std.mem.indexOf(u8, text, "release-1") != null);
}

test "getFolderPath reads the folder remembered under the given key, or null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-folder-read");

    try std.testing.expect((try app_state.getFolderPath(allocator, std.testing.io, state_path, "lastFolder")) == null);
    try writeState(std.testing.io, state_path, "{\"desktop\":{\"last_folder\":\"/photos\",\"last_download_folder\":\"/downloads\"}}");
    try std.testing.expectEqualStrings("/photos", (try app_state.getFolderPath(allocator, std.testing.io, state_path, "lastFolder")).?);
    try std.testing.expectEqualStrings("/downloads", (try app_state.getFolderPath(allocator, std.testing.io, state_path, "lastDownloadFolder")).?);
    try std.testing.expectError(error.Thrown, app_state.getFolderPath(allocator, std.testing.io, state_path, "nonsense"));
}

test "recent searches start empty, dedupe and move a repeated search to the front, cap at the limit and remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "app-state-searches");

    try std.testing.expectEqual(@as(usize, 0), (try app_state.getRecentSearches(allocator, std.testing.io, state_path)).len);
    try app_state.addRecentSearch(allocator, std.testing.io, state_path, "cats");
    try app_state.addRecentSearch(allocator, std.testing.io, state_path, "dogs");
    try app_state.addRecentSearch(allocator, std.testing.io, state_path, "cats");
    var searches = try app_state.getRecentSearches(allocator, std.testing.io, state_path);
    try std.testing.expectEqual(@as(usize, 2), searches.len);
    try std.testing.expectEqualStrings("cats", searches[0]);
    try std.testing.expectEqualStrings("dogs", searches[1]);

    var number: usize = 0;
    while (number < app_state.MAX_RECENT_SEARCHES + 3) : (number += 1) {
        const search = try std.fmt.allocPrint(allocator, "search{d}", .{number});
        try app_state.addRecentSearch(allocator, std.testing.io, state_path, search);
    }
    searches = try app_state.getRecentSearches(allocator, std.testing.io, state_path);
    try std.testing.expectEqual(@as(usize, app_state.MAX_RECENT_SEARCHES), searches.len);
    const newest = try std.fmt.allocPrint(allocator, "search{d}", .{app_state.MAX_RECENT_SEARCHES + 2});
    try std.testing.expectEqualStrings(newest, searches[0]);

    try app_state.removeRecentSearch(allocator, std.testing.io, state_path, newest);
    searches = try app_state.getRecentSearches(allocator, std.testing.io, state_path);
    for (searches) |search| {
        try std.testing.expect(!std.mem.eql(u8, search, newest));
    }
}

test "asFolderStateKey returns each accepted key and names them in the error for another" {
    for (app_state.FOLDER_STATE_KEYS) |folderKey| {
        try std.testing.expectEqual(folderKey, try app_state.asFolderStateKey(@tagName(folderKey)));
    }
    try std.testing.expectError(error.Thrown, app_state.asFolderStateKey("nonsense"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "lastFolder") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "lastDownloadFolder") != null);
}

//
// A thread that adds its own searches, with an allocator and an Io of its own.
//
fn addSearchesThread(state_path: []const u8, prefix: []const u8, failure: *?anyerror) void {
    var thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var number: usize = 0;
    while (number < 5) : (number += 1) {
        const search = std.fmt.allocPrint(arena, "{s} {d}", .{ prefix, number }) catch @panic("out of memory building a search");
        app_state.addRecentSearch(arena, io, state_path, search) catch |err| {
            failure.* = err;
            return;
        };
    }
}

test "twenty rounds of two threads adding searches at once keep all ten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try temp_dirs.makeTempDir(allocator, std.testing.io, "app-state-searches-atomic");
    defer temp_dirs.removeTempDir(std.testing.io, root);
    const state_dir = try std.fs.path.join(allocator, &.{ root, "state" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, state_dir);

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        const state_path = try std.fmt.allocPrint(allocator, "{s}/state-{d}.json", .{ state_dir, round });
        var first_error: ?anyerror = null;
        var second_error: ?anyerror = null;
        const first = try std.Thread.spawn(.{}, addSearchesThread, .{ state_path, "first", &first_error });
        const second = try std.Thread.spawn(.{}, addSearchesThread, .{ state_path, "second", &second_error });
        first.join();
        second.join();
        try std.testing.expect(first_error == null);
        try std.testing.expect(second_error == null);
        const searches = try app_state.getRecentSearches(allocator, std.testing.io, state_path);
        try std.testing.expectEqual(@as(usize, 10), searches.len);
    }
}

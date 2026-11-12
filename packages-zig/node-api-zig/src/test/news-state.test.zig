const std = @import("std");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const news_state = node_api.news_state;

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

//
// The news state the state file holds, as JSON.
//
fn stateJson(allocator: std.mem.Allocator, state: news_state.INewsState) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, state, .{ .emit_null_optional_fields = false });
}

test "news lives in the state file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state_path = try freshStatePath(arena.allocator(), std.testing.io, "news-path");
    try std.testing.expect(std.mem.endsWith(u8, state_path, "state.json"));
}

test "returns empty state when the file does not exist" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-missing");
    const state = try news_state.loadNewsState(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "returns empty state when the file has no news keys" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-no-section");
    try writeState(std.testing.io, state_path, "{\"desktop\":{\"dev_tools_open\":true}}");
    const state = try news_state.loadNewsState(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "reads the shown ids, the version and the feed from the state file and drops an item that cannot be shown" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-read");
    try writeState(std.testing.io, state_path,
        \\{"news":{"shown_news_ids":["a","b"],"last_shown_update_version":"1.2.3",
        \\ "feed":[{"id":"f1","message":"Hello","color":"primary","duration":5000},{"message":"no id"},{"id":"f2","message":"bad colour","color":"neon"}]}}
    );

    const state = try news_state.loadNewsState(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqual(@as(usize, 2), state.shownNewsIds.len);
    try std.testing.expectEqualStrings("1.2.3", state.lastShownUpdateVersion.?);
    try std.testing.expectEqual(@as(usize, 2), state.feed.len);
    try std.testing.expectEqualStrings("f1", state.feed[0].id);
    try std.testing.expect(state.feed[1].color == null);
}

test "saving the news state writes its three keys and keeps every other key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-save");
    try writeState(std.testing.io, state_path, "{\"desktop\":{\"dev_tools_open\":true}}");

    try news_state.saveNewsState(allocator, std.testing.io, state_path, .{
        .shownNewsIds = &.{ "a", "b" },
        .lastShownUpdateVersion = "1.2.3",
        .feed = &.{.{ .id = "a", .message = "hello" }},
    });

    const text = try test_files.readFile(allocator, std.testing.io, state_path);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"shown_news_ids\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"last_shown_update_version\": \"1.2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"dev_tools_open\": true") != null);
}

test "adding shown ids dedupes and keeps the order they were first seen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-add");
    try news_state.addShownNewsIds(allocator, std.testing.io, state_path, &.{"a"});
    try news_state.addShownNewsIds(allocator, std.testing.io, state_path, &.{ "b", "c", "a" });
    const log = MuteLog.init();
    const state = try news_state.loadNewsState(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqual(@as(usize, 3), state.shownNewsIds.len);
    try std.testing.expectEqualStrings("a", state.shownNewsIds[0]);
    try std.testing.expectEqualStrings("b", state.shownNewsIds[1]);
    try std.testing.expectEqualStrings("c", state.shownNewsIds[2]);
}

test "getting and setting the last shown update version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const log = MuteLog.init();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-version");
    try std.testing.expect(try news_state.getLastShownUpdateVersion(allocator, std.testing.io, log, state_path) == null);
    try news_state.setLastShownUpdateVersion(allocator, std.testing.io, state_path, "1.2.3");
    try std.testing.expectEqualStrings("1.2.3", (try news_state.getLastShownUpdateVersion(allocator, std.testing.io, log, state_path)).?);
}

test "getShownNewsIds returns the list, or an empty one when there is no file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const log = MuteLog.init();
    const state_path = try freshStatePath(allocator, std.testing.io, "news-ids");
    try std.testing.expectEqual(@as(usize, 0), (try news_state.getShownNewsIds(allocator, std.testing.io, log, state_path)).len);
    try news_state.addShownNewsIds(allocator, std.testing.io, state_path, &.{ "x", "y" });
    const ids = try news_state.getShownNewsIds(allocator, std.testing.io, log, state_path);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
}

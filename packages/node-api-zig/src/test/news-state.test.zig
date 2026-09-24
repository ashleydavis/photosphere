const std = @import("std");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const news_state = node_api.news_state;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn freshConfigDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    _ = try helpers.setupEnvironment(io);
    const dir = try helpers.makeTempDir(allocator, io, name);
    const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{dir});
    try helpers.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    return configDir;
}

//
// Writes the state file.
//
fn writeState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, configDir);
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/news.yaml", .{configDir}), text);
}

//
// Reads the state file.
//
fn readState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/news.yaml", .{configDir}));
}

test "returns empty state when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try freshConfigDir(allocator, io, "news-missing");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqual(@as(usize, 0), state.shownNewsIds.len);
    try std.testing.expect(state.lastShownUpdateVersion == null);
}

test "returns empty state on YAML parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-malformed");
    try writeState(allocator, io, configDir, "shown_news_ids: [unclosed");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqual(@as(usize, 0), state.shownNewsIds.len);
}

test "parses shown_news_ids from YAML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-ids");
    try writeState(allocator, io, configDir, "shown_news_ids:\n  - a\n  - b\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), state.shownNewsIds.len);
    try std.testing.expectEqualStrings("b", state.shownNewsIds[1]);
}

test "parses last_shown_update_version from YAML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-version");
    try writeState(allocator, io, configDir, "shown_news_ids: []\nlast_shown_update_version: 1.2.3\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("1.2.3", state.lastShownUpdateVersion.?);
}

test "omits last_shown_update_version when empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-empty-version");
    try writeState(allocator, io, configDir, "shown_news_ids: []\nlast_shown_update_version: ''\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expect(state.lastShownUpdateVersion == null);
}

test "writes shown_news_ids in snake_case yaml form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-write");
    try news_state.saveNewsState(allocator, io, .{ .shownNewsIds = &.{ "a", "b" } });
    try std.testing.expectEqualStrings("shown_news_ids:\n  - a\n  - b\n", try readState(allocator, io, configDir));
}

test "writes last_shown_update_version when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-write-version");
    try news_state.saveNewsState(allocator, io, .{ .shownNewsIds = &.{}, .lastShownUpdateVersion = "1.2.3" });
    try std.testing.expectEqualStrings("shown_news_ids: []\nlast_shown_update_version: 1.2.3\n", try readState(allocator, io, configDir));
}

test "creates the config directory before writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-mkdir");
    try std.testing.expect(!helpers.fileExists(io, configDir));
    try news_state.saveNewsState(allocator, io, .{ .shownNewsIds = &.{"x"} });
    try std.testing.expect(helpers.fileExists(io, configDir));
}

test "is a no-op for empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-noop");
    try news_state.addShownNewsIds(allocator, io, &.{});
    try std.testing.expect(!helpers.fileExists(io, configDir));
}

test "appends new ids to the existing list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-append");
    try writeState(allocator, io, configDir, "shown_news_ids:\n  - a\n");
    try news_state.addShownNewsIds(allocator, io, &.{ "b", "c" });
    try std.testing.expectEqualStrings("shown_news_ids:\n  - a\n  - b\n  - c\n", try readState(allocator, io, configDir));
}

test "dedupes ids preserving first-seen order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-dedupe");
    try writeState(allocator, io, configDir, "shown_news_ids:\n  - a\n  - b\n");
    try news_state.addShownNewsIds(allocator, io, &.{ "b", "c", "a", "c" });
    try std.testing.expectEqualStrings("shown_news_ids:\n  - a\n  - b\n  - c\n", try readState(allocator, io, configDir));
}

test "preserves last_shown_update_version when only news ids are added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-preserve");
    try writeState(allocator, io, configDir, "shown_news_ids: []\nlast_shown_update_version: 2.0.0\n");
    try news_state.addShownNewsIds(allocator, io, &.{"x"});
    try std.testing.expectEqualStrings("shown_news_ids:\n  - x\nlast_shown_update_version: 2.0.0\n", try readState(allocator, io, configDir));
}

test "getLastShownUpdateVersion returns undefined when unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try freshConfigDir(arena.allocator(), std.testing.io, "news-get-unset");
    try std.testing.expect(try news_state.getLastShownUpdateVersion(arena.allocator(), std.testing.io) == null);
}

test "getLastShownUpdateVersion returns the stored version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-get");
    try writeState(allocator, io, configDir, "shown_news_ids: []\nlast_shown_update_version: 3.1.4\n");
    try std.testing.expectEqualStrings("3.1.4", (try news_state.getLastShownUpdateVersion(allocator, io)).?);
}

test "setLastShownUpdateVersion overwrites the previous value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-set");
    try writeState(allocator, io, configDir, "shown_news_ids: []\nlast_shown_update_version: 1.0.0\n");
    try news_state.setLastShownUpdateVersion(allocator, io, "2.0.0");
    try std.testing.expectEqualStrings("2.0.0", (try news_state.getLastShownUpdateVersion(allocator, io)).?);
}

test "setLastShownUpdateVersion preserves existing shown news ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-set-preserve");
    try writeState(allocator, io, configDir, "shown_news_ids:\n  - a\n");
    try news_state.setLastShownUpdateVersion(allocator, io, "2.0.0");
    try std.testing.expectEqualStrings("shown_news_ids:\n  - a\nlast_shown_update_version: 2.0.0\n", try readState(allocator, io, configDir));
}

test "returns the stored list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-list");
    try writeState(allocator, io, configDir, "shown_news_ids:\n  - one\n  - two\n");
    const ids = try news_state.getShownNewsIds(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("one", ids[0]);
}

test "returns [] when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try freshConfigDir(arena.allocator(), std.testing.io, "news-list-missing");
    try std.testing.expectEqual(@as(usize, 0), (try news_state.getShownNewsIds(arena.allocator(), std.testing.io)).len);
}

test "TypeScript and Zig read and write the same state file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-interop");
    const overrides = [_][2][]const u8{.{ "PHOTOSPHERE_CONFIG_DIR", configDir }};
    _ = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{ "add", "ts-1", "ts-2" }, &overrides);
    const tsFile = try readState(allocator, io, configDir);
    try news_state.addShownNewsIds(allocator, io, &.{"zig-1"});
    try news_state.setLastShownUpdateVersion(allocator, io, "9.9.9");
    const loaded = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{"load"}, &overrides);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[\"ts-1\",\"ts-2\",\"zig-1\"],\"lastShownUpdateVersion\":\"9.9.9\"}", try std.json.Stringify.valueAlloc(allocator, loaded, .{}));
    try std.testing.expectEqualStrings("shown_news_ids:\n  - ts-1\n  - ts-2\n", tsFile);
}

const std = @import("std");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const news_state = node_api.news_state;
const state_file = node_api.state_file;

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
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/state.yaml", .{configDir}), text);
}

//
// Reads the state file.
//
fn readState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/state.yaml", .{configDir}));
}

//
// The news state as JSON (what the TypeScript tests compare with toEqual).
//
fn stateJson(allocator: std.mem.Allocator, state: news_state.INewsState) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, state, .{ .emit_null_optional_fields = false });
}

test "is the state file, not a news.yaml of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-path");
    const statePath = try state_file.getStatePath(allocator);
    try std.testing.expect(std.mem.endsWith(u8, statePath, "state.yaml"));
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ configDir, "state.yaml" }), statePath);
}

test "returns empty state when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try freshConfigDir(allocator, io, "news-missing");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "returns empty state when the state file has no news section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-no-section");
    try writeState(allocator, io, configDir, "theme: dark\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "returns empty state when the news section is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-malformed-section");
    try writeState(allocator, io, configDir, "news: not a section\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqual(@as(usize, 0), state.shownNewsIds.len);
}

test "parses shown_news_ids from the news section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-ids");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids:\n    - a\n    - b\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[\"a\",\"b\"],\"feed\":[]}", try stateJson(allocator, state));
    try std.testing.expect(state.lastShownUpdateVersion == null);
}

test "parses last_shown_update_version from the news section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-version");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids: []\n  last_shown_update_version: 1.2.3\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("1.2.3", state.lastShownUpdateVersion.?);
}

test "omits last_shown_update_version when empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-version-empty");
    try writeState(allocator, io, configDir, "news:\n  last_shown_update_version: ''\n");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expect(state.lastShownUpdateVersion == null);
}

test "returns empty state when the state file cannot be read at all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-unreadable");

    // Not YAML at all, so reading it throws.
    try writeState(allocator, io, configDir, "news: [unclosed");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "writes shown_news_ids in snake_case under the news section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-save");
    try news_state.saveNewsState(allocator, io, .{ .shownNewsIds = &.{ "a", "b" }, .feed = &.{} });
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n    - b\n", try readState(allocator, io, configDir));
}

test "writes last_shown_update_version when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-save-version");
    try news_state.saveNewsState(allocator, io, .{ .shownNewsIds = &.{}, .lastShownUpdateVersion = "1.2.3", .feed = &.{} });
    try std.testing.expectEqualStrings("news:\n  last_shown_update_version: 1.2.3\n", try readState(allocator, io, configDir));
}

test "leaves every other section of the state file alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-other-sections");
    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /home/someone/photos\nsearches:\n  recent:\n    - beach\ngallery:\n  sort: name\n  row_height: 240\nui:\n  sidebar-collapsed-databases: true\n");
    try news_state.saveNewsState(allocator, io, .{ .shownNewsIds = &.{"a"}, .feed = &.{} });
    try std.testing.expectEqualStrings(
        "desktop:\n  last_folder: /home/someone/photos\nsearches:\n  recent:\n    - beach\ngallery:\n  sort: name\n  row_height: 240\nnews:\n  shown_news_ids:\n    - a\nui:\n  sidebar-collapsed-databases: true\n",
        try readState(allocator, io, configDir),
    );
}

test "is a no-op for empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-add-empty");
    try news_state.addShownNewsIds(allocator, io, &.{});
    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/state.yaml", .{configDir})));
}

test "appends new ids to the existing list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-add");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids:\n    - a\n");
    try news_state.addShownNewsIds(allocator, io, &.{ "b", "c" });
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n    - b\n    - c\n", try readState(allocator, io, configDir));
}

test "dedupes ids preserving first-seen order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-dedupe");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids:\n    - a\n    - b\n");
    try news_state.addShownNewsIds(allocator, io, &.{ "b", "c", "a" });
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n    - b\n    - c\n", try readState(allocator, io, configDir));
}

test "preserves last_shown_update_version when only news ids are added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-add-keeps-version");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids: []\n  last_shown_update_version: 1.2.3\n");
    try news_state.addShownNewsIds(allocator, io, &.{"a"});
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n  last_shown_update_version: 1.2.3\n", try readState(allocator, io, configDir));
}

test "getLastShownUpdateVersion returns undefined when unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-get-version-unset");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids: []\n");
    try std.testing.expect(try news_state.getLastShownUpdateVersion(allocator, io) == null);
}

test "getLastShownUpdateVersion returns the stored version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-get-version");
    try writeState(allocator, io, configDir, "news:\n  last_shown_update_version: 1.2.3\n");
    try std.testing.expectEqualStrings("1.2.3", (try news_state.getLastShownUpdateVersion(allocator, io)).?);
}

test "setLastShownUpdateVersion overwrites the previous value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-set-version");
    try writeState(allocator, io, configDir, "news:\n  last_shown_update_version: 1.2.2\n");
    try news_state.setLastShownUpdateVersion(allocator, io, "1.2.3");
    try std.testing.expectEqualStrings("news:\n  last_shown_update_version: 1.2.3\n", try readState(allocator, io, configDir));
}

test "setLastShownUpdateVersion preserves existing shown news ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-set-version-keeps-ids");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids:\n    - a\n    - b\n");
    try news_state.setLastShownUpdateVersion(allocator, io, "1.2.3");
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n    - b\n  last_shown_update_version: 1.2.3\n", try readState(allocator, io, configDir));
}

test "returns the stored list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-get-ids");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids:\n    - a\n    - b\n");
    const result = try news_state.getShownNewsIds(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b", result[1]);
}

test "returns [] when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try freshConfigDir(allocator, io, "news-get-ids-missing");
    try std.testing.expectEqual(@as(usize, 0), (try news_state.getShownNewsIds(allocator, io)).len);
}

test "TypeScript and Zig read and write the same state file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-interop");
    const overrides = [_][2][]const u8{.{ "PHOTOSPHERE_CONFIG_DIR", configDir }};

    // A state file the desktop app wrote, with every section, then news from TypeScript and from Zig.
    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /home/someone/My Photos\n  dev_tools_open: false\nsearches:\n  recent:\n    - 'yes'\n    - beach\ngallery:\n  sort: date\n  row_height: 180.5\nnews:\n  feed:\n    - id: f1\n      message: 'Hello: world'\n      color: primary\n      duration: 5000\n    - id: f2\n      message: bad colour\n      color: purple\nui:\n  '1': one\n  sidebar-collapsed: true\n  widths:\n    - '10'\n    - wide\n  bad:\n    nested: map\n");
    _ = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{ "add", "ts-1", "ts-2" }, &overrides);
    const tsFile = try readState(allocator, io, configDir);
    try news_state.addShownNewsIds(allocator, io, &.{"zig-1"});
    try news_state.setLastShownUpdateVersion(allocator, io, "9.9.9");
    const zigFile = try readState(allocator, io, configDir);

    // Zig writes what TypeScript writes: TypeScript making the same two changes to its own file gives the
    // same bytes.
    _ = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{ "add", "zig-1" }, &overrides);
    try writeState(allocator, io, configDir, tsFile);
    _ = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{ "add", "zig-1" }, &overrides);
    _ = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{ "set-version", "9.9.9" }, &overrides);
    try std.testing.expectEqualStrings(try readState(allocator, io, configDir), zigFile);

    const loaded = try helpers.runBunJson(allocator, io, "news-state-ts.ts", &.{"load"}, &overrides);
    const zigLoaded = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[\"ts-1\",\"ts-2\",\"zig-1\"],\"lastShownUpdateVersion\":\"9.9.9\",\"feed\":[{\"id\":\"f1\",\"message\":\"Hello: world\",\"color\":\"primary\",\"duration\":5000},{\"id\":\"f2\",\"message\":\"bad colour\"}]}", try stateJson(allocator, zigLoaded));
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[\"ts-1\",\"ts-2\",\"zig-1\"],\"feed\":[{\"id\":\"f1\",\"message\":\"Hello: world\",\"color\":\"primary\",\"duration\":5000},{\"id\":\"f2\",\"message\":\"bad colour\"}],\"lastShownUpdateVersion\":\"9.9.9\"}", try std.json.Stringify.valueAlloc(allocator, loaded, .{}));
}

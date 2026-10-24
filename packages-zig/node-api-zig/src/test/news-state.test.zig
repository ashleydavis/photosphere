const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const news_state = node_api.news_state;
const state_file = node_api.state_file;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn freshConfigDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const configDir = try std.fs.path.join(allocator, &.{ dir, "config" });
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    return configDir;
}

//
// Writes the state file.
//
fn writeState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, configDir);
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ configDir, "state.yaml" }), text);
}

//
// Reads the state file.
//
fn readState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, try std.fs.path.join(allocator, &.{ configDir, "state.yaml" }));
}

//
// The news state as JSON.
//
fn stateJson(allocator: std.mem.Allocator, state: news_state.INewsState) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, state, .{
        .emit_null_optional_fields = false,
    });
}

test "is the state file, not a news.yaml of its own" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-path");
    const statePath = try state_file.getStatePath(allocator);
    try std.testing.expect(std.mem.endsWith(u8, statePath, "state.yaml"));
    try std.testing.expectEqualStrings(try node_utils.path.join(allocator, &.{ configDir, "state.yaml" }), statePath);
}

test "returns empty state when the file does not exist" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try freshConfigDir(allocator, io, "news-missing");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "returns empty state when the state file has no news section" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-unreadable");
    // Loading logs that the state could not be read; a passing test must write nothing to stderr, so the log is muted.
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();

    // Not YAML at all, so reading it throws.
    try writeState(allocator, io, configDir, "news: [unclosed");
    const state = try news_state.loadNewsState(allocator, io);
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[],\"feed\":[]}", try stateJson(allocator, state));
}

test "writes shown_news_ids in snake_case under the news section" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-save");
    try news_state.saveNewsState(allocator, io, .{
        .shownNewsIds = &.{ "a", "b" },
        .feed = &.{},
    });
    try std.testing.expectEqualStrings("news:\n  shown_news_ids:\n    - a\n    - b\n", try readState(allocator, io, configDir));
}

test "writes last_shown_update_version when set" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-save-version");
    try news_state.saveNewsState(allocator, io, .{
        .shownNewsIds = &.{},
        .lastShownUpdateVersion = "1.2.3",
        .feed = &.{},
    });
    try std.testing.expectEqualStrings("news:\n  last_shown_update_version: 1.2.3\n", try readState(allocator, io, configDir));
}

test "leaves every other section of the state file alone" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-other-sections");
    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /home/someone/photos\nsearches:\n  recent:\n    - beach\ngallery:\n  sort: name\n  row_height: 240\nui:\n  sidebar-collapsed-databases: true\n");
    try news_state.saveNewsState(allocator, io, .{
        .shownNewsIds = &.{"a"},
        .feed = &.{},
    });
    try std.testing.expectEqualStrings(
        "desktop:\n  last_folder: /home/someone/photos\nsearches:\n  recent:\n    - beach\ngallery:\n  sort: name\n  row_height: 240\nnews:\n  shown_news_ids:\n    - a\nui:\n  sidebar-collapsed-databases: true\n",
        try readState(allocator, io, configDir),
    );
}

test "is a no-op for empty input" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-add-empty");
    try news_state.addShownNewsIds(allocator, io, &.{});
    try std.testing.expect(!test_files.fileExists(io, try std.fs.path.join(allocator, &.{ configDir, "state.yaml" })));
}

test "appends new ids to the existing list" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-get-version-unset");
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids: []\n");
    try std.testing.expect(try news_state.getLastShownUpdateVersion(allocator, io) == null);
}

test "getLastShownUpdateVersion returns the stored version" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-get-version");
    try writeState(allocator, io, configDir, "news:\n  last_shown_update_version: 1.2.3\n");
    try std.testing.expectEqualStrings("1.2.3", (try news_state.getLastShownUpdateVersion(allocator, io)).?);
}

test "setLastShownUpdateVersion overwrites the previous value" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try freshConfigDir(allocator, io, "news-get-ids-missing");
    try std.testing.expectEqual(@as(usize, 0), (try news_state.getShownNewsIds(allocator, io)).len);
}

test "news changes keep every other section of a state file the desktop app wrote" {
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "news-every-section");

    // A state file with every section, including values the reader drops (a feed item with a colour nobody
    // defined, a ui value that is not a boolean, number, string or list of strings).
    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /home/someone/My Photos\n  dev_tools_open: false\nsearches:\n  recent:\n    - 'yes'\n    - beach\ngallery:\n  sort: date\n  row_height: 180.5\nnews:\n  feed:\n    - id: f1\n      message: 'Hello: world'\n      color: primary\n      duration: 5000\n    - id: f2\n      message: bad colour\n      color: purple\nui:\n  '1': one\n  sidebar-collapsed: true\n  widths:\n    - '10'\n    - wide\n  bad:\n    nested: map\n");
    try news_state.addShownNewsIds(allocator, io, &.{ "first-1", "first-2" });
    try news_state.addShownNewsIds(allocator, io, &.{ "second-1", "first-1" });
    try news_state.setLastShownUpdateVersion(allocator, io, "9.9.9");

    // What the desktop app writes after the same three calls: the file is read and written back whole, so the
    // sections come out in a fixed order, the news section gains shown_news_ids and
    // last_shown_update_version ahead of feed, the dropped values are gone, and the YAML writer quotes the strings that
    // would read back as something else ('yes', 'Hello: world', '1', '10').
    try std.testing.expectEqualStrings(
        "desktop:\n  last_folder: /home/someone/My Photos\n  dev_tools_open: false\nsearches:\n  recent:\n    - 'yes'\n    - beach\ngallery:\n  sort: date\n  row_height: 180.5\nnews:\n  shown_news_ids:\n    - first-1\n    - first-2\n    - second-1\n  last_shown_update_version: 9.9.9\n  feed:\n    - id: f1\n      message: 'Hello: world'\n      color: primary\n      duration: 5000\n    - id: f2\n      message: bad colour\nui:\n  '1': one\n  sidebar-collapsed: true\n  widths:\n    - '10'\n    - wide\n",
        try readState(allocator, io, configDir),
    );

    // And what loadNewsState reads back from it.
    try std.testing.expectEqualStrings("{\"shownNewsIds\":[\"first-1\",\"first-2\",\"second-1\"],\"lastShownUpdateVersion\":\"9.9.9\",\"feed\":[{\"id\":\"f1\",\"message\":\"Hello: world\",\"color\":\"primary\",\"duration\":5000},{\"id\":\"f2\",\"message\":\"bad colour\"}]}", try stateJson(allocator, try news_state.loadNewsState(allocator, io)));
}

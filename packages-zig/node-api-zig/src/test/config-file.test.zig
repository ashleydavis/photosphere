const std = @import("std");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const config_file = node_api.config_file;
const config_format = node_api.config_format;

//
// Points PHOTOSPHERE_CONFIG_DIR and PHOTOSPHERE_STATE_DIR at fresh directories and returns the config file's path.
//
fn freshConfigPath(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const config_dir = try std.fs.path.join(allocator, &.{ dir, "config" });
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", config_dir);
    try test_environment.setEnv("PHOTOSPHERE_STATE_DIR", try std.fs.path.join(allocator, &.{ dir, "state" }));
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
}

//
// Writes the config file.
//
fn writeConfig(io: std.Io, config_path: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, config_path, text);
}

//
// Reads the config file's text.
//
fn readConfig(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, config_path);
}

test "loadConfigFile returns the defaults when the config file does not exist" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const config_path = try freshConfigPath(allocator, io, "config-file-missing");

    const config = try config_file.loadConfigFile(allocator, io, log, config_path);

    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expect(!config.sync.settings.enabled);
    try std.testing.expect(config.sync.settings.onlyOnWifi);
    try std.testing.expect(config.theme == null);
    try std.testing.expect(!test_files.fileExists(io, config_path));
}

test "loadConfigFile returns the defaults for an empty config file" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "config-file-empty");
    try writeConfig(std.testing.io, config_path, "");

    const config = try config_file.loadConfigFile(allocator, std.testing.io, log, config_path);
    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expect(config.theme == null);
}

test "loadConfigFile reads every key of config.toml" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "config-file-sections");
    try writeConfig(std.testing.io, config_path,
        \\theme = "dark"
        \\saved_searches = ["beach"]
        \\
        \\[auto_import]
        \\enabled = true
        \\default_database_path = "/photos"
        \\pause_between_runs_ms = 5000
        \\cleanup_enabled = true
        \\
        \\[[auto_import.sources]]
        \\type = "folder"
        \\path = "/home/me/Pictures"
        \\recurse = false
        \\
        \\[sync]
        \\enabled = true
        \\only_on_wifi = false
        \\database_path = "/db"
        \\pause_between_runs_ms = 300000
    );

    const config = try config_file.loadConfigFile(allocator, std.testing.io, log, config_path);
    try std.testing.expectEqual(config_format.IConfigTheme.dark, config.theme.?);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expect(config.autoImport.settings.enabled);
    try std.testing.expectEqualStrings("/photos", config.autoImport.defaultDatabasePath.?);
    try std.testing.expectEqual(@as(i64, 5000), config.autoImport.pauseBetweenRunsMs.integer);
    try std.testing.expect(config.autoImportCleanupEnabled.?);
    try std.testing.expectEqualStrings("/home/me/Pictures", config.autoImport.settings.sources[0].folder.path);
    try std.testing.expect(!config.autoImport.settings.sources[0].folder.recurse);
    try std.testing.expect(config.sync.settings.enabled);
    try std.testing.expect(!config.sync.settings.onlyOnWifi);
    try std.testing.expectEqualStrings("/db", config.sync.databasePath.?);
    try std.testing.expectEqual(@as(i64, 300000), config.sync.pauseBetweenRunsMs.integer);
}

test "one wrong-typed key gives only its own setting its default, and the log names it" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "config-file-wrong-type");
    try writeConfig(std.testing.io, config_path,
        \\developer_mode = "yes"
        \\theme = "dark"
    );

    const config = try config_file.loadConfigFile(allocator, std.testing.io, log, config_path);
    try std.testing.expect(config.developerMode == null);
    try std.testing.expectEqual(config_format.IConfigTheme.dark, config.theme.?);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "developer_mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "a string") != null);
}

test "a config file with a bad line gives every setting its default and is left alone" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "config-file-bad-line");
    const bad = "theme = \"dark\"\noops = = 1\n";
    try writeConfig(std.testing.io, config_path, bad);

    const config = try config_file.loadConfigFile(allocator, std.testing.io, log, config_path);
    try std.testing.expect(config.theme == null);
    try std.testing.expectEqualStrings(bad, try readConfig(allocator, std.testing.io, config_path));
}

test "saveConfigFile round-trips the theme" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "config-file-save-theme");

    var config = try config_file.defaultConfigFile(allocator);
    config.theme = .light;
    config.sync.settings.enabled = true;
    config.sync.databasePath = "/db";
    try config_file.saveConfigFile(allocator, std.testing.io, config_path, config);

    const text = try readConfig(allocator, std.testing.io, config_path);
    try std.testing.expect(std.mem.indexOf(u8, text, "theme = \"light\"") != null);
    // A whole pause is written as an integer, not a float.
    try std.testing.expect(std.mem.indexOf(u8, text, "pause_between_runs_ms = 300000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "300000.0") == null);

    const loaded = try config_file.loadConfigFile(allocator, std.testing.io, log, config_path);
    try std.testing.expectEqual(config_format.IConfigTheme.light, loaded.theme.?);
    try std.testing.expect(loaded.sync.settings.enabled);
    try std.testing.expectEqualStrings("/db", loaded.sync.databasePath.?);
}

test "defaultConfigFile has syncing and automatic import switched off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try config_file.defaultConfigFile(arena.allocator());
    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expect(!config.sync.settings.enabled);
}

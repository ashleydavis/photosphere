const std = @import("std");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const api = @import("api-zig");
const app_config = node_api.app_config;
const config_format = node_api.config_format;
const app_config_format = node_api.app_config_format;
const IAppConfig = app_config.IAppConfig;
const IConfigTheme = node_api.config_format.IConfigTheme;
const config_state = @import("ziggy").config_state;

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
fn writeConfig(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, text: []const u8) !void {
    _ = allocator;
    try test_files.writeFile(io, config_path, text);
}

//
// Reads the config file's text.
//
fn readConfig(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, config_path);
}

//
// The sample value of one IAppConfig field, for the round-trip test.
//
fn sampleValue(comptime field_name: []const u8) @FieldType(IAppConfig, field_name) {
    const T = @FieldType(IAppConfig, field_name);
    if (T == ?IConfigTheme) {
        return .light;
    }
    if (T == ?bool) {
        return true;
    }
    if (T == ?[]const u8) {
        return "sample value";
    }
    if (T == ?[]const []const u8) {
        return &.{ "one", "two" };
    }
    if (T == ?[]const api.auto_import_settings.IAutoImportSource) {
        return &.{.{ .folder = .{ .path = "/pictures", .recurse = true } }};
    }
    @compileError("app-config.test has no sample for " ++ @typeName(T));
}

test "loadAppConfig returns an empty config when no file exists, and writes nothing" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-missing");

    const config = try app_config.loadAppConfig(allocator, std.testing.io, log, config_path);
    try std.testing.expectEqual(@as(usize, 0), (try app_config.appConfigSettings(allocator, config)).count());
    try std.testing.expect(!test_files.fileExists(std.testing.io, config_path));
}

test "loadAppConfig reads every setting from config.toml" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-load");
    try writeConfig(allocator, std.testing.io, config_path,
        \\theme = "dark"
        \\developer_mode = true
        \\show_fps_indicator = true
        \\saved_searches = ["beach", "dogs"]
        \\
        \\[sync]
        \\enabled = false
        \\only_on_wifi = false
        \\
        \\[auto_import]
        \\enabled = true
        \\default_database_path = "/db"
        \\cleanup_enabled = true
        \\sources = [{ type = "folder", path = "/pictures", recurse = true }]
    );

    const config = try app_config.loadAppConfig(allocator, std.testing.io, log, config_path);
    try std.testing.expectEqual(IConfigTheme.dark, config.theme.?);
    try std.testing.expect(config.developerMode.?);
    try std.testing.expect(config.showFpsIndicator.?);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expect(!config.syncEnabled.?);
    try std.testing.expect(!config.syncOnlyOnWifi.?);
    try std.testing.expect(config.autoImportEnabled.?);
    try std.testing.expectEqualStrings("/db", config.defaultDatabasePath.?);
    try std.testing.expect(config.autoImportCleanupEnabled.?);
    try std.testing.expectEqualStrings("/pictures", config.autoImportSources.?[0].folder.path);
}

test "loadAppConfig gives one wrong-typed key its default and reads every other key" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-wrong-type");
    try writeConfig(allocator, std.testing.io, config_path,
        \\developer_mode = "yes"
        \\theme = "dark"
    );

    const config = try app_config.loadAppConfig(allocator, std.testing.io, log, config_path);
    try std.testing.expect(config.developerMode == null);
    try std.testing.expectEqual(IConfigTheme.dark, config.theme.?);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "developer_mode") != null);
}

test "APP_CONFIG_PATHS has one entry per field of IAppConfig" {
    inline for (std.meta.fields(IAppConfig)) |field| {
        _ = @field(app_config.APP_CONFIG_PATHS, field.name);
    }
}

test "setAppConfig writes every field, config.get reads each key path back and getAppConfig reads the value back" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-round-trip");

    inline for (std.meta.fields(IAppConfig)) |field| {
        const sample = sampleValue(field.name);
        try app_config.setAppConfig(field.name, allocator, std.testing.io, config_path, sample);
        if (comptime std.mem.eql(u8, field.name, "autoImportSources")) {
            _ = try config_state.config.get(?[]const config_format.IStoredAutoImportSource, allocator, std.testing.io, config_path, @field(app_config.APP_CONFIG_PATHS, field.name));
        }
        else {
            _ = try config_state.config.get(field.type, allocator, std.testing.io, config_path, @field(app_config.APP_CONFIG_PATHS, field.name));
        }
        _ = try app_config.getAppConfig(field.name, allocator, std.testing.io, config_path);
    }
}

test "automatic import sources with a folder and a device album round-trip and are written as array-of-table headers" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-sources");

    const sources = [_]api.auto_import_settings.IAutoImportSource{
        .{ .folder = .{ .path = "/home/someone/Pictures", .recurse = true } },
        .{ .@"device-album" = .{ .albumId = "all" } },
    };
    try app_config.setAppConfig("autoImportSources", allocator, std.testing.io, config_path, &sources);

    const text = try readConfig(allocator, std.testing.io, config_path);
    try std.testing.expect(std.mem.indexOf(u8, text, "[[auto_import.sources]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type = \"folder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "album_id = \"all\"") != null);
    const loaded = (try app_config.getAppConfig("autoImportSources", allocator, std.testing.io, config_path)).?;
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("/home/someone/Pictures", loaded[0].folder.path);
    try std.testing.expectEqualStrings("all", loaded[1].@"device-album".albumId);
}

test "setAppConfigIn writes two fields inside one update" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-in-update");

    const Change = struct {
        pub fn run(_: *const @This(), change_arena: std.mem.Allocator, values: config_state.config.Values) !void {
            _ = change_arena;
            try app_config.setAppConfigIn("developerMode", values, true);
            try app_config.setAppConfigIn("autoImportCleanupEnabled", values, true);
        }
    };
    try config_state.config.update(allocator, std.testing.io, config_path, Change{});

    const config = try app_config.loadAppConfig(allocator, std.testing.io, log, config_path);
    try std.testing.expect(config.developerMode.?);
    try std.testing.expect(config.autoImportCleanupEnabled.?);
}

test "getTheme returns system when the theme is unset, missing or names nobody, and the stored value otherwise" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-theme");

    try std.testing.expectEqual(IConfigTheme.system, try app_config.getTheme(allocator, std.testing.io, log, config_path));
    try writeConfig(allocator, std.testing.io, config_path, "");
    try std.testing.expectEqual(IConfigTheme.system, try app_config.getTheme(allocator, std.testing.io, log, config_path));
    try writeConfig(allocator, std.testing.io, config_path, "theme = \"neon\"\n");
    try std.testing.expectEqual(IConfigTheme.system, try app_config.getTheme(allocator, std.testing.io, log, config_path));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "theme") != null);
    try writeConfig(allocator, std.testing.io, config_path, "theme = \"dark\"\n");
    try std.testing.expectEqual(IConfigTheme.dark, try app_config.getTheme(allocator, std.testing.io, log, config_path));
}

test "setTheme writes the theme" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-set-theme");

    try app_config.setTheme(allocator, std.testing.io, config_path, .light);
    try std.testing.expectEqual(IConfigTheme.light, try app_config.getTheme(allocator, std.testing.io, log, config_path));
}

test "loadAppConfig leaves a sync setting absent from the file null, so the UI applies its own default" {
    const log = utils.mute_log.MuteLog.init();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit(log);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config_path = try freshConfigPath(allocator, std.testing.io, "app-config-sync-absent");
    try writeConfig(allocator, std.testing.io, config_path, "theme = \"dark\"\n");

    const config = try app_config.loadAppConfig(allocator, std.testing.io, log, config_path);
    try std.testing.expect(config.syncEnabled == null);
    try std.testing.expect(config.syncOnlyOnWifi == null);
}


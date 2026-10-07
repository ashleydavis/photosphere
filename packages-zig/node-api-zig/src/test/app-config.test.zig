const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const app_config = node_api.app_config;
const IAppConfig = app_config.IAppConfig;
const IConfigTheme = node_api.config_format.IConfigTheme;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn freshConfigDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{dir});
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    return configDir;
}

//
// Writes the config file in the config directory.
//
fn writeConfig(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{configDir}), text);
}

//
// Reads the config file in the config directory.
//
fn readConfig(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{configDir}));
}

//
// Reads the config file and parses it as the YAML document the TypeScript tests inspect (what writeYaml was handed).
//
fn readDocument(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) !std.json.Value {
    return node_utils.yaml.load(allocator, try readConfig(allocator, io, configDir));
}

//
// Turns a value into JSON text, for comparing documents (TypeScript: `toEqual`).
//
fn toJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

//
// A mutator that runs a function over the config it is handed (TypeScript: the arrow function the test passes).
//
const FunctionMutator = struct {
    // The function that changes the config.
    change: *const fn (config: *IAppConfig) void,

    //
    // Changes the config.
    //
    pub fn run(self: FunctionMutator, allocator: std.mem.Allocator, config: *IAppConfig) !void {
        _ = allocator;
        self.change(config);
    }
};

//
// Sets the theme to light.
//
fn setThemeLight(config: *IAppConfig) void {
    config.theme = .light;
}

//
// Sets the theme to dark.
//
fn setThemeDark(config: *IAppConfig) void {
    config.theme = .dark;
}

//
// Switches developer mode on.
//
fn setDeveloperMode(config: *IAppConfig) void {
    config.developerMode = true;
}

//
// Sets the FPS indicator, the saved searches and the default database.
//
fn setSeveralFields(config: *IAppConfig) void {
    config.showFpsIndicator = true;
    config.savedSearches = &.{"beach"};
    config.defaultDatabasePath = "/db";
}

//
// Sets the saved searches.
//
fn setSavedSearches(config: *IAppConfig) void {
    config.savedSearches = &.{"beach"};
}

//
// Sets the sync settings.
//
fn setSyncSettings(config: *IAppConfig) void {
    config.syncEnabled = true;
    config.syncOnlyOnWifi = false;
}

//
// Sets every automatic import setting.
//
fn setAutoImportSettings(config: *IAppConfig) void {
    config.autoImportEnabled = true;
    config.defaultDatabasePath = "/home/someone/photosphere-default";
    config.autoImportSources = &.{.{
        .folder = .{
            .path = "/home/someone/Pictures",
            .recurse = true,
        },
    }};
    config.autoImportCleanupEnabled = true;
}

test "loadAppConfig returns an empty config when no file exists, and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-missing");
    defer temp_dirs.removeTempDir(io, configDir);
    try std.Io.Dir.cwd().createDirPath(io, configDir);

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), (try app_config.appConfigSettings(allocator, config)).count());
    try std.testing.expect(!test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{configDir})));
}

test "loadAppConfig returns the config from the document when the file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-load");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: dark\nshow_fps_indicator: true\n");

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expectEqual(IConfigTheme.dark, config.theme.?);
    try std.testing.expect(config.showFpsIndicator.?);
}

test "loadAppConfig converts snake_case document keys to camelCase fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-snake");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir,
        \\show_fps_indicator: true
        \\saved_searches:
        \\  - beach
        \\auto_import:
        \\  default_database_path: /db
        \\
    );

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expect(config.showFpsIndicator.?);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expectEqualStrings("/db", config.defaultDatabasePath.?);
}

test "loadAppConfig throws when the config file is not YAML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-corrupt");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "sync:\n  enabled: true\n   bad indentation: [");

    try std.testing.expectError(error.Thrown, app_config.loadAppConfig(allocator, io));
}

test "updateAppConfig writes the theme at the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-write-theme");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setThemeLight,
    });

    try std.testing.expectEqualStrings("theme: light\n", try readConfig(allocator, io, configDir));
}

test "updateAppConfig converts camelCase fields to snake_case keys in their own sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-write-snake");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setSeveralFields,
    });

    try std.testing.expectEqualStrings(
        \\show_fps_indicator: true
        \\saved_searches:
        \\  - beach
        \\auto_import:
        \\  default_database_path: /db
        \\
    , try readConfig(allocator, io, configDir));
}

test "the automatic import settings are written with snake_case keys under auto_import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-write-auto-import");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setAutoImportSettings,
    });

    try std.testing.expectEqualStrings(
        \\auto_import:
        \\  enabled: true
        \\  default_database_path: /home/someone/photosphere-default
        \\  cleanup_enabled: true
        \\  sources:
        \\    - type: folder
        \\      path: /home/someone/Pictures
        \\      recurse: true
        \\
    , try readConfig(allocator, io, configDir));
    const loaded = try app_config.loadAppConfig(allocator, io);
    try std.testing.expect(loaded.autoImportEnabled.?);
    try std.testing.expectEqualStrings("/home/someone/Pictures", loaded.autoImportSources.?[0].folder.path);
}

test "getTheme returns system when the theme is unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-theme-unset");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "{}\n");

    try std.testing.expectEqual(IConfigTheme.system, try app_config.getTheme(allocator, io));
}

test "getTheme returns system when there is no file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-theme-nofile");
    defer temp_dirs.removeTempDir(io, configDir);
    try std.Io.Dir.cwd().createDirPath(io, configDir);

    try std.testing.expectEqual(IConfigTheme.system, try app_config.getTheme(allocator, io));
}

test "getTheme returns the stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-theme-stored");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: dark\n");

    try std.testing.expectEqual(IConfigTheme.dark, try app_config.getTheme(allocator, io));
}

test "getTheme returns system when the file names a theme nobody defined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-theme-neon");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: neon\n");

    try std.testing.expectEqual(IConfigTheme.system, try app_config.getTheme(allocator, io));
}

test "setTheme sets the theme and saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-set-theme");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "{}\n");

    try app_config.setTheme(allocator, io, .light);

    const document = try readDocument(allocator, io, configDir);
    try std.testing.expectEqualStrings("light", document.object.get("theme").?.string);
    try std.testing.expectEqual(IConfigTheme.light, try app_config.getTheme(allocator, io));
}

test "loadAppConfig reads show_fps_indicator from the top level and updateAppConfig writes showFpsIndicator to it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-fps");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "show_fps_indicator: true\n");
    try std.testing.expect((try app_config.loadAppConfig(allocator, io)).showFpsIndicator.?);

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setThemeDark,
    });

    const document = try readDocument(allocator, io, configDir);
    try std.testing.expect(document.object.get("show_fps_indicator").?.bool);
    try std.testing.expectEqualStrings("dark", document.object.get("theme").?.string);
}

// Saved searches are the searches the user deliberately kept, so they are a setting and belong here. The ones merely run
// are in the state file instead.
test "loadAppConfig reads saved_searches from the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-saved-searches");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "saved_searches:\n  - beach\n  - dogs\n");

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 2), config.savedSearches.?.len);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expectEqualStrings("dogs", config.savedSearches.?[1]);
}

test "loadAppConfig reads enabled and only_on_wifi from the sync section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-sync-read");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "sync:\n  enabled: false\n  only_on_wifi: false\n");

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expectEqual(false, config.syncEnabled.?);
    try std.testing.expectEqual(false, config.syncOnlyOnWifi.?);
}

test "updateAppConfig writes sync settings into the sync section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-sync-write");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setSyncSettings,
    });

    try std.testing.expectEqualStrings("sync:\n  enabled: true\n  only_on_wifi: false\n", try readConfig(allocator, io, configDir));
}

// The interface applies its own defaults (syncing on, Wi-Fi only) to a setting nobody has touched, so an absent value has
// to arrive as nothing. Handing back the file reader's defaults instead would silently switch syncing off on a fresh
// install.
test "loadAppConfig leaves sync settings unset when the file has no sync section so the UI applies defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-sync-absent");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: dark\n");

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expect(config.syncEnabled == null);
    try std.testing.expect(config.syncOnlyOnWifi == null);
}

test "developerMode is read from developer_mode, written to it and round-trips through save and load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-developer-mode");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "developer_mode: true\n");
    try std.testing.expect((try app_config.loadAppConfig(allocator, io)).developerMode.?);
    try writeConfig(allocator, io, configDir, "{}\n");

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setDeveloperMode,
    });

    try std.testing.expectEqualStrings("developer_mode: true\n", try readConfig(allocator, io, configDir));
    try std.testing.expect((try app_config.loadAppConfig(allocator, io)).developerMode.?);
}

test "updateAppConfig reads the current config, applies the mutation, and writes it back nested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-update");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: dark\n");

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setDeveloperMode,
    });

    // The pre-existing value survives and the mutation is applied.
    try std.testing.expectEqualStrings("theme: dark\ndeveloper_mode: true\n", try readConfig(allocator, io, configDir));
}

// The flat view owns only some of the file. The mobile loops' pacing and the database the mobile sync pushes are in the
// same document and appear nowhere in this view, so a desktop write that rebuilt the document from the flat view alone
// would delete them.
test "updateAppConfig leaves the parts of the file this view does not own exactly as they were" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-keeps-unowned");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir,
        \\auto_import:
        \\  enabled: true
        \\  pause_between_runs_ms: 5000
        \\  sources:
        \\    - type: device-album
        \\      album_id: all
        \\sync:
        \\  enabled: true
        \\  database_path: photosphere-default
        \\  pause_between_runs_ms: 300000
        \\
    );

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setThemeDark,
    });

    const document = (try readDocument(allocator, io, configDir)).object;
    try std.testing.expectEqualStrings("dark", document.get("theme").?.string);
    try std.testing.expectEqual(@as(i64, 5000), document.get("auto_import").?.object.get("pause_between_runs_ms").?.integer);
    try std.testing.expectEqualStrings(
        "[{\"type\":\"device-album\",\"album_id\":\"all\"}]",
        try toJson(allocator, document.get("auto_import").?.object.get("sources").?),
    );
    try std.testing.expectEqualStrings("photosphere-default", document.get("sync").?.object.get("database_path").?.string);
    try std.testing.expectEqual(@as(i64, 300000), document.get("sync").?.object.get("pause_between_runs_ms").?.integer);
}

//
// A mutator that stands for another process writing the file while this edit is in progress: the first time it runs it
// writes `otherText` into the file, as the other process would, and then makes its own change.
//
const InterferingMutator = struct {
    // The directory of the config file.
    configDir: []const u8,

    // What the other process writes.
    otherText: []const u8,

    // The io the other process writes with.
    io: std.Io,

    // How many times the mutator has run.
    runs: u32 = 0,

    // The allocator the other process builds its path with.
    pathAllocator: std.mem.Allocator,

    //
    // Writes the other process's change on the first run, then changes the theme.
    //
    pub fn run(self: *InterferingMutator, allocator: std.mem.Allocator, config: *IAppConfig) !void {
        _ = allocator;
        self.runs += 1;
        if (self.runs == 1) {
            try writeConfig(self.pathAllocator, self.io, self.configDir, self.otherText);
        }
        config.theme = .dark;
    }
};

// The point of routing every edit through updateAppConfig: a key set by someone else between this edit's read and its
// write is still there afterwards. The load-then-save this replaced wrote back a whole config read earlier, so it
// discarded anything changed in the meantime.
test "updateAppConfig keeps a key written by someone else while this edit was being made" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-concurrent");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "{}\n");
    var mutator: InterferingMutator = .{
        .configDir = configDir,
        .otherText = "auto_import:\n  default_database_path: /set-by-another-process\n",
        .io = io,
        .pathAllocator = allocator,
    };

    try app_config.updateAppConfig(allocator, io, &mutator);

    try std.testing.expectEqual(@as(u32, 2), mutator.runs);
    const document = (try readDocument(allocator, io, configDir)).object;
    try std.testing.expectEqualStrings("dark", document.get("theme").?.string);
    try std.testing.expectEqualStrings("/set-by-another-process", document.get("auto_import").?.object.get("default_database_path").?.string);
}

// A mutator that throws is left to throw, and the file is left as it was.
test "updateAppConfig leaves the file as it was when the mutator throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-update-throws");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "theme: dark\n");

    try std.testing.expectError(error.Thrown, app_config.updateAppConfig(allocator, io, ThrowingMutator{}));

    try std.testing.expectEqualStrings("theme: dark\n", try readConfig(allocator, io, configDir));
    try std.testing.expectEqualStrings("\"nothing\" is not a config setting.", utils.errors.lastErrorMessage());
}

//
// A mutator that sets a key that is not a config setting, which throws.
//
const ThrowingMutator = struct {
    //
    // Tries to set a setting that does not exist.
    //
    pub fn run(self: ThrowingMutator, allocator: std.mem.Allocator, config: *IAppConfig) !void {
        _ = self;
        _ = allocator;
        try app_config.setAppConfigValue(config, "nothing", .{
            .boolean = true,
        });
    }
};

test "the names app-config.ts re-exports from app-config-format.ts are available from it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var config: IAppConfig = .{};

    try app_config.setAppConfigValue(&config, "developerMode", .{
        .boolean = true,
    });

    try std.testing.expect(app_config.getAppConfigValue(config, "developerMode").?.boolean);
    try std.testing.expectEqual(@as(usize, 1), (try app_config.appConfigSettings(allocator, config)).count());
    try std.testing.expect(@TypeOf(app_config.yamlToAppConfig) == @TypeOf(node_api.app_config_format.yamlToAppConfig));
    try std.testing.expect(@TypeOf(app_config.appConfigToYaml) == @TypeOf(node_api.app_config_format.appConfigToYaml));
}

test "the automatic import settings are absent from a config that does not mention them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try node_api.app_config_format.yamlToAppConfig(allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"theme\":\"dark\"}", .{}));

    try std.testing.expect(config.autoImportEnabled == null);
    try std.testing.expect(config.defaultDatabasePath == null);
    try std.testing.expect(config.autoImportSources == null);
    try std.testing.expect(config.autoImportCleanupEnabled == null);
}

test "updateAppConfig writes savedSearches to saved_searches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-write-saved-searches");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_config.updateAppConfig(allocator, io, FunctionMutator{
        .change = setSavedSearches,
    });

    const document = (try readDocument(allocator, io, configDir)).object;
    try std.testing.expectEqualStrings("[\"beach\"]", try toJson(allocator, document.get("saved_searches").?));
}

test "loadAppConfig leaves sync settings undefined when absent so the UI applies defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-config-sync-absent-empty");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeConfig(allocator, io, configDir, "{}\n");

    const config = try app_config.loadAppConfig(allocator, io);

    try std.testing.expect(config.syncEnabled == null);
    try std.testing.expect(config.syncOnlyOnWifi == null);
}

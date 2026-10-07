const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const config_format = node_api.config_format;
const IConfigFile = config_format.IConfigFile;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const DEFAULT_AUTO_IMPORT_PAUSE_MS = api.auto_import_mobile.DEFAULT_AUTO_IMPORT_PAUSE_MS;
const DEFAULT_SYNC_PAUSE_MS = api.sync_settings.DEFAULT_SYNC_PAUSE_MS;

//
// Parses a JSON literal (TypeScript: the object literal the test passes).
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Turns a value into JSON text, for comparing documents (TypeScript: `toEqual`; here the order of the keys counts too).
//
fn toJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

//
// Asserts that two lists of sources are equal (TypeScript: `toEqual`).
//
fn expectSources(expected: []const IAutoImportSource, actual: []const IAutoImportSource) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedSource, actualSource| {
        try std.testing.expectEqualStrings(expectedSource.sourceType(), actualSource.sourceType());
        switch (expectedSource) {
            .folder => |folder| {
                try std.testing.expectEqualStrings(folder.path, actualSource.folder.path);
                try std.testing.expectEqual(folder.recurse, actualSource.folder.recurse);
            },
            .@"device-album" => |album| {
                try std.testing.expectEqualStrings(album.albumId, actualSource.@"device-album".albumId);
            },
        }
    }
}

//
// Asserts that two optional strings are equal.
//
fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |expectedText| {
        try std.testing.expectEqualStrings(expectedText, actual.?);
        return;
    }
    try std.testing.expect(actual == null);
}

//
// Asserts that two configurations are equal (TypeScript: `toEqual`).
//
fn expectConfigEqual(expected: IConfigFile, actual: IConfigFile) !void {
    try std.testing.expectEqual(expected.theme, actual.theme);
    try std.testing.expectEqual(expected.developerMode, actual.developerMode);
    try std.testing.expectEqual(expected.showFpsIndicator, actual.showFpsIndicator);
    if (expected.savedSearches) |expectedSearches| {
        try std.testing.expectEqual(expectedSearches.len, actual.savedSearches.?.len);
        for (expectedSearches, actual.savedSearches.?) |expectedSearch, actualSearch| {
            try std.testing.expectEqualStrings(expectedSearch, actualSearch);
        }
    }
    else {
        try std.testing.expect(actual.savedSearches == null);
    }
    try std.testing.expectEqual(expected.autoImportCleanupEnabled, actual.autoImportCleanupEnabled);

    try std.testing.expectEqual(expected.autoImport.settings.enabled, actual.autoImport.settings.enabled);
    try expectSources(expected.autoImport.settings.sources, actual.autoImport.settings.sources);
    try expectOptionalString(expected.autoImport.defaultDatabasePath, actual.autoImport.defaultDatabasePath);
    try std.testing.expectEqual(expected.autoImport.pauseBetweenRunsMs.integer, actual.autoImport.pauseBetweenRunsMs.integer);

    try std.testing.expectEqual(expected.sync.settings.enabled, actual.sync.settings.enabled);
    try std.testing.expectEqual(expected.sync.settings.onlyOnWifi, actual.sync.settings.onlyOnWifi);
    try expectOptionalString(expected.sync.databasePath, actual.sync.databasePath);
    try std.testing.expectEqual(expected.sync.pauseBetweenRunsMs.integer, actual.sync.pauseBetweenRunsMs.integer);
}

test "yamlToConfigFile: an absent document returns the defaults with syncing and automatic import switched off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, null);

    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expectEqual(@as(usize, 0), config.autoImport.settings.sources.len);
    try std.testing.expect(config.autoImport.defaultDatabasePath == null);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), config.autoImport.pauseBetweenRunsMs.integer);
    try std.testing.expect(!config.sync.settings.enabled);
    try std.testing.expect(config.sync.settings.onlyOnWifi);
    try std.testing.expect(config.sync.databasePath == null);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), config.sync.pauseBetweenRunsMs.integer);
    try std.testing.expect(config.theme == null);
    try std.testing.expect(config.developerMode == null);
    try std.testing.expect(config.showFpsIndicator == null);
    try std.testing.expect(config.savedSearches == null);
    try std.testing.expect(config.autoImportCleanupEnabled == null);
}

test "yamlToConfigFile: a document that is not an object reads as the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fromString = try config_format.yamlToConfigFile(allocator, .{
        .string = "nothing",
    });
    const fromArray = try config_format.yamlToConfigFile(allocator, try parseJson(allocator, "[1,2]"));
    const defaults = try config_format.defaultConfigFile(allocator);

    try expectConfigEqual(defaults, fromString);
    try expectConfigEqual(defaults, fromArray);
}

test "yamlToConfigFile: a document with only a sync section leaves the other sections at their defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"sync":{"enabled":true,"only_on_wifi":false,"database_path":"photosphere-default","pause_between_runs_ms":5000}}
    ));

    try std.testing.expect(config.sync.settings.enabled);
    try std.testing.expect(!config.sync.settings.onlyOnWifi);
    try std.testing.expectEqualStrings("photosphere-default", config.sync.databasePath.?);
    try std.testing.expectEqual(@as(i64, 5000), config.sync.pauseBetweenRunsMs.integer);

    try std.testing.expect(!config.autoImport.settings.enabled);
    try std.testing.expectEqual(@as(usize, 0), config.autoImport.settings.sources.len);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), config.autoImport.pauseBetweenRunsMs.integer);
}

test "yamlToConfigFile: a document with only an auto_import section leaves the other sections at their defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"auto_import":{"enabled":true,"default_database_path":"photosphere-default","pause_between_runs_ms":5000,"cleanup_enabled":true,"sources":[{"type":"device-album","album_id":"all"}]}}
    ));

    try std.testing.expect(config.autoImport.settings.enabled);
    try std.testing.expectEqualStrings("photosphere-default", config.autoImport.defaultDatabasePath.?);
    try std.testing.expectEqual(@as(i64, 5000), config.autoImport.pauseBetweenRunsMs.integer);
    try std.testing.expect(config.autoImportCleanupEnabled.?);
    try expectSources(&.{.{
        .@"device-album" = .{
            .albumId = "all",
        },
    }}, config.autoImport.settings.sources);

    try std.testing.expect(!config.sync.settings.enabled);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), config.sync.pauseBetweenRunsMs.integer);
}

test "yamlToConfigFile: unknown keys are ignored rather than throwing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"theme":"dark","something_nobody_defined":42,"sync":{"enabled":true,"a_key_from_a_later_version":"hello"}}
    ));

    try std.testing.expectEqual(config_format.IConfigTheme.dark, config.theme.?);
    try std.testing.expect(config.sync.settings.enabled);
}

test "yamlToConfigFile: a malformed section falls back to that section's defaults without discarding the sections that parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"theme":"light","sync":"not a section at all","auto_import":{"enabled":true,"default_database_path":"kept"},"saved_searches":"not a list"}
    ));

    try std.testing.expectEqual(config_format.IConfigTheme.light, config.theme.?);
    try std.testing.expect(config.autoImport.settings.enabled);
    try std.testing.expectEqualStrings("kept", config.autoImport.defaultDatabasePath.?);

    try std.testing.expect(!config.sync.settings.enabled);
    try std.testing.expect(config.sync.settings.onlyOnWifi);
    try std.testing.expect(config.savedSearches == null);
}

test "yamlToConfigFile: a saved search of the wrong type is dropped and the rest of the list kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"saved_searches":["beach",17,"dogs"]}
    ));

    try std.testing.expectEqual(@as(usize, 2), config.savedSearches.?.len);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expectEqualStrings("dogs", config.savedSearches.?[1]);
}

test "yamlToConfigFile: a theme the file invents is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invented = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"theme":"neon"}
    ));
    const notAString = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"theme":7}
    ));

    try std.testing.expect(invented.theme == null);
    try std.testing.expect(notAString.theme == null);
}

test "yamlToConfigFile: every theme the file may name is read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (config_format.ALLOWED_THEMES) |theme| {
        const document = try std.fmt.allocPrint(allocator, "{{\"theme\":\"{s}\"}}", .{@tagName(theme)});
        const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator, document));
        try std.testing.expectEqual(theme, config.theme.?);
    }
}

test "yamlToConfigFile: settings of the wrong type are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"developer_mode":"yes","show_fps_indicator":1,"auto_import":{"cleanup_enabled":"yes","sources":"not a list"}}
    ));

    try std.testing.expect(config.developerMode == null);
    try std.testing.expect(config.showFpsIndicator == null);
    try std.testing.expect(config.autoImportCleanupEnabled == null);
    try std.testing.expectEqual(@as(usize, 0), config.autoImport.settings.sources.len);
}

test "yamlToConfigFile: a malformed source is dropped and the rest are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"auto_import":{"enabled":true,"sources":[{"type":"folder","path":"/photos","recurse":false},{"type":"folder"},{"type":"device-album","album_id":"all"},"not a source"]}}
    ));

    try expectSources(&.{
        .{
            .folder = .{
                .path = "/photos",
                .recurse = false,
            },
        },
        .{
            .@"device-album" = .{
                .albumId = "all",
            },
        },
    }, config.autoImport.settings.sources);
}

// JavaScript throws reading `type` off a null source, so a file with an empty list entry stops here with that message
// instead of that entry being dropped.
test "yamlToConfigFile: a null source throws the error JavaScript throws reading it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try parseJson(allocator,
        \\{"auto_import":{"sources":[null]}}
    );

    try std.testing.expectError(error.Thrown, config_format.yamlToConfigFile(allocator, document));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading 'type')", errors.lastErrorMessage());
}

test "yamlToConfigFile: a pause of zero falls back to the default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"auto_import":{"pause_between_runs_ms":0},"sync":{"pause_between_runs_ms":-1}}
    ));

    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), config.autoImport.pauseBetweenRunsMs.integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), config.sync.pauseBetweenRunsMs.integer);
}

test "yamlToConfigFile: an empty database path reads as absent rather than as an empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.yamlToConfigFile(allocator, try parseJson(allocator,
        \\{"auto_import":{"default_database_path":""},"sync":{"database_path":""}}
    ));

    try std.testing.expect(config.autoImport.defaultDatabasePath == null);
    try std.testing.expect(config.sync.databasePath == null);
}

//
// A configuration with every field set, used by the round-trip tests.
//
fn fullConfig() IConfigFile {
    return .{
        .theme = .dark,
        .developerMode = true,
        .autoImport = .{
            .settings = .{
                .enabled = true,
                .sources = &.{
                    .{
                        .folder = .{
                            .path = "/home/user/Pictures",
                            .recurse = true,
                        },
                    },
                    .{
                        .@"device-album" = .{
                            .albumId = "all",
                        },
                    },
                },
            },
            .defaultDatabasePath = "/home/user/photos",
            .pauseBetweenRunsMs = .{
                .integer = 12345,
            },
        },
        .autoImportCleanupEnabled = true,
        .sync = .{
            .settings = .{
                .enabled = true,
                .onlyOnWifi = false,
            },
            .databasePath = "/home/user/photos",
            .pauseBetweenRunsMs = .{
                .integer = 54321,
            },
        },
        .showFpsIndicator = true,
        .savedSearches = &.{ "beach", "2024 birthday" },
    };
}

test "configFileToYaml: every field round-trips through configFileToYaml then yamlToConfigFile unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = fullConfig();

    const roundTripped = try config_format.yamlToConfigFile(allocator, try config_format.configFileToYaml(allocator, original, null));

    try expectConfigEqual(original, roundTripped);
}

test "configFileToYaml: an absent optional field stays absent rather than being written as null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = try config_format.defaultConfigFile(allocator);

    const document = (try config_format.configFileToYaml(allocator, config, null)).object;

    try std.testing.expect(document.get("theme") == null);
    try std.testing.expect(document.get("developer_mode") == null);
    try std.testing.expect(document.get("auto_import").?.object.get("default_database_path") == null);
    try std.testing.expect(document.get("auto_import").?.object.get("cleanup_enabled") == null);
    try std.testing.expect(document.get("sync").?.object.get("database_path") == null);
    try std.testing.expect(document.get("show_fps_indicator") == null);
    try std.testing.expect(document.get("saved_searches") == null);

    // The rendered document must not carry the absent keys at all.
    try std.testing.expect(std.mem.indexOf(u8, try config_format.buildConfigYaml(allocator, config, null), "null") == null);
}

test "configFileToYaml: the searches the user saved are written at the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var config = try config_format.defaultConfigFile(allocator);
    config.savedSearches = &.{ "beach", "dogs" };

    const document = try config_format.configFileToYaml(allocator, config, null);

    try std.testing.expectEqualStrings("[\"beach\",\"dogs\"]", try toJson(allocator, document.object.get("saved_searches").?));
}

// Which sections are written says which features have been set, and a reader uses that to tell "nobody has chosen
// this" from "somebody switched it off". Writing every section every time would tell a fresh install that both had
// already been decided.
test "configFileToYaml: writes only the sections it is asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = fullConfig();

    const syncOnly = (try config_format.configFileToYaml(allocator, config, .{
        .autoImport = false,
        .sync = true,
    })).object;
    try std.testing.expect(syncOnly.get("sync") != null);
    try std.testing.expect(syncOnly.get("auto_import") == null);

    const autoImportOnly = (try config_format.configFileToYaml(allocator, config, .{
        .autoImport = true,
        .sync = false,
    })).object;
    try std.testing.expect(autoImportOnly.get("auto_import") != null);
    try std.testing.expect(autoImportOnly.get("sync") == null);

    const neither = (try config_format.configFileToYaml(allocator, config, .{
        .autoImport = false,
        .sync = false,
    })).object;
    try std.testing.expect(neither.get("auto_import") == null);
    try std.testing.expect(neither.get("sync") == null);

    // The settings that belong to no feature are still written.
    try std.testing.expectEqualStrings("dark", neither.get("theme").?.string);
}

test "configFileToYaml: writes both sections when it is not told which to write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = (try config_format.configFileToYaml(allocator, fullConfig(), null)).object;

    try std.testing.expect(document.get("auto_import") != null);
    try std.testing.expect(document.get("sync") != null);
}

test "configFileToYaml: an empty sources list round-trips as an empty list and not as absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = try config_format.defaultConfigFile(allocator);

    const document = try config_format.configFileToYaml(allocator, config, null);

    try std.testing.expectEqual(@as(usize, 0), document.object.get("auto_import").?.object.get("sources").?.array.items.len);
    const readBack = try config_format.yamlToConfigFile(allocator, document);
    try std.testing.expectEqual(@as(usize, 0), readBack.autoImport.settings.sources.len);
}

test "configFileToYaml: the emitted document puts auto-import keys under auto_import and sync keys under sync" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = (try config_format.configFileToYaml(allocator, fullConfig(), null)).object;

    try std.testing.expectEqualStrings(
        "{\"theme\":\"dark\",\"developer_mode\":true,\"show_fps_indicator\":true,\"saved_searches\":[\"beach\",\"2024 birthday\"]," ++
            "\"auto_import\":{\"enabled\":true,\"pause_between_runs_ms\":12345,\"sources\":[{\"type\":\"folder\",\"path\":\"/home/user/Pictures\",\"recurse\":true},{\"type\":\"device-album\",\"album_id\":\"all\"}],\"default_database_path\":\"/home/user/photos\",\"cleanup_enabled\":true}," ++
            "\"sync\":{\"enabled\":true,\"only_on_wifi\":false,\"pause_between_runs_ms\":54321,\"database_path\":\"/home/user/photos\"}}",
        try toJson(allocator, .{
            .object = document,
        }),
    );

    // Nothing that belongs in a section may also appear at the top level.
    try std.testing.expect(document.get("enabled") == null);
    try std.testing.expect(document.get("only_on_wifi") == null);
    try std.testing.expect(document.get("sources") == null);
}

test "configFileToYaml: a folder source writes no album id and a device album source writes no path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = (try config_format.configFileToYaml(allocator, fullConfig(), null)).object;
    const sources = document.get("auto_import").?.object.get("sources").?.array.items;

    try std.testing.expectEqualStrings("{\"type\":\"folder\",\"path\":\"/home/user/Pictures\",\"recurse\":true}", try toJson(allocator, sources[0]));
    try std.testing.expectEqualStrings("{\"type\":\"device-album\",\"album_id\":\"all\"}", try toJson(allocator, sources[1]));
}

// Which sections a document carried, as distinct from the configuration, which fills every section from the defaults.
// A caller has to tell "nobody has chosen this" from "somebody switched it off", and the settings alone cannot say
// which, because both read as switched off.
test "sectionsPresent: an absent document carries no sections" {
    const present = config_format.sectionsPresent(null);

    try std.testing.expect(!present.autoImport);
    try std.testing.expect(!present.sync);
}

test "sectionsPresent: reports each section on its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const autoImportOnly = config_format.sectionsPresent(try parseJson(allocator,
        \\{"auto_import":{"enabled":true}}
    ));
    try std.testing.expect(autoImportOnly.autoImport);
    try std.testing.expect(!autoImportOnly.sync);

    const syncOnly = config_format.sectionsPresent(try parseJson(allocator,
        \\{"sync":{"enabled":true}}
    ));
    try std.testing.expect(!syncOnly.autoImport);
    try std.testing.expect(syncOnly.sync);

    const both = config_format.sectionsPresent(try parseJson(allocator,
        \\{"auto_import":{},"sync":{}}
    ));
    try std.testing.expect(both.autoImport);
    try std.testing.expect(both.sync);
}

test "sectionsPresent: a document holding only settings that belong to no feature carries neither section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const present = config_format.sectionsPresent(try parseJson(allocator,
        \\{"theme":"dark"}
    ));

    try std.testing.expect(!present.autoImport);
    try std.testing.expect(!present.sync);
}

// A hand-edited file can put a string or a list where a section belongs. Counting that as "these settings have been
// chosen" would leave a fresh install unseeded on the strength of a line that says nothing.
test "sectionsPresent: a section that is not an object does not count as present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const present = config_format.sectionsPresent(try parseJson(allocator,
        \\{"sync":"off","auto_import":[1,2]}
    ));

    try std.testing.expect(!present.autoImport);
    try std.testing.expect(!present.sync);
}

test "sectionsPresent: a document that is not an object carries no sections" {
    const present = config_format.sectionsPresent(.{
        .string = "text",
    });

    try std.testing.expect(!present.autoImport);
    try std.testing.expect(!present.sync);
}

test "buildConfigYaml produces a document yamlToConfigFile parses back to the input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = fullConfig();

    const text = try config_format.buildConfigYaml(allocator, original, null);

    try expectConfigEqual(original, try config_format.parseConfigYaml(allocator, text));
}

test "the rendered text nests the sections the way the documentation describes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try config_format.buildConfigYaml(allocator, fullConfig(), null);
    const document = (try node_utils.yaml.load(allocator, text)).object;

    try std.testing.expect(document.get("auto_import").?.object.get("enabled").?.bool);
    try std.testing.expect(!document.get("sync").?.object.get("only_on_wifi").?.bool);
    try std.testing.expectEqualStrings("[\"beach\",\"2024 birthday\"]", try toJson(allocator, document.get("saved_searches").?));
    try std.testing.expectEqualStrings("dark", document.get("theme").?.string);
}

test "parseConfigYaml: text that will not parse as YAML comes back as the defaults rather than throwing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.parseConfigYaml(allocator, "sync:\n  enabled: true\n   bad indentation: [");

    try expectConfigEqual(try config_format.defaultConfigFile(allocator), config);
}

test "parseConfigYaml: an empty document reads as the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try config_format.parseConfigYaml(allocator, "");

    try expectConfigEqual(try config_format.defaultConfigFile(allocator), config);
}

test "parseConfigYamlChecked: reports text that will not parse as malformed, with what the parser said" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try config_format.parseConfigYamlChecked(allocator, "sync:\n  enabled: true\n   bad indentation: [");

    try std.testing.expect(parsed.malformed);
    try std.testing.expect(std.mem.startsWith(u8, parsed.parseError.?, "YAMLException: "));
    try std.testing.expect(!parsed.present.sync);
    try std.testing.expect(!parsed.present.autoImport);
    try std.testing.expect(parsed.document == null);
    try expectConfigEqual(try config_format.defaultConfigFile(allocator), parsed.config);
}

test "parseConfigYamlChecked: reports the sections and the document of text that parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try config_format.parseConfigYamlChecked(allocator, "theme: dark\nsync:\n  enabled: true\n");

    try std.testing.expect(!parsed.malformed);
    try std.testing.expect(parsed.parseError == null);
    try std.testing.expect(parsed.present.sync);
    try std.testing.expect(!parsed.present.autoImport);
    try std.testing.expectEqualStrings("{\"theme\":\"dark\",\"sync\":{\"enabled\":true}}", try toJson(allocator, parsed.document.?));
    try std.testing.expectEqual(config_format.IConfigTheme.dark, parsed.config.theme.?);
}

test "parseConfigYamlChecked: an empty file and a file that is not a mapping have no document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const empty = try config_format.parseConfigYamlChecked(allocator, "");
    const list = try config_format.parseConfigYamlChecked(allocator, "- 1\n- 2\n");

    try std.testing.expect(!empty.malformed);
    try std.testing.expect(empty.document == null);
    try std.testing.expect(!list.malformed);
    try std.testing.expect(list.document == null);
}

//
// An allocator whose first allocation fails and which then works as normal, so a test can tell code that returns an
// out of memory error from code that swallows it and carries on (std.testing.FailingAllocator keeps failing once it
// has failed, which cannot tell the two apart). (No TypeScript counterpart.)
//
const FailsOnceAllocator = struct {
    // The allocator that does the work.
    child: std.mem.Allocator,

    // Whether the failure has been delivered.
    failed: bool = false,

    //
    // Gets the allocator.
    //
    fn allocator(self: *FailsOnceAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    //
    // Fails the first allocation, and passes on the rest.
    //
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        if (!self.failed) {
            self.failed = true;
            return null;
        }
        return self.child.rawAlloc(length, alignment, return_address);
    }

    //
    // Passes a resize on.
    //
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_length, return_address);
    }

    //
    // Passes a remap on.
    //
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_length, return_address);
    }

    //
    // Passes a free on.
    //
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

// Running out of memory is not a parse failure, so it comes back as the error it is and is not reported as a file that
// would not parse.
test "parseConfigYamlChecked: running out of memory is returned and not reported as malformed text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failsOnce: FailsOnceAllocator = .{
        .child = arena.allocator(),
    };

    try std.testing.expectError(error.OutOfMemory, config_format.parseConfigYamlChecked(failsOnce.allocator(), "theme: dark\n"));
}

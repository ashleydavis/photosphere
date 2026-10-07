const std = @import("std");
const node_api = @import("node-api-zig");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const app_config_format = node_api.app_config_format;
const IAppConfig = app_config_format.IAppConfig;
const IAppConfigValue = app_config_format.IAppConfigValue;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;

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
// Reads a document and flattens it (TypeScript: `yamlToAppConfig` of the literal the test passes).
//
fn flatten(allocator: std.mem.Allocator, text: []const u8) !IAppConfig {
    return app_config_format.yamlToAppConfig(allocator, try parseJson(allocator, text));
}

test "yamlToAppConfig: converts every snake_case key to its camelCase field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"theme":"dark","developer_mode":true,"show_fps_indicator":true,"saved_searches":["beach"],"sync":{"enabled":false,"only_on_wifi":false},"auto_import":{"default_database_path":"/db"}}
    );

    try std.testing.expectEqual(node_api.config_format.IConfigTheme.dark, config.theme.?);
    try std.testing.expect(config.developerMode.?);
    try std.testing.expect(config.showFpsIndicator.?);
    try std.testing.expectEqual(@as(usize, 1), config.savedSearches.?.len);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expectEqual(false, config.syncEnabled.?);
    try std.testing.expectEqual(false, config.syncOnlyOnWifi.?);
    try std.testing.expectEqualStrings("/db", config.defaultDatabasePath.?);
    try std.testing.expect(config.autoImportEnabled == null);
    try std.testing.expect(config.autoImportSources == null);
    try std.testing.expect(config.autoImportCleanupEnabled == null);
}

// The UI applies its own defaults, so an unset value has to stay unset rather than becoming false or an empty string
// here.
test "yamlToAppConfig: leaves absent keys absent rather than filling in defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var settings = try app_config_format.appConfigSettings(allocator, try flatten(allocator, "{}"));

    try std.testing.expectEqual(@as(usize, 0), settings.count());
    try std.testing.expectEqual(@as(usize, 0), (try app_config_format.appConfigSettings(allocator, try app_config_format.yamlToAppConfig(allocator, null))).count());
}

test "yamlToAppConfig: a document that is not an object gives an empty config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try app_config_format.yamlToAppConfig(allocator, .{
        .string = "text",
    });

    try std.testing.expectEqual(@as(usize, 0), (try app_config_format.appConfigSettings(allocator, config)).count());
}

test "yamlToAppConfig: a malformed section is ignored without discarding the keys that parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"theme":"light","auto_import":"not a section","sync":{"enabled":true}}
    );

    try std.testing.expectEqual(node_api.config_format.IConfigTheme.light, config.theme.?);
    try std.testing.expect(config.syncEnabled.?);
    try std.testing.expect(config.defaultDatabasePath == null);
}

test "yamlToAppConfig: values of the wrong type are left absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"theme":7,"developer_mode":"yes","show_fps_indicator":"yes","saved_searches":"beach","sync":{"enabled":"yes","only_on_wifi":1},"auto_import":{"enabled":"yes","default_database_path":5,"cleanup_enabled":"yes","sources":"nothing"}}
    );

    try std.testing.expectEqual(@as(usize, 0), (try app_config_format.appConfigSettings(allocator, config)).count());
}

test "yamlToAppConfig: a theme the file names that nobody defined reads as absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"theme":"neon"}
    );

    try std.testing.expect(config.theme == null);
}

test "yamlToAppConfig: an entry of the wrong type is dropped from the saved searches and the rest are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"saved_searches":["beach",17,"dogs"]}
    );

    try std.testing.expectEqual(@as(usize, 2), config.savedSearches.?.len);
    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expectEqualStrings("dogs", config.savedSearches.?[1]);
}

test "yamlToAppConfig: a malformed watched place is dropped and the rest are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"auto_import":{"sources":[{"type":"folder","path":"/photos","recurse":false},{"type":"folder"},{"type":"device-album","album_id":"all"},null,"text"]}}
    );

    const sources = config.autoImportSources.?;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("/photos", sources[0].folder.path);
    try std.testing.expect(!sources[0].folder.recurse);
    try std.testing.expectEqualStrings("all", sources[1].@"device-album".albumId);
}

test "yamlToAppConfig: an empty list of watched places is an empty list and not absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"auto_import":{"sources":[]}}
    );

    try std.testing.expectEqual(@as(usize, 0), config.autoImportSources.?.len);
}

test "yamlToAppConfig: reads the automatic import settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try flatten(allocator,
        \\{"auto_import":{"enabled":true,"default_database_path":"","cleanup_enabled":false}}
    );

    try std.testing.expect(config.autoImportEnabled.?);
    try std.testing.expectEqualStrings("", config.defaultDatabasePath.?);
    try std.testing.expectEqual(false, config.autoImportCleanupEnabled.?);
}

test "appConfigToYaml: converts every camelCase field to its snake_case key in the right section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_config_format.appConfigToYaml(allocator, .{
        .theme = .dark,
        .developerMode = true,
        .showFpsIndicator = true,
        .savedSearches = &.{"beach"},
        .defaultDatabasePath = "/db",
        .syncEnabled = false,
        .syncOnlyOnWifi = false,
    }, .{
        .object = .empty,
    });

    try std.testing.expectEqualStrings(
        "{\"theme\":\"dark\",\"developer_mode\":true,\"show_fps_indicator\":true,\"saved_searches\":[\"beach\"],\"sync\":{\"enabled\":false,\"only_on_wifi\":false},\"auto_import\":{\"default_database_path\":\"/db\"}}",
        try toJson(allocator, document),
    );
}

// An empty section is not the same as no section: the file uses a `sync` section's presence to say syncing has been
// decided, so stamping an empty one in would tell a fresh install its syncing settings had already been chosen and
// leave syncing off with the toggles saying on.
test "appConfigToYaml: omits absent fields rather than writing them as null, and writes no empty section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_config_format.appConfigToYaml(allocator, .{}, .{
        .object = .empty,
    });

    try std.testing.expectEqualStrings("{}", try toJson(allocator, document));
}

test "appConfigToYaml: a section that has been emptied is removed rather than left behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_config_format.appConfigToYaml(allocator, .{}, try parseJson(allocator,
        \\{"sync":{"enabled":true}}
    ));

    try std.testing.expectEqualStrings("{}", try toJson(allocator, document));
}

test "appConfigToYaml: a field that has been cleared is removed from the document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_config_format.appConfigToYaml(allocator, .{
        .developerMode = true,
    }, try parseJson(allocator,
        \\{"theme":"dark","developer_mode":false,"saved_searches":["beach"],"show_fps_indicator":true}
    ));

    try std.testing.expectEqualStrings("{\"developer_mode\":true}", try toJson(allocator, document));
}

test "appConfigToYaml: writes the watched places with only the fields their kind uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sources = [_]IAutoImportSource{
        .{
            .folder = .{
                .path = "/home/someone/Pictures",
                .recurse = true,
            },
        },
        .{
            .@"device-album" = .{
                .albumId = "all",
            },
        },
    };

    const document = try app_config_format.appConfigToYaml(allocator, .{
        .autoImportEnabled = true,
        .defaultDatabasePath = "/home/someone/photosphere-default",
        .autoImportSources = &sources,
        .autoImportCleanupEnabled = true,
    }, .{
        .object = .empty,
    });

    try std.testing.expectEqualStrings(
        "{\"auto_import\":{\"enabled\":true,\"default_database_path\":\"/home/someone/photosphere-default\",\"cleanup_enabled\":true,\"sources\":[{\"type\":\"folder\",\"path\":\"/home/someone/Pictures\",\"recurse\":true},{\"type\":\"device-album\",\"album_id\":\"all\"}]}}",
        try toJson(allocator, document),
    );
}

// The flat view owns only some of the file. The mobile loops' pacing and the database the mobile sync pushes are in the
// same document and appear nowhere in this view, so a desktop write that rebuilt the document from the flat view alone
// would delete them.
test "appConfigToYaml: leaves the parts of the document this view does not own exactly as they were" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try parseJson(allocator,
        \\{"unknown_key":1,"auto_import":{"enabled":true,"pause_between_runs_ms":5000,"sources":[{"type":"device-album","album_id":"all"}]},"sync":{"enabled":true,"database_path":"photosphere-default","pause_between_runs_ms":300000}}
    );
    const config = try app_config_format.yamlToAppConfig(allocator, document);

    var changed = config;
    changed.theme = .dark;
    const merged = try app_config_format.appConfigToYaml(allocator, changed, document);

    try std.testing.expectEqualStrings(
        "{\"unknown_key\":1,\"auto_import\":{\"enabled\":true,\"pause_between_runs_ms\":5000,\"sources\":[{\"type\":\"device-album\",\"album_id\":\"all\"}]}," ++
            "\"sync\":{\"enabled\":true,\"database_path\":\"photosphere-default\",\"pause_between_runs_ms\":300000},\"theme\":\"dark\"}",
        try toJson(allocator, merged),
    );
}

test "appConfigToYaml: does not change the document it was given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try parseJson(allocator,
        \\{"theme":"dark","sync":{"enabled":true}}
    );

    _ = try app_config_format.appConfigToYaml(allocator, .{
        .developerMode = true,
    }, document);

    try std.testing.expectEqualStrings("{\"theme\":\"dark\",\"sync\":{\"enabled\":true}}", try toJson(allocator, document));
}

test "appConfigToYaml: a document that is not an object is replaced by one holding the config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try app_config_format.appConfigToYaml(allocator, .{
        .developerMode = true,
    }, .{
        .string = "text",
    });

    try std.testing.expectEqualStrings("{\"developer_mode\":true}", try toJson(allocator, document));
}

test "a config round trips through the document and back unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sources = [_]IAutoImportSource{.{
        .folder = .{
            .path = "/photos",
            .recurse = false,
        },
    }};
    const original: IAppConfig = .{
        .theme = .light,
        .savedSearches = &.{"dogs"},
        .showFpsIndicator = false,
        .autoImportEnabled = true,
        .defaultDatabasePath = "/photos",
        .autoImportSources = &sources,
        .autoImportCleanupEnabled = false,
    };

    const roundTripped = try app_config_format.yamlToAppConfig(allocator, try app_config_format.appConfigToYaml(allocator, original, .{
        .object = .empty,
    }));

    try std.testing.expectEqual(original.theme, roundTripped.theme);
    try std.testing.expectEqualStrings("dogs", roundTripped.savedSearches.?[0]);
    try std.testing.expectEqual(original.showFpsIndicator, roundTripped.showFpsIndicator);
    try std.testing.expectEqual(original.autoImportEnabled, roundTripped.autoImportEnabled);
    try std.testing.expectEqualStrings("/photos", roundTripped.defaultDatabasePath.?);
    try std.testing.expectEqualStrings("/photos", roundTripped.autoImportSources.?[0].folder.path);
    try std.testing.expect(!roundTripped.autoImportSources.?[0].folder.recurse);
    try std.testing.expectEqual(original.autoImportCleanupEnabled, roundTripped.autoImportCleanupEnabled);
}

test "reading and writing one config setting by name: a key is read from and written to its own field" {
    var config: IAppConfig = .{};

    try app_config_format.setAppConfigValue(&config, "theme", .{
        .string = "dark",
    });
    try app_config_format.setAppConfigValue(&config, "developerMode", .{
        .boolean = true,
    });

    try std.testing.expectEqual(node_api.config_format.IConfigTheme.dark, config.theme.?);
    try std.testing.expectEqualStrings("dark", app_config_format.getAppConfigValue(config, "theme").?.string);
    try std.testing.expect(app_config_format.getAppConfigValue(config, "developerMode").?.boolean);
}

test "reading and writing one config setting by name: every kind of value is stored in its own field" {
    var config: IAppConfig = .{};
    const searches = [_][]const u8{"beach"};
    const sources = [_]IAutoImportSource{.{
        .@"device-album" = .{
            .albumId = "all",
        },
    }};

    try app_config_format.setAppConfigValue(&config, "savedSearches", .{
        .strings = &searches,
    });
    try app_config_format.setAppConfigValue(&config, "defaultDatabasePath", .{
        .string = "/db",
    });
    try app_config_format.setAppConfigValue(&config, "autoImportSources", .{
        .sources = &sources,
    });

    try std.testing.expectEqualStrings("beach", config.savedSearches.?[0]);
    try std.testing.expectEqualStrings("/db", config.defaultDatabasePath.?);
    try std.testing.expectEqualStrings("all", config.autoImportSources.?[0].@"device-album".albumId);
    try std.testing.expectEqualStrings("/db", app_config_format.getAppConfigValue(config, "defaultDatabasePath").?.string);
    try std.testing.expectEqualStrings("beach", app_config_format.getAppConfigValue(config, "savedSearches").?.strings[0]);
    try std.testing.expectEqualStrings("all", app_config_format.getAppConfigValue(config, "autoImportSources").?.sources[0].@"device-album".albumId);
}

test "reading and writing one config setting by name: a key nothing has been stored under reads as nothing" {
    try std.testing.expect(app_config_format.getAppConfigValue(.{}, "theme") == null);
    try std.testing.expect(app_config_format.getAppConfigValue(.{}, "not-a-setting") == null);
}

test "reading and writing one config setting by name: writing nothing removes a key rather than leaving it as it was" {
    var config: IAppConfig = .{
        .theme = .dark,
    };

    try app_config_format.setAppConfigValue(&config, "theme", null);

    try std.testing.expect(config.theme == null);
    try std.testing.expect(app_config_format.getAppConfigValue(config, "theme") == null);
}

test "reading and writing one config setting by name: every setting that has a value is listed together under its own name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const settings = try app_config_format.appConfigSettings(allocator, .{
        .theme = .dark,
        .showFpsIndicator = true,
    });

    try std.testing.expectEqual(@as(usize, 2), settings.count());
    try std.testing.expectEqualStrings("dark", settings.get("theme").?.string);
    try std.testing.expect(settings.get("showFpsIndicator").?.boolean);
    try std.testing.expectEqualStrings("theme", settings.keys()[0]);
    try std.testing.expectEqualStrings("showFpsIndicator", settings.keys()[1]);
}

test "reading and writing one config setting by name: a setting with no value is left out rather than listed as nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const settings = try app_config_format.appConfigSettings(allocator, .{});

    try std.testing.expectEqual(@as(usize, 0), settings.count());
}

test "setAppConfigValue: a key that is not a config setting throws an error naming it" {
    var config: IAppConfig = .{};

    try std.testing.expectError(error.Thrown, app_config_format.setAppConfigValue(&config, "lastFolder", .{
        .string = "/x",
    }));

    try std.testing.expectEqualStrings("\"lastFolder\" is not a config setting.", errors.lastErrorMessage());
}

// TypeScript deletes the property whatever the key is, so clearing a key that is not a config setting leaves the config
// as it was and is not an error.
test "setAppConfigValue: clearing a key that is not a config setting changes nothing" {
    var config: IAppConfig = .{
        .developerMode = true,
    };

    try app_config_format.setAppConfigValue(&config, "lastFolder", null);

    try std.testing.expectEqual(@as(?bool, true), config.developerMode);
}

test "setAppConfigValue: a value of a type the key cannot hold throws an error naming the key and leaves it as it was" {
    var config: IAppConfig = .{
        .developerMode = false,
    };

    try std.testing.expectError(error.Thrown, app_config_format.setAppConfigValue(&config, "developerMode", .{
        .string = "yes",
    }));
    try std.testing.expectEqualStrings("The config setting \"developerMode\" cannot hold a value of that type.", errors.lastErrorMessage());
    try std.testing.expectEqual(false, config.developerMode.?);

    try std.testing.expectError(error.Thrown, app_config_format.setAppConfigValue(&config, "savedSearches", .{
        .boolean = true,
    }));
    try std.testing.expectEqualStrings("The config setting \"savedSearches\" cannot hold a value of that type.", errors.lastErrorMessage());
}

test "setAppConfigValue: a theme that is not one of the themes throws an error naming it" {
    var config: IAppConfig = .{
        .theme = .light,
    };

    try std.testing.expectError(error.Thrown, app_config_format.setAppConfigValue(&config, "theme", .{
        .string = "neon",
    }));
    try std.testing.expectEqualStrings("\"neon\" is not a theme, so it cannot be stored as the config setting \"theme\".", errors.lastErrorMessage());
    try std.testing.expectEqual(node_api.config_format.IConfigTheme.light, config.theme.?);

    try std.testing.expectError(error.Thrown, app_config_format.setAppConfigValue(&config, "theme", .{
        .boolean = true,
    }));
    try std.testing.expectEqualStrings("The config setting \"theme\" holds a theme name, and was given a value that is not a string.", errors.lastErrorMessage());
}

test "IAppConfigValue is the type the settings listing holds" {
    const value: IAppConfigValue = .{
        .number = .{
            .integer = 3,
        },
    };

    try std.testing.expectEqual(@as(i64, 3), value.number.integer);
}

const std = @import("std");
const node_api = @import("node-api-zig");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const app_config_format = node_api.app_config_format;
const IAppConfig = app_config_format.IAppConfig;
const IAppConfigValue = app_config_format.IAppConfigValue;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;

//
// Parses a JSON literal.
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Turns a value into JSON text, for comparing documents (the order of the keys counts too).
//
fn toJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

//
// Reads a document and flattens it.
//
fn flatten(allocator: std.mem.Allocator, text: []const u8) !IAppConfig {
    return app_config_format.yamlToAppConfig(allocator, try parseJson(allocator, text));
}


// The UI applies its own defaults, so an unset value has to stay unset rather than becoming false or an empty string
// here.










// An empty section is not the same as no section: the file uses a `sync` section's presence to say syncing has been
// decided, so stamping an empty one in would tell a fresh install its syncing settings had already been chosen and
// leave syncing off with the toggles saying on.




// The flat view owns only some of the file. The mobile loops' pacing and the database the mobile sync pushes are in the
// same document and appear nowhere in this view, so a desktop write that rebuilt the document from the flat view alone
// would delete them.




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

// The property is deleted whatever the key is, so clearing a key that is not a config setting leaves the config
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

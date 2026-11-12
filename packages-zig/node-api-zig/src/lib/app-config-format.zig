const std = @import("std");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const config_format = @import("config-format.zig");
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const normaliseAutoImportSource = api.auto_import_settings.normaliseAutoImportSource;
const IConfigTheme = config_format.IConfigTheme;
const ALLOWED_THEMES = config_format.ALLOWED_THEMES;
const IStoredAutoImportSource = config_format.IStoredAutoImportSource;
const autoImportSourcesFromStored = config_format.autoImportSourcesFromStored;
const autoImportSourcesToStored = config_format.autoImportSourcesToStored;
const config_state = @import("ziggy").config_state;

//
// The flat key/value view of config.toml that the interface works in.
//
// `IConfig` in user-interface offers get, set, add, remove and clear over a plain string key, and
// every platform provides the get/set pair underneath it. This module is the one definition of what
// the config keys mean: which section of the document each one sits in, and what it is called on disk.
// The state keys are the same idea over state.json, in app-state-format.zig. Nothing decides between
// the two: the interface has a context per store and the caller asks the one it means.
//
// It touches no filesystem, which is what lets it be bundled into the mobile worker. The functions
// that open the file are in app-config.zig, which re-exports everything here so a caller that wants
// both does not have to know they are two modules.
//
// It maps the raw document rather than the normalised configuration on purpose. Every field is
// optional and absent means absent, because the interface applies its own defaults to a setting
// nobody has touched: sync-context starts with syncing on and only overrides that when the store
// returns a value. Handing it the file reader's defaults instead would silently switch syncing off on
// a fresh install. That is why this view exists beside IConfigFile rather than being folded into it.
//
// (Zig: the YAML document is a std.json.Value object, as in config-format.zig.)
//

//
// Every setting the user chooses, flattened into one namespace.
//
pub const IAppConfig = struct {
    //
    // The theme preference: 'light', 'dark', or 'system'.
    //
    theme: ?IConfigTheme = null,

    //
    // Whether developer mode is enabled (reveals developer tools in the UI). Defaults to false when unset.
    //
    developerMode: ?bool = null,

    //
    // Whether the FPS indicator overlay is shown in the UI. Defaults to false when unset.
    //
    showFpsIndicator: ?bool = null,

    //
    // The searches the user has deliberately saved from the sidebar.
    //
    savedSearches: ?[]const []const u8 = null,

    //
    // Whether automatic syncing is enabled. Defaults to false when unset (applied by the UI).
    //
    syncEnabled: ?bool = null,

    //
    // Whether automatic syncing is restricted to Wi-Fi. Defaults to true when unset (applied by the UI).
    //
    syncOnlyOnWifi: ?bool = null,

    //
    // Whether automatic photo import is switched on. Defaults to false when unset.
    //
    autoImportEnabled: ?bool = null,

    //
    // The path of the database automatic import writes to; absent until one has been made the default.
    //
    defaultDatabasePath: ?[]const u8 = null,

    //
    // The places automatic import watches. On desktop these are folders; the type is the shared
    // union so the same settings mean the same thing on every platform.
    //
    autoImportSources: ?[]const IAutoImportSource = null,

    //
    // Whether the source file is deleted once the photo is confirmed in the database. Defaults to
    // false when unset.
    //
    autoImportCleanupEnabled: ?bool = null,
};

//
// The key path each field of IAppConfig is stored at. The field names are the interface's names and the values are the file's keys.
//
pub const APP_CONFIG_PATHS = .{
    .theme = "theme",
    .developerMode = "developer_mode",
    .showFpsIndicator = "show_fps_indicator",
    .savedSearches = "saved_searches",
    .syncEnabled = "sync.enabled",
    .syncOnlyOnWifi = "sync.only_on_wifi",
    .autoImportEnabled = "auto_import.enabled",
    .defaultDatabasePath = "auto_import.default_database_path",
    .autoImportSources = "auto_import.sources",
    .autoImportCleanupEnabled = "auto_import.cleanup_enabled",
};

//
// Reads one field of IAppConfig from the config file, through the typed API.
//
pub fn getAppConfig(comptime field_name: []const u8, arena: std.mem.Allocator, io: std.Io, config_path: []const u8) !@FieldType(IAppConfig, field_name) {
    const path = @field(APP_CONFIG_PATHS, field_name);
    if (comptime std.mem.eql(u8, field_name, "autoImportSources")) {
        const stored = try config_state.config.get(?[]const IStoredAutoImportSource, arena, io, config_path, path);
        return try autoImportSourcesFromStored(arena, stored);
    }
    return config_state.config.get(@FieldType(IAppConfig, field_name), arena, io, config_path, path);
}

//
// Writes one field of IAppConfig to the config file, through the typed API.
//
pub fn setAppConfig(comptime field_name: []const u8, arena: std.mem.Allocator, io: std.Io, config_path: []const u8, value: @FieldType(IAppConfig, field_name)) !void {
    const path = @field(APP_CONFIG_PATHS, field_name);
    if (comptime std.mem.eql(u8, field_name, "autoImportSources")) {
        const stored = try autoImportSourcesToStored(arena, value);
        return config_state.config.set(arena, io, config_path, path, stored);
    }
    return config_state.config.set(arena, io, config_path, path, value);
}

//
// A value one of the flat config keys can hold.
// (Zig: a tagged union with a case for each of the types a config value can be: boolean, number, string, list of strings
// and list of auto-import sources. The theme is the `string` case, holding the theme's name.)
//
pub const IAppConfigValue = union(enum) {
    // A boolean setting.
    boolean: bool,

    // A number setting.
    number: std.json.Value,

    // A string setting.
    string: []const u8,

    // A list of strings.
    strings: []const []const u8,

    // A list of watched places.
    sources: []const IAutoImportSource,
};

//
// Every config key that has a value, under the name the interface uses for it, in the order the keys are declared in
// IAppConfig.
//
pub const IAppConfigSettings = std.StringArrayHashMapUnmanaged(IAppConfigValue);

//
// Gets the value of a field of IAppConfig as a flat config value, or null when the field has no value.
//
fn fieldValue(comptime FieldType: type, field: FieldType) ?IAppConfigValue {
    const value = field orelse {
        return null;
    };
    const ValueType = @TypeOf(value);
    if (ValueType == IConfigTheme) {
        return .{
            .string = @tagName(value),
        };
    }
    if (ValueType == bool) {
        return .{
            .boolean = value,
        };
    }
    if (ValueType == []const u8) {
        return .{
            .string = value,
        };
    }
    if (ValueType == []const []const u8) {
        return .{
            .strings = value,
        };
    }
    if (ValueType == []const IAutoImportSource) {
        return .{
            .sources = value,
        };
    }
    @compileError("IAppConfig has a field of a type IAppConfigValue cannot hold");
}

//
// Reads one flat config key. null when nothing has been stored under it.
//
// Every key config.toml holds is declared as a field of IAppConfig, so unlike the state view there is
// no catch-all here: a key that is not a config key never reaches this module, because the routing
// sends it to state.json instead.
//
// (Zig: a key that is not a field of IAppConfig reads as null.)
//
pub fn getAppConfigValue(config: IAppConfig, key: []const u8) ?IAppConfigValue {
    inline for (std.meta.fields(IAppConfig)) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            return fieldValue(field.type, @field(config, field.name));
        }
    }
    return null;
}

//
// Writes one flat config key. null removes it, which is what IConfig.clear means.
//
// (Zig: a field has one type, so a value for a key that is not a config key, or a value of a type the key cannot hold
// (including a theme that is not one of ALLOWED_THEMES), throws an error saying so instead of being stored where
// nothing reads it. Clearing a key that is not a config key removes nothing, and is not an error.)
//
pub fn setAppConfigValue(config: *IAppConfig, key: []const u8, value: ?IAppConfigValue) !void {
    inline for (std.meta.fields(IAppConfig)) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            const present = value orelse {
                @field(config, field.name) = null;
                return;
            };
            const FieldValueType = @typeInfo(field.type).optional.child;
            if (FieldValueType == IConfigTheme) {
                if (present != .string) {
                    return errors.throwError("The config setting \"{s}\" holds a theme name, and was given a value that is not a string.", .{key});
                }
                for (ALLOWED_THEMES) |allowedTheme| {
                    if (std.mem.eql(u8, present.string, @tagName(allowedTheme))) {
                        @field(config, field.name) = allowedTheme;
                        return;
                    }
                }
                return errors.throwError("\"{s}\" is not a theme, so it cannot be stored as the config setting \"{s}\".", .{ present.string, key });
            }
            if (FieldValueType == bool and present == .boolean) {
                @field(config, field.name) = present.boolean;
                return;
            }
            if (FieldValueType == []const u8 and present == .string) {
                @field(config, field.name) = present.string;
                return;
            }
            if (FieldValueType == []const []const u8 and present == .strings) {
                @field(config, field.name) = present.strings;
                return;
            }
            if (FieldValueType == []const IAutoImportSource and present == .sources) {
                @field(config, field.name) = present.sources;
                return;
            }
            return errors.throwError("The config setting \"{s}\" cannot hold a value of that type.", .{key});
        }
    }
    if (value == null) {
        return;
    }
    return errors.throwError("\"{s}\" is not a config setting.", .{key});
}

//
// Every config key that has a value, under the name the interface uses for it.
//
// The whole config store in one object, for a caller that wants to read settings by name without
// having to know which section each one sits in.
//
pub fn appConfigSettings(allocator: std.mem.Allocator, config: IAppConfig) !IAppConfigSettings {
    var settings: IAppConfigSettings = .empty;

    inline for (std.meta.fields(IAppConfig)) |field| {
        if (fieldValue(field.type, @field(config, field.name))) |value| {
            try settings.put(allocator, field.name, value);
        }
    }

    return settings;
}


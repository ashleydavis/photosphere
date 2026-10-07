const std = @import("std");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const config_format = @import("config-format.zig");
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const normaliseAutoImportSource = api.auto_import_settings.normaliseAutoImportSource;
const IConfigTheme = config_format.IConfigTheme;
const ALLOWED_THEMES = config_format.ALLOWED_THEMES;

//
// The flat key/value view of config.yaml that the interface works in.
//
// `IConfig` in user-interface offers get, set, add, remove and clear over a plain string key, and
// every platform provides the get/set pair underneath it. This module is the one definition of what
// the config keys mean: which section of the document each one sits in, and what it is called on disk.
// The state keys are the same idea over state.yaml, in app-state-format.ts. Nothing decides between
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
    // Whether automatic syncing is enabled. Defaults to true when unset (applied by the UI).
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
// A value one of the flat config keys can hold.
// (Zig: a tagged union with a case for each of the types TypeScript's `boolean | number | string | string[] |
// IAutoImportSource[]` names. The theme is the `string` case, holding the theme's name.)
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
// IAppConfig. (No TypeScript counterpart: TypeScript's `Record<string, IAppConfigValue>`.)
//
pub const IAppConfigSettings = std.StringArrayHashMapUnmanaged(IAppConfigValue);

//
// Gets the value of a field of IAppConfig as a flat config value, or null when the field has no value.
// (No TypeScript counterpart: TypeScript reads the field of the object by name.)
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
// Every key config.yaml holds is declared as a field of IAppConfig, so unlike the state view there is
// no catch-all here: a key that is not a config key never reaches this module, because the routing
// sends it to state.yaml instead.
//
// (Zig: a key that is not a field of IAppConfig reads as null, as an undeclared property reads as undefined.)
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
// (Zig: TypeScript stores whatever it is given under whatever name it is given, and appConfigToYaml then ignores it.
// A Zig field has one type, so a value for a key that is not a config key, or a value of a type the key cannot hold
// (including a theme that is not one of ALLOWED_THEMES), throws an error saying so instead of being stored where
// nothing reads it. Clearing a key that is not a config key removes nothing, as `delete` of an absent property does,
// and is not an error.)
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

//
// True when the value is an object we can read keys off, and not an array or null. A hand-edited
// file can put a string or a list where a section belongs, and reading keys off one of those gives
// undefined for everything, which would look like an empty section rather than a malformed one.
//
fn isSection(value: ?std.json.Value) bool {
    return value != null and value.? == .object;
}

//
// Turns the watched places in the document into settings, dropping any that are malformed.
//
// It goes through the shared normaliser rather than trusting the file, because this list reaches the
// import task and a source with no path would have it scanning nothing while looking like it worked.
//
// (Zig: a source that is not an object has no fields, so it is read as one with none, as `rawSource?.type` reads
// undefined off a null or a string.)
//
fn documentSources(allocator: std.mem.Allocator, section: std.json.ObjectMap) !?[]const IAutoImportSource {
    const rawSources = section.get("sources") orelse {
        return null;
    };
    if (rawSources != .array) {
        return null;
    }

    var sources: std.ArrayList(IAutoImportSource) = .empty;
    for (rawSources.array.items) |rawSource| {
        var normalisable: std.json.ObjectMap = .empty;
        if (rawSource == .object) {
            if (rawSource.object.get("type")) |sourceType| {
                try normalisable.put(allocator, "type", sourceType);
            }
            if (rawSource.object.get("path")) |path| {
                try normalisable.put(allocator, "path", path);
            }
            if (rawSource.object.get("recurse")) |recurse| {
                try normalisable.put(allocator, "recurse", recurse);
            }
            if (rawSource.object.get("album_id")) |albumId| {
                try normalisable.put(allocator, "albumId", albumId);
            }
        }
        if (normaliseAutoImportSource(.{
            .object = normalisable,
        })) |source| {
            try sources.append(allocator, source);
        }
    }
    return sources.items;
}

//
// Flattens the on-disk document into the key/value view the interface works in.
//
pub fn yamlToAppConfig(allocator: std.mem.Allocator, document: ?std.json.Value) !IAppConfig {
    var config: IAppConfig = .{};
    if (!isSection(document)) {
        return config;
    }
    const fields = document.?.object;

    if (fields.get("theme")) |theme| {
        if (theme == .string) {
            for (ALLOWED_THEMES) |allowedTheme| {
                if (std.mem.eql(u8, theme.string, @tagName(allowedTheme))) {
                    config.theme = allowedTheme;
                }
            }
        }
    }
    if (fields.get("developer_mode")) |developerMode| {
        if (developerMode == .bool) {
            config.developerMode = developerMode.bool;
        }
    }
    if (fields.get("show_fps_indicator")) |showFpsIndicator| {
        if (showFpsIndicator == .bool) {
            config.showFpsIndicator = showFpsIndicator.bool;
        }
    }
    if (fields.get("saved_searches")) |savedSearches| {
        if (savedSearches == .array) {
            var searches: std.ArrayList([]const u8) = .empty;
            for (savedSearches.array.items) |search| {
                if (search == .string) {
                    try searches.append(allocator, search.string);
                }
            }
            config.savedSearches = searches.items;
        }
    }

    if (isSection(fields.get("sync"))) {
        const sync = fields.get("sync").?.object;
        if (sync.get("enabled")) |enabled| {
            if (enabled == .bool) {
                config.syncEnabled = enabled.bool;
            }
        }
        if (sync.get("only_on_wifi")) |onlyOnWifi| {
            if (onlyOnWifi == .bool) {
                config.syncOnlyOnWifi = onlyOnWifi.bool;
            }
        }
    }

    if (isSection(fields.get("auto_import"))) {
        const autoImport = fields.get("auto_import").?.object;
        if (autoImport.get("enabled")) |enabled| {
            if (enabled == .bool) {
                config.autoImportEnabled = enabled.bool;
            }
        }
        if (autoImport.get("default_database_path")) |defaultDatabasePath| {
            if (defaultDatabasePath == .string) {
                config.defaultDatabasePath = defaultDatabasePath.string;
            }
        }
        if (autoImport.get("cleanup_enabled")) |cleanupEnabled| {
            if (cleanupEnabled == .bool) {
                config.autoImportCleanupEnabled = cleanupEnabled.bool;
            }
        }
        if (try documentSources(allocator, autoImport)) |sources| {
            config.autoImportSources = sources;
        }
    }

    return config;
}

//
// Converts one watched place to its on-disk contents, writing only the fields its kind uses.
//
fn sourceToYaml(allocator: std.mem.Allocator, source: IAutoImportSource) !std.json.Value {
    var yamlSource: std.json.ObjectMap = .empty;
    switch (source) {
        .folder => |folder| {
            try yamlSource.put(allocator, "type", .{
                .string = "folder",
            });
            try yamlSource.put(allocator, "path", .{
                .string = folder.path,
            });
            try yamlSource.put(allocator, "recurse", .{
                .bool = folder.recurse,
            });
        },
        .@"device-album" => |album| {
            try yamlSource.put(allocator, "type", .{
                .string = "device-album",
            });
            try yamlSource.put(allocator, "album_id", .{
                .string = album.albumId,
            });
        },
    }
    return .{
        .object = yamlSource,
    };
}

//
// Writes one field into a section, or removes it from the section when it has been cleared.
//
// Removing matters because this view is built from the document: a field that is absent here was
// absent there, so writing "nothing" back has to mean the key goes, or IConfig.clear would report
// success and change nothing on disk. A value the reader refused (a theme naming a colour that does
// not exist) also arrives here as absent and is dropped on the next write, which costs the user that
// one line and no other setting in the file.
//
fn writeField(allocator: std.mem.Allocator, section: *std.json.ObjectMap, key: []const u8, value: ?std.json.Value) !void {
    const present = value orelse {
        _ = section.orderedRemove(key);
        return;
    };
    try section.put(allocator, key, present);
}

//
// Writes a section into the document, or leaves the document without it when it holds nothing.
//
// An empty section is never written, because for both of these the file uses the section's presence to
// answer a question the settings themselves cannot: an empty `sync` section says syncing has been
// decided, and a fresh install told that keeps syncing switched off while its toggles say it is on.
// The desktop app used to stamp an empty one into the file the first time a theme was changed, which
// only went unnoticed because nothing on that platform reads the answer.
//
fn writeSection(allocator: std.mem.Allocator, document: *std.json.ObjectMap, name: []const u8, section: std.json.ObjectMap) !void {
    if (section.count() > 0) {
        try document.put(allocator, name, .{
            .object = section,
        });
        return;
    }
    _ = document.orderedRemove(name);
}

//
// Makes a YAML boolean, or null for no value. (No TypeScript counterpart: TypeScript writes the value itself.)
//
fn boolValue(value: ?bool) ?std.json.Value {
    const present = value orelse {
        return null;
    };
    return .{
        .bool = present,
    };
}

//
// Makes a YAML string, or null for no value. (No TypeScript counterpart: TypeScript writes the value itself.)
//
fn stringValue(value: ?[]const u8) ?std.json.Value {
    const present = value orelse {
        return null;
    };
    return .{
        .string = present,
    };
}

//
// Writes the flat view back into the document, leaving everything this view does not own where it is.
//
// The merge matters: the document also carries the background loops' pacing and the database the
// mobile sync pushes, and neither appears in the flat view. Rebuilding the document from the flat view
// alone would drop them every time the desktop app remembered a theme.
//
// (Zig: the document is the std.json.Value read from disk, which is copied, not changed. The sections are copied one
// level deep, which is as deep as TypeScript's `{ ...document }` and `{ ...merged.sync }` copy.)
//
pub fn appConfigToYaml(allocator: std.mem.Allocator, config: IAppConfig, document: std.json.Value) !std.json.Value {
    var merged: std.json.ObjectMap = if (isSection(document)) try document.object.clone(allocator) else .empty;

    const theme: ?std.json.Value = if (config.theme) |theme| .{
        .string = @tagName(theme),
    } else null;
    try writeField(allocator, &merged, "theme", theme);
    try writeField(allocator, &merged, "developer_mode", boolValue(config.developerMode));
    try writeField(allocator, &merged, "show_fps_indicator", boolValue(config.showFpsIndicator));
    var savedSearches: ?std.json.Value = null;
    if (config.savedSearches) |searches| {
        var searchesArray = std.json.Array.init(allocator);
        for (searches) |search| {
            try searchesArray.append(.{
                .string = search,
            });
        }
        savedSearches = .{
            .array = searchesArray,
        };
    }
    try writeField(allocator, &merged, "saved_searches", savedSearches);

    var sync: std.json.ObjectMap = if (isSection(merged.get("sync"))) try merged.get("sync").?.object.clone(allocator) else .empty;
    try writeField(allocator, &sync, "enabled", boolValue(config.syncEnabled));
    try writeField(allocator, &sync, "only_on_wifi", boolValue(config.syncOnlyOnWifi));
    try writeSection(allocator, &merged, "sync", sync);

    var autoImport: std.json.ObjectMap = if (isSection(merged.get("auto_import"))) try merged.get("auto_import").?.object.clone(allocator) else .empty;
    try writeField(allocator, &autoImport, "enabled", boolValue(config.autoImportEnabled));
    try writeField(allocator, &autoImport, "default_database_path", stringValue(config.defaultDatabasePath));
    try writeField(allocator, &autoImport, "cleanup_enabled", boolValue(config.autoImportCleanupEnabled));
    var yamlSources: ?std.json.Value = null;
    if (config.autoImportSources) |sources| {
        var sourcesArray = std.json.Array.init(allocator);
        for (sources) |source| {
            try sourcesArray.append(try sourceToYaml(allocator, source));
        }
        yamlSources = .{
            .array = sourcesArray,
        };
    }
    try writeField(allocator, &autoImport, "sources", yamlSources);
    try writeSection(allocator, &merged, "auto_import", autoImport);

    return .{
        .object = merged,
    };
}

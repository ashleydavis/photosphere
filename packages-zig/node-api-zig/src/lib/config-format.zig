const std = @import("std");
const node_utils = @import("node-utils-zig");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const auto_import_settings = api.auto_import_settings;
const IAutoImportSource = auto_import_settings.IAutoImportSource;
const IRawAutoImportSource = auto_import_settings.IRawAutoImportSource;
const IRawAutoImportSettings = auto_import_settings.IRawAutoImportSettings;
const normaliseAutoImportSettings = auto_import_settings.normaliseAutoImportSettings;
const normaliseAutoImportSource = auto_import_settings.normaliseAutoImportSource;
const IAutoImportFile = api.auto_import_mobile.IAutoImportFile;
const resolveAutoImportPauseMs = api.auto_import_mobile.resolveAutoImportPauseMs;
const ISyncFile = api.sync_settings.ISyncFile;
const IRawSyncSettings = api.sync_settings.IRawSyncSettings;
const normaliseSyncSettings = api.sync_settings.normaliseSyncSettings;
const resolveSyncPauseMs = api.sync_settings.resolveSyncPauseMs;
const config_state = @import("ziggy").config_state;

//
// The on-disk contents of config.toml and the conversions between it and the in-memory type.
//
// One file holds every setting the app remembers, on every platform: ~/.config/photosphere/config.toml
// for the CLI and the desktop app, and config.toml at the root of the storage sandbox on a mobile. One
// file means one format definition, so a setting means the same thing whichever platform wrote it.
// The wiki page "Configuration-File" documents the file for users.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//
// This file is what the user chose. What the app remembered on its own, so the interface comes back
// the way it was left, is in state.json beside it (see state-format.zig). The two are split because
// only one of them is worth documenting, hand-editing or carrying to another machine.
//
// The settings themselves are not defined here. The normalisers in `api` own what a valid setting is
// (normaliseSyncSettings, normaliseAutoImportSettings and the two pause resolvers), because the
// interface applies the same rules to values that never came from this file. This module is only
// about the document: which section a setting sits in, and what its key is called on disk.
//
// (Zig: the YAML documents (IYamlConfigFile, IYamlAutoImportSection, IYamlAutoImportSource and IYamlSyncSection) are
// std.json.Value objects, which is what node-utils-zig's YAML reader and writer work in, so they have no separate struct
// types. A number the file holds (the pacing) is a std.json.Value that is a number, so an integer stays an integer when
// it is written back.)
//

//
// Everything config.toml holds, in memory, with camelCase fields.
//
// The auto-import and sync sections are the already-resolved types the rest of the app works with
// (settings plus pacing plus the database path), not raw stored blobs: anything reading this type
// has values that have been through the normalisers.
//
pub const IConfigFile = struct {
    //
    // Whether developer mode is on, which reveals the developer tools in the interface.
    //
    developerMode: ?bool = null,

    //
    // Whether the frames-per-second overlay is drawn.
    //
    showFpsIndicator: ?bool = null,

    //
    // The searches the user has deliberately saved from the sidebar. The ones they merely ran are in
    // state.json, because those the app remembered rather than the user chose.
    //
    savedSearches: ?[]const []const u8 = null,

    //
    // What automatic photo import watches, where it puts what it finds, and how often it looks.
    //
    autoImport: IAutoImportFile,

    //
    // Whether the source file is deleted once the photo is confirmed in the database.
    //
    autoImportCleanupEnabled: ?bool = null,

    //
    // The two syncing toggles, the database the background loop pushes, and how often it runs.
    //
    sync: ISyncFile,
};

//
// Gets the object of a value that is one, or null.
//
fn objectOf(value: ?std.json.Value) ?std.json.ObjectMap {
    const present = value orelse {
        return null;
    };
    return if (present == .object) present.object else null;
}

//
// Copies a field of one object into another when the first has it, so a field that is absent stays absent.
//
fn copyField(allocator: std.mem.Allocator, target: *std.json.ObjectMap, source: std.json.ObjectMap, sourceKey: []const u8, targetKey: []const u8) !void {
    if (source.get(sourceKey)) |value| {
        try target.put(allocator, targetKey, value);
    }
}

//
// Converts one on-disk source to the raw source the normaliser checks.
//
// It goes to the raw type rather than straight to IAutoImportSource because a hand-edited or older
// file may hold anything at all, and normaliseAutoImportSettings is the only supported way to turn
// that into settings.
//
// (Zig: a source that is null throws here with a TypeError message
// instead of being dropped; any other value that is not an object has no fields.)
//
fn yamlSourceToRawSource(allocator: std.mem.Allocator, yamlSource: std.json.Value) !IRawAutoImportSource {
    if (yamlSource == .null) {
        return errors.throwError("Cannot read properties of null (reading 'type')", .{});
    }

    var rawSource: std.json.ObjectMap = .empty;
    if (yamlSource == .object) {
        try copyField(allocator, &rawSource, yamlSource.object, "type", "type");
        try copyField(allocator, &rawSource, yamlSource.object, "path", "path");
        try copyField(allocator, &rawSource, yamlSource.object, "recurse", "recurse");
        try copyField(allocator, &rawSource, yamlSource.object, "album_id", "albumId");
    }
    return .{
        .object = rawSource,
    };
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
// True when the value is an object we can read keys off, and not an array or null.
//
// Every section is read through this because a hand-edited file can put a string or a list where a
// section belongs, and reading keys off one of those gives undefined for everything, which would
// silently look like an empty section rather than a malformed one.
//
fn isSection(value: ?std.json.Value) bool {
    return value != null and value.? == .object;
}

//
// Gets a non-empty string field of a section.
//
fn nonEmptyStringField(section: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = section.get(key) orelse {
        return null;
    };
    if (value == .string and value.string.len > 0) {
        return value.string;
    }
    return null;
}

//
// Turns the `auto_import` section into the settings, the database path and the pacing.
//
fn yamlToAutoImportFile(allocator: std.mem.Allocator, section: ?std.json.Value) !IAutoImportFile {
    if (!isSection(section)) {
        return .{
            .settings = try normaliseAutoImportSettings(allocator, null),
            .defaultDatabasePath = null,
            .pauseBetweenRunsMs = resolveAutoImportPauseMs(null),
        };
    }
    const fields = section.?.object;

    var rawSources = std.json.Array.init(allocator);
    if (fields.get("sources")) |sources| {
        if (sources == .array) {
            for (sources.array.items) |yamlSource| {
                try rawSources.append(try yamlSourceToRawSource(allocator, yamlSource));
            }
        }
    }
    var rawSettingsFields: std.json.ObjectMap = .empty;
    try copyField(allocator, &rawSettingsFields, fields, "enabled", "enabled");
    try rawSettingsFields.put(allocator, "sources", .{
        .array = rawSources,
    });
    const rawSettings: IRawAutoImportSettings = .{
        .object = rawSettingsFields,
    };

    return .{
        .settings = try normaliseAutoImportSettings(allocator, rawSettings),
        .defaultDatabasePath = nonEmptyStringField(fields, "default_database_path"),
        .pauseBetweenRunsMs = resolveAutoImportPauseMs(fields.get("pause_between_runs_ms")),
    };
}

//
// Turns the `sync` section into the settings, the database path and the pacing.
//
fn yamlToSyncFile(allocator: std.mem.Allocator, section: ?std.json.Value) !ISyncFile {
    if (!isSection(section)) {
        return .{
            .settings = normaliseSyncSettings(null),
            .databasePath = null,
            .pauseBetweenRunsMs = resolveSyncPauseMs(null),
        };
    }
    const fields = section.?.object;

    var rawSettingsFields: std.json.ObjectMap = .empty;
    try copyField(allocator, &rawSettingsFields, fields, "enabled", "enabled");
    try copyField(allocator, &rawSettingsFields, fields, "only_on_wifi", "onlyOnWifi");
    const rawSettings: IRawSyncSettings = .{
        .object = rawSettingsFields,
    };

    return .{
        .settings = normaliseSyncSettings(rawSettings),
        .databasePath = nonEmptyStringField(fields, "database_path"),
        .pauseBetweenRunsMs = resolveSyncPauseMs(fields.get("pause_between_runs_ms")),
    };
}

//
// Turns the parsed document into the configuration the app works with.
//
// A file that is not there arrives here as undefined and comes back as the defaults, which have both
// automatic import and syncing switched off. That is the whole point of the defaults being what they
// are: a mobile that cannot read its settings must not start pushing over a metered connection.
//
// A section that is malformed falls back to that section's own defaults without discarding the
// sections that did parse, and a key nothing recognises is ignored rather than rejected. One
// mistyped line in a hand-edited file must not cost the user every other setting in it.
//
pub fn defaultConfigFile(allocator: std.mem.Allocator) !IConfigFile {
    return .{
        .autoImport = try autoImportFileFromStored(allocator, null),
        .sync = syncFileFromStored(allocator, null),
    };
}

//
// The sync section as the config file holds it, with every field optional and named by its key.
//
pub const IStoredSyncSection = struct {
    // Whether syncing is on.
    enabled: ?bool = null,
    // Whether syncing waits for Wi-Fi.
    only_on_wifi: ?bool = null,
    // The database the background loop pushes.
    database_path: ?[]const u8 = null,
    // How long the loop waits between runs.
    pause_between_runs_ms: ?f64 = null,
};

//
// One watched place as the config file holds it, with every field optional and named by its key.
//
pub const IStoredAutoImportSource = struct {
    // The kind of place, "folder" or "device-album".
    @"type": ?[]const u8 = null,
    // The folder's path, for a folder.
    path: ?[]const u8 = null,
    // Whether a folder's subfolders are watched, for a folder.
    recurse: ?bool = null,
    // The device album's id, for a device album.
    album_id: ?[]const u8 = null,
};

//
// The automatic import section as the config file holds it, with every field optional and named by its key.
//
pub const IStoredAutoImportSection = struct {
    // Whether automatic import is on.
    enabled: ?bool = null,
    // The database automatic import writes to.
    default_database_path: ?[]const u8 = null,
    // How long automatic import waits between runs.
    pause_between_runs_ms: ?f64 = null,
    // Whether the source file is deleted once its photo is in the database.
    cleanup_enabled: ?bool = null,
    // The watched places.
    sources: ?[]const IStoredAutoImportSource = null,
};

//
// The pacing as the file's kind of value: a whole number when it is whole and fits, else a float, so a whole pause stays an integer when
// it is written back.
//
pub fn pauseValue(pause: f64) std.json.Value {
    if (pause == @floor(pause) and pause >= @as(f64, @floatFromInt(std.math.minInt(i64))) and pause <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
        return .{ .integer = @intFromFloat(pause) };
    }
    return .{ .float = pause };
}

//
// Builds the sync settings from the section the file holds.
//
pub fn syncFileFromStored(allocator: std.mem.Allocator, stored: ?IStoredSyncSection) ISyncFile {
    const section = stored orelse IStoredSyncSection{};
    var raw: std.json.ObjectMap = .empty;
    if (section.enabled) |enabled| {
        raw.put(allocator, "enabled", .{ .bool = enabled }) catch @panic("out of memory reading the sync settings");
    }
    if (section.only_on_wifi) |onlyOnWifi| {
        raw.put(allocator, "onlyOnWifi", .{ .bool = onlyOnWifi }) catch @panic("out of memory reading the sync settings");
    }
    const pause: ?std.json.Value = if (section.pause_between_runs_ms) |pauseMs| pauseValue(pauseMs) else null;
    return .{
        .settings = normaliseSyncSettings(.{ .object = raw }),
        .databasePath = section.database_path,
        .pauseBetweenRunsMs = resolveSyncPauseMs(pause),
    };
}

//
// Builds the automatic import settings from the section the file holds.
//
pub fn autoImportFileFromStored(allocator: std.mem.Allocator, stored: ?IStoredAutoImportSection) !IAutoImportFile {
    const section = stored orelse IStoredAutoImportSection{};
    var raw: std.json.ObjectMap = .empty;
    if (section.enabled) |enabled| {
        try raw.put(allocator, "enabled", .{ .bool = enabled });
    }
    var sources: std.json.Array = .init(allocator);
    if (section.sources) |storedSources| {
        for (storedSources) |source| {
            var rawSource: std.json.ObjectMap = .empty;
            if (source.@"type") |sourceType| {
                try rawSource.put(allocator, "type", .{ .string = sourceType });
            }
            if (source.path) |path| {
                try rawSource.put(allocator, "path", .{ .string = path });
            }
            if (source.recurse) |recurse| {
                try rawSource.put(allocator, "recurse", .{ .bool = recurse });
            }
            if (source.album_id) |albumId| {
                try rawSource.put(allocator, "albumId", .{ .string = albumId });
            }
            try sources.append(.{ .object = rawSource });
        }
    }
    try raw.put(allocator, "sources", .{ .array = sources });
    const pause: ?std.json.Value = if (section.pause_between_runs_ms) |pauseMs| pauseValue(pauseMs) else null;
    return .{
        .settings = try normaliseAutoImportSettings(allocator, .{ .object = raw }),
        .defaultDatabasePath = section.default_database_path,
        .pauseBetweenRunsMs = resolveAutoImportPauseMs(pause),
    };
}

//
// The sync section as the file holds it. The pause is left null, because a pause is never written through a stored section.
//
pub fn syncFileToStored(file: ISyncFile) IStoredSyncSection {
    return .{
        .enabled = file.settings.enabled,
        .only_on_wifi = file.settings.onlyOnWifi,
        .database_path = file.databasePath,
    };
}

//
// The automatic import section as the file holds it. The pause is left null, because a pause is never written through a stored section.
//
pub fn autoImportFileToStored(allocator: std.mem.Allocator, file: IAutoImportFile) !IStoredAutoImportSection {
    var sources: std.ArrayList(IStoredAutoImportSource) = .empty;
    for (file.settings.sources) |source| {
        switch (source) {
            .folder => |folder| try sources.append(allocator, .{ .@"type" = "folder", .path = folder.path, .recurse = folder.recurse }),
            .@"device-album" => |album| try sources.append(allocator, .{ .@"type" = "device-album", .album_id = album.albumId }),
        }
    }
    return .{
        .enabled = file.settings.enabled,
        .default_database_path = file.defaultDatabasePath,
        .cleanup_enabled = null,
        .sources = sources.items,
    };
}

//
// The watched places as the file holds them, from the settings the app works with.
//
pub fn autoImportSourcesToStored(allocator: std.mem.Allocator, sources: ?[]const IAutoImportSource) !?[]const IStoredAutoImportSource {
    const present = sources orelse return null;
    var stored: std.ArrayList(IStoredAutoImportSource) = .empty;
    for (present) |source| {
        switch (source) {
            .folder => |folder| try stored.append(allocator, .{ .@"type" = "folder", .path = folder.path, .recurse = folder.recurse }),
            .@"device-album" => |album| try stored.append(allocator, .{ .@"type" = "device-album", .album_id = album.albumId }),
        }
    }
    return stored.items;
}

//
// The watched places the app works with, from the ones the file holds, each through the shared normaliser.
//
pub fn autoImportSourcesFromStored(allocator: std.mem.Allocator, sources: ?[]const IStoredAutoImportSource) !?[]const IAutoImportSource {
    const present = sources orelse return null;
    var normalised: std.ArrayList(IAutoImportSource) = .empty;
    for (present) |source| {
        var raw: std.json.ObjectMap = .empty;
        if (source.@"type") |sourceType| {
            try raw.put(allocator, "type", .{ .string = sourceType });
        }
        if (source.path) |path| {
            try raw.put(allocator, "path", .{ .string = path });
        }
        if (source.recurse) |recurse| {
            try raw.put(allocator, "recurse", .{ .bool = recurse });
        }
        if (source.album_id) |albumId| {
            try raw.put(allocator, "albumId", .{ .string = albumId });
        }
        if (normaliseAutoImportSource(.{ .object = raw })) |found| {
            try normalised.append(allocator, found);
        }
    }
    return normalised.items;
}

//
// Writes a pause, already the file's kind of value, at a key path. An integer writes as an integer, a float as a float, and a null
// removes the key.
//
pub fn setPause(values: config_state.config.Values, key_path: []const u8, pause: std.json.Value) !void {
    switch (pause) {
        .integer => |integer| try values.set(key_path, integer),
        .float => |float| try values.set(key_path, float),
        .null => try values.set(key_path, @as(?i64, null)),
        else => return errors.throwError("The pause at \"{s}\" must be a whole number, a number or null.", .{key_path}),
    }
}

//
// Which sections a document actually carried.
//
// Separate from the configuration itself, which fills every section from the defaults so nothing
// downstream has to check. A caller sometimes has to tell "nobody has written this yet" from
// "somebody switched it off", and the settings alone cannot say which it is because both read as
// switched off. When the sections lived in files of their own the file's existence answered that;
// with one file it does not, because automatic import writing its section brings the file into being
// for syncing as well.
//
pub const IConfigSectionsPresent = struct {
    //
    // Whether the document carried an `auto_import` section.
    //
    autoImport: bool,

    //
    // Whether the document carried a `sync` section.
    //
    sync: bool,
};


const std = @import("std");
const node_utils = @import("node-utils-zig");
const errors = @import("utils-zig").errors;
const api = @import("api-zig");
const auto_import_settings = api.auto_import_settings;
const IAutoImportSource = auto_import_settings.IAutoImportSource;
const IRawAutoImportSource = auto_import_settings.IRawAutoImportSource;
const IRawAutoImportSettings = auto_import_settings.IRawAutoImportSettings;
const normaliseAutoImportSettings = auto_import_settings.normaliseAutoImportSettings;
const IAutoImportFile = api.auto_import_mobile.IAutoImportFile;
const resolveAutoImportPauseMs = api.auto_import_mobile.resolveAutoImportPauseMs;
const ISyncFile = api.sync_settings.ISyncFile;
const IRawSyncSettings = api.sync_settings.IRawSyncSettings;
const normaliseSyncSettings = api.sync_settings.normaliseSyncSettings;
const resolveSyncPauseMs = api.sync_settings.resolveSyncPauseMs;

//
// The on-disk contents of config.yaml and the conversions between it and the in-memory type.
//
// One file holds every setting the app remembers, on every platform: ~/.config/photosphere/config.yaml
// for the CLI and the desktop app, and config.yaml at the root of the storage sandbox on a phone. One
// file means one format definition, so a setting means the same thing whichever platform wrote it.
// The wiki page "Configuration-File" documents the file for users.
//
// Nothing here touches the filesystem, which is what lets it be bundled into the mobile worker, and
// it is the only definition of the file format, so the reader and the writer cannot drift apart.
//
// This file is what the user chose. What the app remembered on its own, so the interface comes back
// the way it was left, is in state.yaml beside it (see state-format.zig). The two are split because
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
// it is written back, the way a JavaScript number does.)
//

//
// The theme the interface runs with. "system" follows the operating system.
// (Zig: an enum, whose tag names are the strings.)
//
pub const IConfigTheme = enum {
    // A light interface.
    light,

    // A dark interface.
    dark,

    // Follows the operating system.
    system,
};

//
// Everything config.yaml holds, in memory, with camelCase fields.
//
// The auto-import and sync sections are the already-resolved types the rest of the app works with
// (settings plus pacing plus the database path), not raw stored blobs: anything reading this type
// has values that have been through the normalisers.
//
pub const IConfigFile = struct {
    //
    // Which theme the interface uses.
    //
    theme: ?IConfigTheme = null,

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
    // state.yaml, because those the app remembered rather than the user chose.
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
// The themes a config file is allowed to name. A file that says anything else is ignored rather
// than passed through, because the value reaches the interface and picking a stylesheet by a name
// nobody defined leaves a window with no styling at all.
//
pub const ALLOWED_THEMES = [_]IConfigTheme{ .light, .dark, .system };

//
// Gets the object of a value that is one, or null (the optional chaining `value?.key` the TypeScript reads keys with).
// (No TypeScript counterpart.)
//
fn objectOf(value: ?std.json.Value) ?std.json.ObjectMap {
    const present = value orelse {
        return null;
    };
    return if (present == .object) present.object else null;
}

//
// Copies a field of one object into another when the first has it, so a field that is absent stays absent as an
// `undefined` property does in TypeScript. (No TypeScript counterpart.)
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
// (Zig: a source that is null is the TypeError JavaScript throws reading `type` off it, so it throws here with that
// message instead of being dropped; any other value that is not an object has no fields, as in JavaScript.)
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
// Gets a non-empty string field of a section (`typeof section.key === "string" && section.key.length > 0`).
// (No TypeScript counterpart.)
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
// are: a phone that cannot read its settings must not start pushing over a metered connection.
//
// A section that is malformed falls back to that section's own defaults without discarding the
// sections that did parse, and a key nothing recognises is ignored rather than rejected. One
// mistyped line in a hand-edited file must not cost the user every other setting in it.
//
pub fn yamlToConfigFile(allocator: std.mem.Allocator, document: ?std.json.Value) !IConfigFile {
    const parsed: std.json.ObjectMap = if (isSection(document)) document.?.object else .empty;

    var config: IConfigFile = .{
        .autoImport = try yamlToAutoImportFile(allocator, parsed.get("auto_import")),
        .sync = try yamlToSyncFile(allocator, parsed.get("sync")),
    };

    if (parsed.get("theme")) |theme| {
        if (theme == .string) {
            for (ALLOWED_THEMES) |allowedTheme| {
                if (std.mem.eql(u8, theme.string, @tagName(allowedTheme))) {
                    config.theme = allowedTheme;
                }
            }
        }
    }
    if (parsed.get("developer_mode")) |developerMode| {
        if (developerMode == .bool) {
            config.developerMode = developerMode.bool;
        }
    }
    if (parsed.get("show_fps_indicator")) |showFpsIndicator| {
        if (showFpsIndicator == .bool) {
            config.showFpsIndicator = showFpsIndicator.bool;
        }
    }
    if (parsed.get("saved_searches")) |savedSearches| {
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
    if (objectOf(parsed.get("auto_import"))) |autoImport| {
        if (autoImport.get("cleanup_enabled")) |cleanupEnabled| {
            if (cleanupEnabled == .bool) {
                config.autoImportCleanupEnabled = cleanupEnabled.bool;
            }
        }
    }

    return config;
}

//
// Turns the configuration into the document written to disk.
//
// An absent optional field stays absent rather than being written as null, so a file the app wrote
// holds only settings that have actually been chosen, and a reader cannot tell "never set" from
// "explicitly set to nothing" wrongly. An empty sources list is the exception and is written as an
// empty list, because "watching nothing" is a state a user can choose and is not the same as never
// having touched automatic import.
//
pub fn configFileToYaml(allocator: std.mem.Allocator, config: IConfigFile, emit: ?IConfigSectionsPresent) !std.json.Value {
    var sources = std.json.Array.init(allocator);
    for (config.autoImport.settings.sources) |source| {
        try sources.append(try sourceToYaml(allocator, source));
    }
    var autoImport: std.json.ObjectMap = .empty;
    try autoImport.put(allocator, "enabled", .{
        .bool = config.autoImport.settings.enabled,
    });
    try autoImport.put(allocator, "pause_between_runs_ms", config.autoImport.pauseBetweenRunsMs);
    try autoImport.put(allocator, "sources", .{
        .array = sources,
    });
    if (config.autoImport.defaultDatabasePath) |defaultDatabasePath| {
        try autoImport.put(allocator, "default_database_path", .{
            .string = defaultDatabasePath,
        });
    }
    if (config.autoImportCleanupEnabled) |autoImportCleanupEnabled| {
        try autoImport.put(allocator, "cleanup_enabled", .{
            .bool = autoImportCleanupEnabled,
        });
    }

    var sync: std.json.ObjectMap = .empty;
    try sync.put(allocator, "enabled", .{
        .bool = config.sync.settings.enabled,
    });
    try sync.put(allocator, "only_on_wifi", .{
        .bool = config.sync.settings.onlyOnWifi,
    });
    try sync.put(allocator, "pause_between_runs_ms", config.sync.pauseBetweenRunsMs);
    if (config.sync.databasePath) |databasePath| {
        try sync.put(allocator, "database_path", .{
            .string = databasePath,
        });
    }

    var document: std.json.ObjectMap = .empty;

    if (config.theme) |theme| {
        try document.put(allocator, "theme", .{
            .string = @tagName(theme),
        });
    }
    if (config.developerMode) |developerMode| {
        try document.put(allocator, "developer_mode", .{
            .bool = developerMode,
        });
    }
    if (config.showFpsIndicator) |showFpsIndicator| {
        try document.put(allocator, "show_fps_indicator", .{
            .bool = showFpsIndicator,
        });
    }
    if (config.savedSearches) |savedSearches| {
        var searches = std.json.Array.init(allocator);
        for (savedSearches) |search| {
            try searches.append(.{
                .string = search,
            });
        }
        try document.put(allocator, "saved_searches", .{
            .array = searches,
        });
    }

    // A section is written only once its feature has actually been set, so a reader can tell "nobody
    // has chosen this" from "somebody switched it off". Writing every section every time would put an
    // `auto_import` section in the file the moment syncing was switched on, and a fresh install would
    // then be told automatic import had already been decided.
    if (emit == null or emit.?.autoImport) {
        try document.put(allocator, "auto_import", .{
            .object = autoImport,
        });
    }
    if (emit == null or emit.?.sync) {
        try document.put(allocator, "sync", .{
            .object = sync,
        });
    }

    return .{
        .object = document,
    };
}

//
// The configuration a reader falls back to when there is no file, used wherever a caller needs the
// defaults without having a document to convert.
//
pub fn defaultConfigFile(allocator: std.mem.Allocator) !IConfigFile {
    return yamlToConfigFile(allocator, null);
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

//
// Reports which sections a parsed document carried.
//
pub fn sectionsPresent(document: ?std.json.Value) IConfigSectionsPresent {
    if (!isSection(document)) {
        return .{
            .autoImport = false,
            .sync = false,
        };
    }

    return .{
        .autoImport = isSection(document.?.object.get("auto_import")),
        .sync = isSection(document.?.object.get("sync")),
    };
}

//
// The result of parsing a config file: the configuration, and whether the text was readable at all.
//
pub const IParsedConfigFile = struct {
    //
    // The configuration. The defaults when the text could not be parsed.
    //
    config: IConfigFile,

    //
    // True when the text is not valid YAML, so `config` is the defaults rather than anything the
    // file asked for. The caller reports it: a corrupt settings file is a bug somewhere else, and a
    // reader that quietly substituted the defaults would hide it.
    //
    malformed: bool,

    //
    // What the YAML parser said, when it refused the text. Absent otherwise.
    //
    parseError: ?[]const u8 = null,

    //
    // Which sections the document actually carried. Both false for text that would not parse.
    //
    present: IConfigSectionsPresent,

    //
    // The document as it was parsed, before any section was filled in from the defaults. Undefined
    // for an empty file and for text that would not parse.
    //
    // A caller that writes one setting by the name the interface uses needs this rather than the
    // configuration: the flat view has to be able to tell a setting nobody has chosen from one that
    // was switched off, and the configuration has already lost that distinction.
    //
    document: ?std.json.Value = null,
};

//
// Parses the text of a config file, reporting whether it was readable.
//
// Text that will not parse as YAML comes back as the defaults rather than throwing, for the same
// reason an absent file does: this runs on a phone whose only copy of the file may have been
// hand-edited, and refusing to start is a worse answer than starting with syncing switched off. The
// caller is told, so the failure reaches the log instead of being silent.
//
// (Zig: only the YAML parser's own refusal (a thrown YAMLException) is reported as malformed; running out of memory is
// not a parse failure and is returned as the error it is.)
//
pub fn parseConfigYamlChecked(allocator: std.mem.Allocator, text: []const u8) !IParsedConfigFile {
    const loaded = node_utils.yaml.load(allocator, text) catch |err| {
        if (err != error.Thrown) {
            return err;
        }
        return .{
            .config = try defaultConfigFile(allocator),
            .malformed = true,
            .parseError = try errors.errorToString(allocator, err),
            .present = sectionsPresent(null),
        };
    };

    const parsed: ?std.json.Value = if (loaded == .null) null else loaded;
    return .{
        .config = try yamlToConfigFile(allocator, parsed),
        .malformed = false,
        .present = sectionsPresent(parsed),
        .document = if (isSection(parsed)) parsed else null,
    };
}

//
// Parses the text of a config file into the configuration, for a caller with nothing useful to do
// about text that will not parse.
//
pub fn parseConfigYaml(allocator: std.mem.Allocator, text: []const u8) !IConfigFile {
    return (try parseConfigYamlChecked(allocator, text)).config;
}

//
// Renders the configuration as the text of a config file.
//
pub fn buildConfigYaml(allocator: std.mem.Allocator, config: IConfigFile, emit: ?IConfigSectionsPresent) ![]const u8 {
    return node_utils.yaml.dump(allocator, try configFileToYaml(allocator, config, emit));
}

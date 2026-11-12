//
// Reads and writes config.toml as a background task.
//
// The mobile WebView holds these settings but cannot open a file, so its reads and writes run in the
// embedded worker over the storage layer. Putting them in a file rather than in the WebView's own
// store is what lets the background import and the background sync, which run while the app is off
// screen, find out whether they are switched on at all.
//
// One file holds every feature's settings, so a write merges rather than replaces: switching syncing
// on must not wipe what automatic import is watching. Every section the caller does not send is left
// exactly as it was on disk.
//
// The file contents come from config-format.zig, the same module every reader converts through, so a
// file written here is readable by anything else that opens it by construction.
//
// (Zig: the settings a write sends are the std.json.Value they arrive as, and are turned into the typed settings by
// normaliseAutoImportSettings and normaliseSyncSettings, because the configuration holds typed settings. The task data
// and output are JSON values.)
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const Timers = @import("ziggy").timers.Timers;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const config_format = @import("config-format.zig");
const app_config_format = @import("app-config-format.zig");
const errors = utils.errors;
const FileStorage = storage_zig.file_storage.FileStorage;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const normaliseAutoImportSettings = api.auto_import_settings.normaliseAutoImportSettings;
const autoImportSettingsToJson = api.auto_import_settings.autoImportSettingsToJson;
const autoImportSourcesToJson = api.auto_import_settings.autoImportSourcesToJson;
const normaliseAutoImportSource = api.auto_import_settings.normaliseAutoImportSource;
const resolveAutoImportPauseMs = api.auto_import_mobile.resolveAutoImportPauseMs;
const normaliseSyncSettings = api.sync_settings.normaliseSyncSettings;
const resolveSyncPauseMs = api.sync_settings.resolveSyncPauseMs;
const IAutoImportFile = api.auto_import_mobile.IAutoImportFile;
const ISyncFile = api.sync_settings.ISyncFile;
const IConfigFile = config_format.IConfigFile;
const IConfigSectionsPresent = config_format.IConfigSectionsPresent;
const defaultConfigFile = config_format.defaultConfigFile;
const IAppConfig = app_config_format.IAppConfig;
const IAppConfigValue = app_config_format.IAppConfigValue;
const appConfigSettings = app_config_format.appConfigSettings;
const setAppConfigValue = app_config_format.setAppConfigValue;
const config_file = @import("config-file.zig");
const app_config = @import("app-config.zig");
const config_state = @import("ziggy").config_state;

//
// Input for the read-config task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses.)
//
pub const IReadConfigData = struct {
    // Sandbox-relative path of config.toml.
    configPath: []const u8 = "",
};

//
// The automatic import part of a write, sent only when the caller is changing it.
// (Zig: the settings are a std.json.Value; the defaults let std.json parse data that leaves keys out.)
//
pub const IWriteConfigAutoImport = struct {
    // The settings to write.
    settings: ?std.json.Value = null,

    // The database automatic import writes to, or undefined when none has been chosen yet.
    defaultDatabasePath: ?[]const u8 = null,

    // The gap between background import passes, in milliseconds (a number value).
    pauseBetweenRunsMs: ?std.json.Value = null,
};

//
// The syncing part of a write, sent only when the caller is changing it.
// (Zig: the settings are a std.json.Value; the defaults let std.json parse data that leaves keys out.)
//
pub const IWriteConfigSync = struct {
    // The settings to write.
    settings: ?std.json.Value = null,

    // The database the background sync pushes, or undefined when none has been opened yet.
    databasePath: ?[]const u8 = null,

    // The gap between background sync passes, in milliseconds (a number value).
    pauseBetweenRunsMs: ?std.json.Value = null,
};

//
// One flat key the caller is changing.
//
// A missing `value` clears the key, which is what IConfig.clear means, and is not the same as the
// entry not being sent at all. The two have to be told apart because the entry crosses the bridge to
// the phone as JSON, where an undefined property simply disappears: a caller that meant "clear this"
// would arrive looking like a caller that meant nothing, so the key would be left as it was.
// (Zig: the value is the std.json.Value it arrives as. A null value clears the key, as an absent one does.)
//
pub const IWriteConfigEntry = struct {
    // The flat key the interface uses.
    key: []const u8 = "",

    // What to store under it. Absent clears the key.
    value: ?std.json.Value = null,
};

//
// Input for the write-config task.
//
// Every part is optional, and a part that is absent is left as it is on disk. That is what keeps two
// features that are switched on separately from overwriting each other now they share a file: the
// settings card writes the one section the user touched.
//
pub const IWriteConfigData = struct {
    // Sandbox-relative path of config.toml.
    configPath: []const u8 = "",

    // The automatic import settings, when they are what is being changed.
    autoImport: ?IWriteConfigAutoImport = null,

    // The syncing settings, when they are what is being changed.
    sync: ?IWriteConfigSync = null,

    // The flat keys being changed, each written where this file keeps it.
    entries: ?[]const IWriteConfigEntry = null,
};

//
// What reading the file gives back: the settings, and which sections were in it.
//
pub const IConfigRead = struct {
    // The settings, filled from the defaults for anything the file did not say.
    config: IConfigFile,

    // Which sections the file carried. A caller needs this to tell a section nobody has
    // written from one that has been switched off, because both read as switched off.
    present: IConfigSectionsPresent,
};

//
// Reads the config file through storage, which is how it is reached on a device.
//
// A file that is not there, and one that will not parse, both come back as the defaults rather than
// throwing, which for these settings means both loops switched off. This file is written by the app
// and never shown to the user, so a corrupt copy is a bug somewhere else, and throwing here would
// take the settings card that could fix it down with it. The parse failure is logged so it is not
// silent.
//
pub fn readConfig(allocator: std.mem.Allocator, io: std.Io, log: ILog, config_path: []const u8) !IConfigRead {
    return .{
        .config = try config_file.loadConfigFile(allocator, io, log, config_path),
        .present = .{
            .autoImport = try config_state.config.has(allocator, io, config_path, "auto_import"),
            .sync = try config_state.config.has(allocator, io, config_path, "sync"),
        },
    };
}

//
// Turns the value of a flat config key into the JSON it crosses the bridge as.
//
fn configValueToJson(allocator: std.mem.Allocator, value: IAppConfigValue) !std.json.Value {
    return switch (value) {
        .boolean => |boolean| .{
            .bool = boolean,
        },
        .number => |number| number,
        .string => |text| .{
            .string = text,
        },
        .strings => |strings| blk: {
            var array = std.json.Array.init(allocator);
            for (strings) |text| {
                try array.append(.{
                    .string = text,
                });
            }
            break :blk .{
                .array = array,
            };
        },
        .sources => |sources| try autoImportSourcesToJson(allocator, sources),
    };
}

//
// Turns the JSON a write sent for a flat config key into the value the key holds.
// (A list of objects is the watched places when the key is the one that holds them, and a list of text otherwise.)
//
fn configValueFromJson(allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !IAppConfigValue {
    switch (value) {
        .bool => |boolean| return .{
            .boolean = boolean,
        },
        .string => |text| return .{
            .string = text,
        },
        .integer, .float, .number_string => return .{
            .number = value,
        },
        .array => |array| {
            if (std.mem.eql(u8, key, "autoImportSources")) {
                var sources: std.ArrayList(IAutoImportSource) = .empty;
                for (array.items) |item| {
                    const source = normaliseAutoImportSource(item) orelse {
                        return errors.throwError("The config setting \"{s}\" was given a place to watch that is not a folder or a device album.", .{key});
                    };
                    try sources.append(allocator, source);
                }
                return .{
                    .sources = sources.items,
                };
            }
            var strings: std.ArrayList([]const u8) = .empty;
            for (array.items) |item| {
                if (item != .string) {
                    return errors.throwError("The config setting \"{s}\" was given a list that holds something other than text.", .{key});
                }
                try strings.append(allocator, item.string);
            }
            return .{
                .strings = strings.items,
            };
        },
        else => return errors.throwError("The config setting \"{s}\" cannot hold that kind of value.", .{key}),
    }
}

//
// Builds the JSON object of the automatic import part of the configuration, as the read-config task returns it.
//
fn autoImportFileToJson(allocator: std.mem.Allocator, autoImport: IAutoImportFile) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "settings", try autoImportSettingsToJson(allocator, autoImport.settings));
    if (autoImport.defaultDatabasePath) |defaultDatabasePath| {
        try object.put(allocator, "defaultDatabasePath", .{
            .string = defaultDatabasePath,
        });
    }
    try object.put(allocator, "pauseBetweenRunsMs", autoImport.pauseBetweenRunsMs);
    return .{
        .object = object,
    };
}

//
// Builds the JSON object of the syncing part of the configuration, as the read-config task returns it.
//
fn syncFileToJson(allocator: std.mem.Allocator, sync: ISyncFile) !std.json.Value {
    var settings: std.json.ObjectMap = .empty;
    try settings.put(allocator, "enabled", .{
        .bool = sync.settings.enabled,
    });
    try settings.put(allocator, "onlyOnWifi", .{
        .bool = sync.settings.onlyOnWifi,
    });

    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "settings", .{
        .object = settings,
    });
    if (sync.databasePath) |databasePath| {
        try object.put(allocator, "databasePath", .{
            .string = databasePath,
        });
    }
    try object.put(allocator, "pauseBetweenRunsMs", sync.pauseBetweenRunsMs);
    return .{
        .object = object,
    };
}

//
// Handler for the read-config task.
// (Zig: the context's config path is used when it has one, because a device's app cannot name its own absolute path; the task
// data's path is used otherwise, which is what a test does.)
//
pub fn readConfigHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    log: utils.log.ILog,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when configPath is not a string.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IReadConfigData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The read-config task data is not valid: configPath must be a string", .{});
    };
    const config_path = if (context.configPath.len > 0) context.configPath else data.configPath;
    if (config_path.len == 0) {
        return errors.throwError("configPath is required", .{});
    }

    const contents = try readConfig(allocator, io, log, config_path);

    var settingsObject: std.json.ObjectMap = .empty;
    var settings = try appConfigSettings(allocator, try app_config.loadAppConfig(allocator, io, log, config_path));
    var settingsIterator = settings.iterator();
    while (settingsIterator.next()) |entry| {
        try settingsObject.put(allocator, entry.key_ptr.*, try configValueToJson(allocator, entry.value_ptr.*));
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "autoImport", try autoImportFileToJson(allocator, contents.config.autoImport));
    try result.put(allocator, "sync", try syncFileToJson(allocator, contents.config.sync));
    try result.put(allocator, "syncSettingsWritten", .{
        .bool = contents.present.sync,
    });
    try result.put(allocator, "autoImportSettingsWritten", .{
        .bool = contents.present.autoImport,
    });
    try result.put(allocator, "settings", .{
        .object = settingsObject,
    });
    return .{
        .object = result,
    };
}

//
// Handler for the write-config task.
//
// A read-modify-write: it reads what is on disk, replaces only the sections the caller sent, and
// writes the whole document back. Reading first is what keeps the sections nobody touched, including
// the ones this task has no notion of at all.
// (Zig: the context's config path is used when it has one, as the read-config handler uses it. The
// task data is a JSON value holding IWriteConfigData, and the handler returns null.)
//
pub fn writeConfigHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    log: utils.log.ILog,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when a field has the wrong type.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IWriteConfigData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The write-config task data is not valid: configPath must be a string, and autoImport, sync and entries must hold their parts", .{});
    };
    const config_path = if (context.configPath.len > 0) context.configPath else data.configPath;
    if (config_path.len == 0) {
        return errors.throwError("configPath is required", .{});
    }
    if (data.autoImport == null and data.sync == null and data.entries == null) {
        return errors.throwError("write-config was given no autoImport section, no sync section and no settings to write, so there is nothing to write.", .{});
    }

    // The sections the caller gave are normalised as they always were, and each entry is checked against the settings the app knows
    // before anything is written, so a failure writes none of it.
    var auto_import: ?IAutoImportFile = null;
    var auto_import_pause: ?std.json.Value = null;
    if (data.autoImport) |given| {
        const settings = given.settings orelse {
            return errors.throwError("autoImport.settings is required", .{});
        };
        auto_import = .{
            .settings = try normaliseAutoImportSettings(allocator, settings),
            .defaultDatabasePath = given.defaultDatabasePath,
            .pauseBetweenRunsMs = resolveAutoImportPauseMs(given.pauseBetweenRunsMs),
        };
        auto_import_pause = given.pauseBetweenRunsMs;
    }
    var sync: ?ISyncFile = null;
    var sync_pause: ?std.json.Value = null;
    if (data.sync) |given| {
        const settings = given.settings orelse {
            return errors.throwError("sync.settings is required", .{});
        };
        sync = .{
            .settings = normaliseSyncSettings(settings),
            .databasePath = given.databasePath,
            .pauseBetweenRunsMs = resolveSyncPauseMs(given.pauseBetweenRunsMs),
        };
        sync_pause = given.pauseBetweenRunsMs;
    }
    if (data.entries) |entries| {
        var checked = try app_config.loadAppConfig(allocator, io, log, config_path);
        for (entries) |entry| {
            if (entry.key.len == 0) {
                return errors.throwError("write-config was given a setting with no key.", .{});
            }
            const value: ?IAppConfigValue = if (entry.value) |entryValue| (if (entryValue == .null) null else try configValueFromJson(allocator, entry.key, entryValue)) else null;
            try setAppConfigValue(&checked, entry.key, value);
        }
    }

    const change = WriteConfigChange{
        .autoImport = auto_import,
        .autoImportPause = auto_import_pause,
        .sync = sync,
        .syncPause = sync_pause,
        .entries = data.entries,
    };
    try config_state.config.update(allocator, io, config_path, change);
    return .null;
}

//
// The change writeConfigHandler runs: each section it was given, each pause it was given and each setting entry, in one rename.
//
const WriteConfigChange = struct {
    // The automatic import section to write, or null to leave it as it is.
    autoImport: ?IAutoImportFile,
    // The automatic import pause the caller gave, or null to leave it as it is.
    autoImportPause: ?std.json.Value,
    // The sync section to write, or null to leave it as it is.
    sync: ?ISyncFile,
    // The sync pause the caller gave, or null to leave it as it is.
    syncPause: ?std.json.Value,
    // The flat settings to write, or null for none.
    entries: ?[]const IWriteConfigEntry,

    //
    // Writes every key, so a reader sees all of the change or none of it.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: config_state.config.Values) !void {
        if (self.autoImport) |auto_import| {
            try values.set("auto_import.enabled", auto_import.settings.enabled);
            try values.set("auto_import.sources", try config_format.autoImportSourcesToStored(arena, auto_import.settings.sources));
            try values.set("auto_import.default_database_path", auto_import.defaultDatabasePath);
            if (self.autoImportPause) |pause| {
                try config_format.setPause(values, "auto_import.pause_between_runs_ms", pause);
            }
        }
        if (self.sync) |sync| {
            try values.set("sync.enabled", sync.settings.enabled);
            try values.set("sync.only_on_wifi", sync.settings.onlyOnWifi);
            try values.set("sync.database_path", sync.databasePath);
            if (self.syncPause) |pause| {
                try config_format.setPause(values, "sync.pause_between_runs_ms", pause);
            }
        }
        if (self.entries) |entries| {
            for (entries) |entry| {
                if (entry.key.len == 0) {
                    return errors.throwError("write-config was given a setting with no key.", .{});
                }
                var one: IAppConfig = .{};
                const value: ?IAppConfigValue = if (entry.value) |entryValue| (if (entryValue == .null) null else try configValueFromJson(arena, entry.key, entryValue)) else null;
                try setAppConfigValue(&one, entry.key, value);
                inline for (std.meta.fields(IAppConfig)) |field| {
                    if (std.mem.eql(u8, field.name, entry.key)) {
                        try app_config.setAppConfigIn(field.name, values, @field(one, field.name));
                    }
                }
            }
        }
    }
};

//
// Re-exported from the format module so a host-side script can produce a file the read handler reads
// back exactly, which is how a mobile smoke test establishes settings from outside the app.
//

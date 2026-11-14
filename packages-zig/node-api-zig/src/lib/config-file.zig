const std = @import("std");
const node_utils = @import("node-utils-zig");
const config_format = @import("config-format.zig");
const fs = node_utils.fs;
const ziggy = @import("ziggy");
const ILog = @import("utils-zig").log.ILog;
const IConfigFile = config_format.IConfigFile;

//
// One setting of one config file, as a struct so that the path and the key path cannot be swapped.
//
pub const ISettingTarget = struct {
    // The config file's path.
    configPath: []const u8,
    // The dotted key path of the setting.
    keyPath: []const u8,
};

//
// Reading and writing config.toml where there is a filesystem: the CLI and the desktop app.
//
// The mobile apps read and write the same document through worker tasks instead (config.worker.zig),
// because a mobile's WebView has no filesystem of its own. Both go through config-format.zig, so the
// file means the same thing whichever wrote it. The wiki page "Configuration-File" documents it for
// users.
//

//
// Reads one setting through the typed API. A value of the wrong type in a hand-edited file is logged, and the setting is given its
// default; every other error is returned.
//
pub fn readSetting(comptime T: type, arena: std.mem.Allocator, io: std.Io, log: ILog, target: ISettingTarget) !T {
    comptime {
        if (@typeInfo(T) != .optional) {
            @compileError("readSetting reads an optional type, so a bad setting can be told apart from an absent one.");
        }
    }
    return ziggy.config_state.config.get(T, arena, io, target.configPath, target.keyPath) catch |err| switch (err) {
        error.SettingWrongType => {
            log.@"error"(ziggy.utils.errors.lastErrorMessage());
            log.@"error"("The setting is at its default.");
            return null;
        },
        else => return err,
    };
}

//
// Loads the configuration from disk, returning the defaults when there is no file yet. Every key is read on its own, so one value of
// the wrong type gives only its own setting its default.
//
pub fn loadConfigFile(allocator: std.mem.Allocator, io: std.Io, log: ILog, config_path: []const u8) !IConfigFile {
    const loaded_sync = config_format.IStoredSyncSection{
        .enabled = try readSetting(?bool, allocator, io, log, .{ .configPath = config_path, .keyPath = "sync.enabled" }),
        .only_on_wifi = try readSetting(?bool, allocator, io, log, .{ .configPath = config_path, .keyPath = "sync.only_on_wifi" }),
        .database_path = try readSetting(?[]const u8, allocator, io, log, .{ .configPath = config_path, .keyPath = "sync.database_path" }),
        .pause_between_runs_ms = try readSetting(?f64, allocator, io, log, .{ .configPath = config_path, .keyPath = "sync.pause_between_runs_ms" }),
    };
    const loaded_auto_import = config_format.IStoredAutoImportSection{
        .enabled = try readSetting(?bool, allocator, io, log, .{ .configPath = config_path, .keyPath = "auto_import.enabled" }),
        .default_database_path = try readSetting(?[]const u8, allocator, io, log, .{ .configPath = config_path, .keyPath = "auto_import.default_database_path" }),
        .pause_between_runs_ms = try readSetting(?f64, allocator, io, log, .{ .configPath = config_path, .keyPath = "auto_import.pause_between_runs_ms" }),
        .cleanup_enabled = try readSetting(?bool, allocator, io, log, .{ .configPath = config_path, .keyPath = "auto_import.cleanup_enabled" }),
        .sources = try readSetting(?[]const config_format.IStoredAutoImportSource, allocator, io, log, .{ .configPath = config_path, .keyPath = "auto_import.sources" }),
    };
    return .{
        .developerMode = try readSetting(?bool, allocator, io, log, .{ .configPath = config_path, .keyPath = "developer_mode" }),
        .showFpsIndicator = try readSetting(?bool, allocator, io, log, .{ .configPath = config_path, .keyPath = "show_fps_indicator" }),
        .savedSearches = try readSetting(?[]const []const u8, allocator, io, log, .{ .configPath = config_path, .keyPath = "saved_searches" }),
        .autoImport = try config_format.autoImportFileFromStored(allocator, loaded_auto_import),
        .autoImportCleanupEnabled = loaded_auto_import.cleanup_enabled,
        .sync = config_format.syncFileFromStored(allocator, loaded_sync),
    };
}

//
// Writes every setting in one update, so the whole configuration lands in one rename and a reader sees all of it or none of it.
//
pub fn saveConfigFile(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, config: IConfigFile) !void {
    try ziggy.config_state.config.update(allocator, io, config_path, SaveConfigChange{ .config = config });
}

//
// The change saveConfigFile runs: one set per leaf key.
//
const SaveConfigChange = struct {
    // The configuration to write.
    config: IConfigFile,

    //
    // Writes every key.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: ziggy.config_state.config.Values) !void {
        try values.set("developer_mode", self.config.developerMode);
        try values.set("show_fps_indicator", self.config.showFpsIndicator);
        try values.set("saved_searches", self.config.savedSearches);
        const sync = self.config.sync;
        try values.set("sync.enabled", sync.settings.enabled);
        try values.set("sync.only_on_wifi", sync.settings.onlyOnWifi);
        try values.set("sync.database_path", sync.databasePath);
        try config_format.setPause(values, "sync.pause_between_runs_ms", sync.pauseBetweenRunsMs);
        const auto_import = self.config.autoImport;
        try values.set("auto_import.enabled", auto_import.settings.enabled);
        try values.set("auto_import.default_database_path", auto_import.defaultDatabasePath);
        try config_format.setPause(values, "auto_import.pause_between_runs_ms", auto_import.pauseBetweenRunsMs);
        try values.set("auto_import.cleanup_enabled", self.config.autoImportCleanupEnabled);
        const stored_sources = (try config_format.autoImportSourcesToStored(arena, auto_import.settings.sources)) orelse &[_]config_format.IStoredAutoImportSource{};
        try values.set("auto_import.sources", stored_sources);
    }
};

//
// The configuration a reader falls back to when there is no file. Re-exported so callers that only
// deal with the file do not have to reach into the format module for it.
//
pub const defaultConfigFile = config_format.defaultConfigFile;


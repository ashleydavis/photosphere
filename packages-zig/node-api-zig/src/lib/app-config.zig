const std = @import("std");
const node_utils = @import("node-utils-zig");
const config_file = @import("config-file.zig");
const app_config_format = @import("app-config-format.zig");
const config_format = @import("config-format.zig");
const fs = node_utils.fs;
const IConfigTheme = config_format.IConfigTheme;

//
// The config store the shared UI reads and writes through, backed by config.toml.
//
// `IConfig` in user-interface offers get, set, add, remove and clear over a string key, and this is
// what backs it: the settings the user chose. What the app remembered is the sibling store in
// app-state.zig, reached through its own context, so nothing anywhere has to work out which of the two
// a key belongs to.
//
// What the keys mean is not decided here. app-config-format.zig owns that, and is where the flat view
// and its conversions live, so the phone's worker can be handed the same definition without dragging
// the filesystem in with it. This module is the file half: loading it, and changing it. Everything
// there is re-exported from here so a caller that wants both does not have to know they are two
// modules.
//

// Re-exported from app-config-format.zig (`export * from "./app-config-format"`). (Zig: each public declaration is named,
// because Zig has no re-export of a whole module.)
pub const IAppConfig = app_config_format.IAppConfig;
pub const IAppConfigValue = app_config_format.IAppConfigValue;
pub const IAppConfigSettings = app_config_format.IAppConfigSettings;
pub const getAppConfigValue = app_config_format.getAppConfigValue;
pub const setAppConfigValue = app_config_format.setAppConfigValue;
pub const appConfigSettings = app_config_format.appConfigSettings;
pub const APP_CONFIG_PATHS = app_config_format.APP_CONFIG_PATHS;
pub const getAppConfig = app_config_format.getAppConfig;
pub const setAppConfig = app_config_format.setAppConfig;

const config_state = @import("ziggy").config_state;
const ILog = @import("utils-zig").log.ILog;

//
// Loads the whole store from disk. Every key is read on its own, so one value of the wrong type gives only its own setting its default.
// Returns an empty config when the file does not exist, so every setting falls to its own default.
//
pub fn loadAppConfig(allocator: std.mem.Allocator, io: std.Io, log: ILog, config_path: []const u8) !IAppConfig {
    var config: IAppConfig = .{};
    inline for (std.meta.fields(IAppConfig)) |field| {
        const path = @field(APP_CONFIG_PATHS, field.name);
        if (comptime std.mem.eql(u8, field.name, "autoImportSources")) {
            const stored = try config_file.readSetting(?[]const config_format.IStoredAutoImportSource, allocator, io, log, .{ .configPath = config_path, .keyPath = path });
            @field(config, field.name) = try config_format.autoImportSourcesFromStored(allocator, stored);
        }
        else {
            @field(config, field.name) = try config_file.readSetting(field.type, allocator, io, log, .{ .configPath = config_path, .keyPath = path });
        }
    }
    return config;
}

//
// Writes one field of IAppConfig inside an update another change is making, so several settings land in one rename.
//
pub fn setAppConfigIn(comptime field_name: []const u8, values: config_state.config.Values, value: @FieldType(IAppConfig, field_name)) !void {
    const path = @field(APP_CONFIG_PATHS, field_name);
    if (comptime std.mem.eql(u8, field_name, "autoImportSources")) {
        const stored = try config_format.autoImportSourcesToStored(values.arena(), value);
        try values.set(path, stored);
        return;
    }
    try values.set(path, value);
}

//
// Gets the theme preference. A string naming a theme nobody defined is logged and gives the system theme, as a missing setting does.
//
pub fn getTheme(allocator: std.mem.Allocator, io: std.Io, log: ILog, config_path: []const u8) !IConfigTheme {
    const theme = try config_file.readSetting(?IConfigTheme, allocator, io, log, .{ .configPath = config_path, .keyPath = "theme" });
    return theme orelse .system;
}

//
// Sets the theme preference.
//
pub fn setTheme(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, theme: IConfigTheme) !void {
    try config_state.config.set(allocator, io, config_path, "theme", theme);
}

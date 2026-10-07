const std = @import("std");
const node_utils = @import("node-utils-zig");
const config_file = @import("config-file.zig");
const app_config_format = @import("app-config-format.zig");
const config_format = @import("config-format.zig");
const fs = node_utils.fs;
const getConfigPath = config_file.getConfigPath;
const IConfigTheme = config_format.IConfigTheme;

//
// The config store the shared UI reads and writes through, backed by config.yaml.
//
// `IConfig` in user-interface offers get, set, add, remove and clear over a string key, and this is
// what backs it: the settings the user chose. What the app remembered is the sibling store in
// app-state.ts, reached through its own context, so nothing anywhere has to work out which of the two
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
pub const yamlToAppConfig = app_config_format.yamlToAppConfig;
pub const appConfigToYaml = app_config_format.appConfigToYaml;
pub const getAppConfigValue = app_config_format.getAppConfigValue;
pub const setAppConfigValue = app_config_format.setAppConfigValue;
pub const appConfigSettings = app_config_format.appConfigSettings;

//
// Loads the whole store from disk.
// Returns an empty config when the file does not exist, so every setting falls to its own default.
//
pub fn loadAppConfig(allocator: std.mem.Allocator, io: std.Io) !IAppConfig {
    const document = try fs.readYaml(allocator, io, try getConfigPath(allocator));
    return yamlToAppConfig(allocator, document);
}

//
// The mutator updateAppConfig hands to updateYaml (the arrow function in TypeScript): it turns the document into the
// flat config, lets the caller change it and merges it back into the document.
//
fn AppConfigMutator(comptime MutatorT: type) type {
    return struct {
        // The caller's mutator.
        mutator: MutatorT,

        //
        // Applies the caller's mutator to the flat config the document holds.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, document: std.json.Value) !std.json.Value {
            var config = try yamlToAppConfig(allocator, document);
            try self.mutator.run(allocator, &config);
            return appConfigToYaml(allocator, config, document);
        }
    };
}

//
// Changes the store on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// This is the only way to write the file. A saveDesktopConfig that took a whole config and wrote it
// used to sit beside this, and its callers were all load-then-save, so an edit made between their
// read and their write was silently discarded. Windows made the same overlap visible on the sibling
// databases.toml, where it refuses to rename over a file another handle still holds.
//
// In Zig the mutator is a value with a method `run(self, allocator, config: *IAppConfig) !void`.
//
pub fn updateAppConfig(allocator: std.mem.Allocator, io: std.Io, mutator: anytype) !void {
    const appConfigMutator: AppConfigMutator(@TypeOf(mutator)) = .{
        .mutator = mutator,
    };
    try fs.updateYaml(allocator, io, try getConfigPath(allocator), .{
        .object = .empty,
    }, &appConfigMutator, 3);
}

//
// Gets the theme preference.
//
pub fn getTheme(allocator: std.mem.Allocator, io: std.Io) !IConfigTheme {
    const config = try loadAppConfig(allocator, io);
    return config.theme orelse .system;
}

//
// The mutator setTheme hands to updateAppConfig (the arrow function in TypeScript). (No TypeScript counterpart.)
//
const SetThemeMutator = struct {
    // The theme to store.
    theme: IConfigTheme,

    //
    // Stores the theme in the config.
    //
    pub fn run(self: SetThemeMutator, allocator: std.mem.Allocator, config: *IAppConfig) !void {
        _ = allocator;
        config.theme = self.theme;
    }
};

//
// Sets the theme preference.
//
pub fn setTheme(allocator: std.mem.Allocator, io: std.Io, theme: IConfigTheme) !void {
    try updateAppConfig(allocator, io, SetThemeMutator{
        .theme = theme,
    });
}

//
// The channels the page reads and writes its settings and its remembered state through: get-config and set-config (config.yaml, what the
// user chose), and get-state and set-state (state.yaml, what the
// app remembered), from the ipcMain handlers of the same names in apps/desktop/src/main.ts.
//
// Each is a task type, because it reads or writes a file.
//
// The page sends a value as JSON, where Electron's structured clone carried it as it was: setting a key to null (or leaving the value
// out) removes it, which is what `undefined` did.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const app_state = node_api.app_state;
const app_config = node_api.app_config;
const auto_import_settings = @import("api-zig").auto_import_settings;
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const main_process = @import("main-process.zig");

//
// get-state: the payload is a state key. The reply is the value remembered under it, or null when there is none.
//
pub fn getStateHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The state request needs the name of a key.", .{});
    }
    const state = try app_state.loadAppState(context.arena, context.io());
    const value = try app_state.getAppStateValue(context.arena, state, data.string);
    return try json_util.stringify(context.arena, value);
}

//
// The change set-state makes to the state: one key set to a value, or removed.
//
const SetStateMutator = struct {
    // The key to write.
    key: []const u8,
    // The value to store, or null to remove the key.
    value: ?std.json.Value,

    //
    // Writes the key into the state, which is the file's current contents.
    //
    pub fn run(self: *const SetStateMutator, allocator: std.mem.Allocator, state: *app_state.IAppState) !void {
        try app_state.setAppStateValue(allocator, state, self.key, self.value);
    }
};

//
// set-state: the payload is {key, value}. Writes the value under the key in state.yaml, or removes the key when the value is null or
// left out. Nothing here reacts to a particular key the way set-config does: the theme and the automatic import settings are the
// user's, and this file holds nothing anything else has to be told about. The reply is null.
//
pub fn setStateHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const key = json_util.getString(data, "key") orelse {
        return utils.errors.throwError("The state request needs the name of a key.", .{});
    };
    const value: ?std.json.Value = if (data.object.get("value")) |present| (if (present == .null) null else present) else null;
    const mutator: SetStateMutator = .{
        .key = key,
        .value = value,
    };
    try app_state.updateAppState(context.arena, context.io(), &mutator);
    return try context.arena.dupe(u8, "null");
}

//
// The config keys that change what automatic import should be doing, so writing one restarts it (AUTO_IMPORT_CONFIG_KEYS of main.ts).
//
const AUTO_IMPORT_CONFIG_KEYS = [_][]const u8{
    "autoImportEnabled",
    "autoImportSources",
    "autoImportCleanupEnabled",
    "defaultDatabasePath",
};

//
// Turns a value from the page into the value a config key holds. (No TypeScript counterpart: Electron carried the JavaScript value
// as it was.) A number, which no config key holds at present, is kept as the JSON number it is.
//
fn configValueFromJson(arena: std.mem.Allocator, key: []const u8, value: std.json.Value) !app_config.IAppConfigValue {
    switch (value) {
        .bool => |boolean| return .{ .boolean = boolean },
        .string => |text| return .{ .string = text },
        .integer, .float, .number_string => return .{ .number = value },
        .array => |array| {
            if (std.mem.eql(u8, key, "autoImportSources")) {
                var sources: std.ArrayList(auto_import_settings.IAutoImportSource) = .empty;
                for (array.items) |item| {
                    const source = auto_import_settings.normaliseAutoImportSource(item) orelse {
                        return utils.errors.throwError("The config setting \"{s}\" was given a place to watch that is not a folder or a device album.", .{key});
                    };
                    try sources.append(arena, source);
                }
                return .{ .sources = sources.items };
            }
            var strings: std.ArrayList([]const u8) = .empty;
            for (array.items) |item| {
                if (item != .string) {
                    return utils.errors.throwError("The config setting \"{s}\" was given a list that holds something other than text.", .{key});
                }
                try strings.append(arena, item.string);
            }
            return .{ .strings = strings.items };
        },
        else => return utils.errors.throwError("The config setting \"{s}\" cannot hold that kind of value.", .{key}),
    }
}

//
// Turns the value of a config key into the JSON the page is sent. (No TypeScript counterpart.)
//
fn configValueToJson(arena: std.mem.Allocator, value: ?app_config.IAppConfigValue) ![]const u8 {
    const present = value orelse {
        return try arena.dupe(u8, "null");
    };
    return switch (present) {
        .boolean => |boolean| try json_util.stringify(arena, boolean),
        .number => |number| try json_util.stringify(arena, number),
        .string => |text| try json_util.stringify(arena, text),
        .strings => |strings| try json_util.stringify(arena, strings),
        .sources => |sources| try json_util.stringify(arena, try auto_import_settings.autoImportSourcesToJson(arena, sources)),
    };
}

//
// get-config: the payload is a config key. The reply is the setting the user chose under it, from config.yaml, or null when there is
// none.
//
pub fn getConfigHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The config request needs the name of a key.", .{});
    }
    const config = try app_config.loadAppConfig(context.arena, context.io());
    return try configValueToJson(context.arena, app_config.getAppConfigValue(config, data.string));
}

//
// The change set-config makes to the config: one key set to a value, or removed.
//
const SetConfigMutator = struct {
    // The key to write.
    key: []const u8,
    // The value to store, or null to remove the key.
    value: ?app_config.IAppConfigValue,

    //
    // Writes the key into the config, which is the file's current contents.
    //
    pub fn run(self: *const SetConfigMutator, allocator: std.mem.Allocator, config: *app_config.IAppConfig) !void {
        _ = allocator;
        try app_config.setAppConfigValue(config, self.key, self.value);
    }
};

//
// set-config: the payload is {key, value}. Writes the setting to config.yaml, or removes it when the value is null or left out. A change
// of theme is announced to the page (the `theme-changed` event), so the menu bar can follow, and a change to a setting that decides what
// automatic import does takes effect now rather than at the next start. The reply is null.
//
pub fn setConfigHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const key = json_util.getString(data, "key") orelse {
        return utils.errors.throwError("The config request needs the name of a key.", .{});
    };
    const json_value: ?std.json.Value = if (data.object.get("value")) |present| (if (present == .null) null else present) else null;
    const value: ?app_config.IAppConfigValue = if (json_value) |present| try configValueFromJson(arena, key, present) else null;
    const mutator: SetConfigMutator = .{
        .key = key,
        .value = value,
    };
    try app_config.updateAppConfig(arena, context.io(), &mutator);
    // Keep the theme-changed event so the menu bar can react to theme changes.
    if (std.mem.eql(u8, key, "theme")) {
        try events.sendThemeChanged(main_state.fromContext(context).core, arena, if (value) |present| present.string else null);
    }
    // Switching automatic import on or off, or changing what it watches, takes effect now rather than at the next restart. The main
    // process reads the same config the page just wrote, so this needs no channel of its own.
    for (AUTO_IMPORT_CONFIG_KEYS) |auto_import_key| {
        if (std.mem.eql(u8, key, auto_import_key)) {
            try main_process.ensureAutoImport(context);
            break;
        }
    }
    return try arena.dupe(u8, "null");
}

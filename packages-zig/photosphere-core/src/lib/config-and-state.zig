//
// The messages the page reads and writes its settings and its remembered state through: get-config and set-config (config.yaml, what the
// user chose), and get-state and set-state (state.yaml, what the
// app remembered).
//
// Each is a task type, because it reads or writes a file.
//
// The page sends a value as JSON: setting a key to null (or leaving the value
// out) removes it.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json = ziggy.json;
const app_state = node_api.app_state;
const app_config = node_api.app_config;
const auto_import_settings = @import("api-zig").auto_import_settings;
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const main_process = @import("main-process.zig");
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// get-state: the payload is a state key. The reply is the value remembered under it, or null when there is none.
//
fn getState(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The state request needs the name of a key.", .{});
    }
    const state = try app_state.loadAppState(context.arena, context.io());
    const value = try app_state.getAppStateValue(context.arena, state, data.string);
    return try json.stringify(context.arena, value);
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
fn setState(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const key = json.getString(data, "key") orelse {
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
// The config keys that change what automatic import should be doing, so writing one restarts it.
//
const AUTO_IMPORT_CONFIG_KEYS = [_][]const u8{
    "autoImportEnabled",
    "autoImportSources",
    "autoImportCleanupEnabled",
    "defaultDatabasePath",
};

//
// Turns a value from the page into the value a config key holds. A number, which no config key holds at present, is kept as the JSON number it is.
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
// Turns the value of a config key into the JSON the page is sent.
//
fn configValueToJson(arena: std.mem.Allocator, value: ?app_config.IAppConfigValue) ![]const u8 {
    const present = value orelse {
        return try arena.dupe(u8, "null");
    };
    return switch (present) {
        .boolean => |boolean| try json.stringify(arena, boolean),
        .number => |number| try json.stringify(arena, number),
        .string => |text| try json.stringify(arena, text),
        .strings => |strings| try json.stringify(arena, strings),
        .sources => |sources| try json.stringify(arena, try auto_import_settings.autoImportSourcesToJson(arena, sources)),
    };
}

//
// get-config: the payload is a config key. The reply is the setting the user chose under it, from config.yaml, or null when there is
// none.
//
fn getConfig(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
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
fn setConfig(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const key = json.getString(data, "key") orelse {
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
        try events.sendThemeChanged(main_state.fromContext(context).core, arena, json_value);
    }
    // Switching automatic import on or off, or changing what it watches, takes effect now rather than at the next restart. The main
    // process reads the same config the page just wrote, so this needs no message of its own.
    for (AUTO_IMPORT_CONFIG_KEYS) |auto_import_key| {
        if (std.mem.eql(u8, key, auto_import_key)) {
            try main_process.ensureAutoImport(context);
            break;
        }
    }
    return try arena.dupe(u8, "null");
}

//
// The get-state message's handler: getState, with its errors logged.
//
pub const getStateHandler = logExceptions(getState, "Error getting state value");

//
// The set-state message's handler: setState, with its errors logged.
//
pub const setStateHandler = logExceptions(setState, "Error setting state value");

//
// The get-config message's handler: getConfig, with its errors logged.
//
pub const getConfigHandler = logExceptions(getConfig, "Error getting config value");

//
// The set-config message's handler: setConfig, with its errors logged.
//
pub const setConfigHandler = logExceptions(setConfig, "Error setting config value");

//
// reset-app-storage: no payload. Empties the app's config and cache directories and, on a phone, the app's data directory, which is
// where every database the app made sits. The reply is what was removed (node-api's IResetAppStorageResult).
//
// Ziggy runs this ahead of the handler node-api registers under the same task type, because that one cannot know the data directory:
// on Android the data directory is the home directory, which the cache directory already is, but on iOS it is the app's Application
// Support directory, which neither the config nor the cache directory is, so without this a reset on iOS left every database on the
// device. On desktop the data directory holds the default database, the user's photos, so it is left alone there.
//
fn resetAppStorage(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const device_data_dir: ?[]const u8 = if (builtin.os.tag == .ios or builtin.abi.isAndroid()) std.mem.span(context.config().data_dir) else null;
    const result = try node_api.reset_app_storage_worker.resetAppStorage(context.arena, context.io(), device_data_dir);
    return try json.stringify(context.arena, result);
}

//
// The reset-app-storage task's handler: resetAppStorage, with its errors logged.
//
pub const resetAppStorageHandler = logExceptions(resetAppStorage, "Error resetting the app's storage");

//
// get-config: the data is a config key, answered by the get-config task. The response is the setting, or null.
//
pub fn getConfigMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, key: []const u8) !ziggy.core.Answer(std.json.Value) {
    _ = core;
    return .{
        .task = .{
            .task_type = "get-config",
            .data = try json.stringify(arena, key),
        },
    };
}

//
// The data of set-config.
//
pub const SetConfigRequest = struct {
    // The config key to write.
    key: []const u8,
    // The value to write, or null to remove the key.
    value: std.json.Value = .null,
};

//
// set-config: answered by the set-config task. The response is null.
//
pub fn setConfigMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: SetConfigRequest) !ziggy.core.Answer(void) {
    _ = core;
    return .{
        .task = .{
            .task_type = "set-config",
            .data = try json.stringify(arena, request),
        },
    };
}

//
// get-state: the data is a state key, answered by the get-state task. The response is the value remembered, or null.
//
pub fn getStateMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, key: []const u8) !ziggy.core.Answer(std.json.Value) {
    _ = core;
    return .{
        .task = .{
            .task_type = "get-state",
            .data = try json.stringify(arena, key),
        },
    };
}

//
// The data of set-state.
//
pub const SetStateRequest = struct {
    // The state key to write.
    key: []const u8,
    // The value to remember, or null to remove the key.
    value: std.json.Value = .null,
};

//
// set-state: answered by the set-state task. The response is null.
//
pub fn setStateMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: SetStateRequest) !ziggy.core.Answer(void) {
    _ = core;
    return .{
        .task = .{
            .task_type = "set-state",
            .data = try json.stringify(arena, request),
        },
    };
}

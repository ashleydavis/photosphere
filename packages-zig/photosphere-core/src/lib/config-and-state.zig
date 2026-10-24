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
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const app_state = node_api.app_state;
const app_config = node_api.app_config;
const auto_import_settings = @import("api-zig").auto_import_settings;
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// get-state: the payload is a state key. The reply is the value remembered under it, or null when there is none.
//
fn getState(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    if (data != .string) {
        return utils.errors.throwError("The state request needs the name of a key.", .{});
    }
    const state = try app_state.loadAppState(allocator, io);
    const value = try app_state.getAppStateValue(allocator, state, data.string);
    return try json.stringify(allocator, value);
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
fn setState(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    const key = json.getString(data, "key") orelse {
        return utils.errors.throwError("The state request needs the name of a key.", .{});
    };
    const value: ?std.json.Value = if (data.object.get("value")) |present| (if (present == .null) null else present) else null;
    const mutator: SetStateMutator = .{
        .key = key,
        .value = value,
    };
    try app_state.updateAppState(allocator, io, &mutator);
    return try allocator.dupe(u8, "null");
}

//
// The config keys that change what automatic import should be doing, so writing one restarts it.
//
pub const AUTO_IMPORT_CONFIG_KEYS = [_][]const u8{
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
fn getConfig(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    if (data != .string) {
        return utils.errors.throwError("The config request needs the name of a key.", .{});
    }
    const config = try app_config.loadAppConfig(allocator, io);
    return try configValueToJson(allocator, app_config.getAppConfigValue(config, data.string));
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
fn setConfig(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const arena = allocator;
    const key = json.getString(data, "key") orelse {
        return utils.errors.throwError("The config request needs the name of a key.", .{});
    };
    const json_value: ?std.json.Value = if (data.object.get("value")) |present| (if (present == .null) null else present) else null;
    const value: ?app_config.IAppConfigValue = if (json_value) |present| try configValueFromJson(arena, key, present) else null;
    const mutator: SetConfigMutator = .{
        .key = key,
        .value = value,
    };
    try app_config.updateAppConfig(arena, io, &mutator);
    // Keep the theme-changed event so the menu bar can react to theme changes.
    if (std.mem.eql(u8, key, "theme")) {
        try events.sendThemeChanged(services, io, arena, json_value);
    }
    // Switching automatic import on or off, or changing what it watches, takes effect now rather than at the next restart: the check
    // runs as a child of this task, and the main thread does what it found when it ends (see main-process.zig). A check that fails
    // fails this request, as TypeScript's awaited ensureAutoImport rejects it.
    if (data.object.get("ensure")) |ensure| {
        if (ensure != .null) {
            const child = try services.queueChild(io, arena, timers, "ensure-auto-import", ensure, null);
            const completion = try services.awaitTask(io, arena, timers, child);
            if (completion.status != .succeeded) {
                return utils.errors.throwError("{s}", .{completion.error_message orelse "Unknown error"});
            }
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
fn resetAppStorage(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = data;
    const device_data_dir: ?[]const u8 = if (builtin.os.tag == .ios or builtin.abi.isAndroid()) context.data_dir else null;
    const result = try node_api.reset_app_storage_worker.resetAppStorage(allocator, io, device_data_dir);
    return try json.stringify(allocator, result);
}

//
// The reset-app-storage task's handler: resetAppStorage, with its errors logged.
//
pub const resetAppStorageHandler = logExceptions(resetAppStorage, "Error resetting the app's storage");

//
// get-config: the data is a config key, answered by the get-config task. The response is the setting, or null.
//
pub fn getConfigMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, key: []const u8) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "get-config",
            .data = try json.stringify(allocator, key),
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
pub fn setConfigMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: SetConfigRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    // A setting of automatic import takes effect now rather than at the next restart: the task makes automatic import match the
    // config before it replies, as TypeScript awaits ensureAutoImport, and is given what automatic import is running now. One check
    // at a time: while one is under way the setting is only written, as TypeScript's ensureAutoImport returns while one is starting.
    var ensure: ?main_state.IEnsureAutoImportData = null;
    if (isAutoImportConfigKey(request.key)) {
        const state = main_state.current();
        if (!state.auto_import_starting) {
            const running = state.auto_import_running;
            ensure = .{
                .restarting = false,
                .runningDatabasePath = if (running) state.auto_import_database_path else null,
                .runningSettingsJson = if (running) state.auto_import_settings_json else null,
            };
            state.auto_import_starting = true;
        }
    }
    return .{
        .task = .{
            .task_type = "set-config",
            .data = try json.stringify(allocator, ISetConfigData{
                .key = request.key,
                .value = request.value,
                .ensure = ensure,
            }),
        },
    };
}

//
// What the main thread gives the set-config task: the request, and for a setting of automatic import, what automatic import is running
// now, which the check that the task runs takes.
//
const ISetConfigData = struct {
    // The config key to write.
    key: []const u8,
    // The value to write, or null to remove the key.
    value: std.json.Value = .null,
    // The input of the check of automatic import the task runs once it has written the config, or null when it runs none.
    ensure: ?main_state.IEnsureAutoImportData = null,
};

//
// Whether the key is a setting of automatic import.
//
fn isAutoImportConfigKey(key: []const u8) bool {
    for (AUTO_IMPORT_CONFIG_KEYS) |auto_import_key| {
        if (std.mem.eql(u8, key, auto_import_key)) {
            return true;
        }
    }
    return false;
}

//
// get-state: the data is a state key, answered by the get-state task. The response is the value remembered, or null.
//
pub fn getStateMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, key: []const u8) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "get-state",
            .data = try json.stringify(allocator, key),
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
pub fn setStateMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: SetStateRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "set-state",
            .data = try json.stringify(allocator, request),
        },
    };
}

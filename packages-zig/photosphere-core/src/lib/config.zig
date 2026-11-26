//
// The messages the page reads and writes its settings and its remembered state through: get-config and set-config (config.toml, what the
// user chose), and get-state and set-state (state.json, what the
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
const logExceptions = @import("log-exceptions.zig").logExceptions;

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
// get-config: the payload is a config key. The reply is the setting the user chose under it, from config.toml, or null when there is
// none.
//
fn getConfig(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    if (data != .string) {
        return utils.errors.throwError("The config request needs the name of a key.", .{});
    }
    const config = try app_config.loadAppConfig(allocator, io, services.log, context.config_path);
    return try configValueToJson(allocator, app_config.getAppConfigValue(config, data.string));
}

//
// The change set-config makes to the config: one setting set to a value, or removed, in one update.
//
const SetConfigChange = struct {
    // The key to write.
    key: []const u8,
    // The config holding the one field the key names, already checked.
    config: app_config.IAppConfig,

    //
    // Writes the field the key names.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: ziggy.config_state.config.Values) !void {
        _ = arena;
        inline for (std.meta.fields(app_config.IAppConfig)) |field| {
            if (std.mem.eql(u8, field.name, self.key)) {
                try app_config.setAppConfigIn(field.name, values, @field(self.config, field.name));
            }
        }
    }
};

//
// set-config: the payload is {key, value}. Writes the setting to config.toml, or removes it when the value is null or left out. A change
// to a setting that decides what automatic import does takes effect now rather than at the next start. The reply is null.
//
fn setConfig(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    // The setting is checked against a config with nothing in it, so a key that is no setting and a value of the wrong type fail
    // before anything is written, and the one field the key names is what the update writes.
    _ = services;
    _ = timers;
    const arena = allocator;
    const key = json.getString(data, "key") orelse {
        return utils.errors.throwError("The config request needs the name of a key.", .{});
    };
    const json_value: ?std.json.Value = if (data.object.get("value")) |present| (if (present == .null) null else present) else null;
    const value: ?app_config.IAppConfigValue = if (json_value) |present| try configValueFromJson(arena, key, present) else null;
    var checked: app_config.IAppConfig = .{};
    try app_config.setAppConfigValue(&checked, key, value);
    try ziggy.config_state.config.update(arena, io, context.config_path, SetConfigChange{ .key = key, .config = checked });
    return try arena.dupe(u8, "null");
}

//

//
// The get-config message's handler: getConfig, with its errors logged.
//
pub const getConfigHandler = logExceptions(getConfig, "Error getting config value");

//
// The set-config message's handler: setConfig, with its errors logged.
//
pub const setConfigHandler = logExceptions(setConfig, "Error setting config value");

//
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
    return .{
        .task = .{
            .task_type = "set-config",
            .data = try json.stringify(allocator, ISetConfigData{
                .key = request.key,
                .value = request.value,
            }),
        },
    };
}

//
// What the main thread gives the set-config task: the request.
//
const ISetConfigData = struct {
    // The config key to write.
    key: []const u8,
    // The value to write, or null to remove the key.
    value: std.json.Value = .null,
};

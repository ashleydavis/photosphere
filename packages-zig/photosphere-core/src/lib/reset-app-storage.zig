//
// The reset-app-storage task: no payload. Empties the app's config and cache directories and, on a phone, the app's data directory,
// which is where every database the app made sits. The reply is what was removed (node-api's IResetAppStorageResult).
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const logExceptions = @import("log-exceptions.zig").logExceptions;

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
    const result = try node_api.reset_app_storage_worker.resetAppStorage(allocator, io, device_data_dir, .{ .configPath = context.config_path, .statePath = context.state_path });
    return try json.stringify(allocator, result);
}

//
// The reset-app-storage task's handler: resetAppStorage, with its errors logged.
//
pub const resetAppStorageHandler = logExceptions(resetAppStorage, "Error resetting the app's storage");

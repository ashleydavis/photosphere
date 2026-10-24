//
// The planning tasks the phone's background loop asks of the core: plan-auto-import, plan-sync and plan-prefetch. They work out, from the settings on disk, whether the loop should
// run, with what, and how long to pause.
//
// plan-sync and plan-prefetch ask the platform for the connection type. The native app is asked through the core's host request
// callback, which only a task in Ziggy's runner can reach, so the three are Ziggy task types registered with the app and not
// handlers registered with Ziggy's task queue. They ignore their ITaskContext, so the one they are given is the minimum the
// interface needs.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const node_api = @import("node-api-zig");
const mobile_worker = @import("mobile-worker-zig");
const background_work = @import("background-work.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const ITaskContext = task_queue_zig.types.ITaskContext;
const INetworkStatusHost = mobile_worker.network_status.INetworkStatusHost;

//
// What the planning handlers' ITaskContext reaches: the services of the task they run in, the argument the task was given, which the
// context's pointer is.
//
const context_bridge_vtable: ITaskContext.VTable = .{
    .sendEvent = sendEventOfTask,
    .isCancelled = isCancelledOfTask,
};

//
// The services of the task a context or a network status host is for.
//
fn servicesOf(ptr: *anyopaque) TaskServices {
    const services: *const TaskServices = @ptrCast(@alignCast(ptr));
    return services.*;
}

fn sendEventOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, event: std.json.Value) void {
    servicesOf(ptr).sendEvent(io, allocator, event) catch |err| {
        utils.log.log.exception("Error sending a task event", err);
    };
}

fn isCancelledOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool {
    return servicesOf(ptr).isCancelled(io, allocator);
}

//
// Calls the native app for the connection type through the native call callback, by the method `networkConnectionType`, and gives
// its result, which is a JSON string such as "wifi". On Windows, whose native app has no such callback, the core makes the call itself
// (windows-native-calls.zig). Another platform with no such callback, and a native app that cannot make the call, are errors with a
// sentence the user can act on. The network status host's pointer is the task's services. The call is made with no timers, as the
// network status shim has none to give.
//
const network_status_vtable: INetworkStatusHost.VTable = .{
    .networkConnectionType = networkConnectionTypeOfTask,
};

fn networkConnectionTypeOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) anyerror![]const u8 {
    const result = try background_work.callNativeApp(servicesOf(ptr), io, allocator, null, "networkConnectionType", "null");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, result, .{}) catch {
        return utils.errors.throwError("The phone's answer to networkConnectionType could not be read.", .{});
    };
    if (parsed != .string) {
        return utils.errors.throwError("The phone's answer to networkConnectionType was not text.", .{});
    }
    return parsed.string;
}

//
// The network status host of the task whose services are given.
//
fn networkStatusOf(services: *const TaskServices) INetworkStatusHost {
    return .{
        .ptr = @constCast(services),
        .vtable = &network_status_vtable,
    };
}

//
// The minimum context the interface needs, for a handler run in the task whose services are given.
//
fn bridgedContext(services: *const TaskServices, context: TaskContext, native_caller_storage: *ziggy.task_runner.TaskNativeCaller, uuid_generator: *utils.random_uuid_generator.RandomUuidGenerator, timestamp_provider: *utils.timestamp_provider.TimestampProvider) ITaskContext {
    return .{
        .uuidGenerator = uuid_generator.uuidGenerator(),
        .timestampProvider = timestamp_provider.timestampProvider(),
        .sessionId = context.source,
        .taskId = context.task_id,
        .maxConcurrentChildTasks = context.max_concurrent_child_tasks,
        .nativeCaller = services.nativeCaller(native_caller_storage),
        .ptr = @constCast(services),
        .vtable = &context_bridge_vtable,
    };
}

//
// plan-auto-import: no payload. The reply is the plan for automatic import.
//
pub fn planAutoImportTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    // The phone's working directory is not the app's data directory, so the default database is given a place in it.
    var request: std.json.ObjectMap = .empty;
    try request.put(allocator, "appDataPath", .{
        .string = context.data_dir,
    });
    var native_caller_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(&services, context, &native_caller_storage, &uuid_generator, &timestamp_provider);
    const result = try mobile_worker.plan_auto_import_worker.planAutoImportHandler(allocator, io, timers, .{
        .object = request,
    }, task_context);
    return try std.json.Stringify.valueAlloc(allocator, result, .{});
}

//
// plan-sync: no payload. The reply is the plan for the background sync.
//
pub fn planSyncTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var native_caller_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(&services, context, &native_caller_storage, &uuid_generator, &timestamp_provider);
    const host = networkStatusOf(&services);
    const result = try mobile_worker.plan_sync_worker.planSyncHandler(allocator, io, timers, data, task_context, host);
    return try std.json.Stringify.valueAlloc(allocator, result, .{});
}

//
// plan-prefetch: no payload. The reply is the plan for the background prefetch.
//
pub fn planPrefetchTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var native_caller_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(&services, context, &native_caller_storage, &uuid_generator, &timestamp_provider);
    const host = networkStatusOf(&services);
    const result = try mobile_worker.plan_prefetch_worker.planPrefetchHandler(allocator, io, timers, data, task_context, host);
    return try std.json.Stringify.valueAlloc(allocator, result, .{});
}

//
// Gives the config tasks the path of the config file the core reads and writes, whatever path the request names. The page does not
// know where the settings directory is, and the planning tasks above read the same file.
//
fn withConfigPath(allocator: std.mem.Allocator, data: std.json.Value) !std.json.Value {
    var object: std.json.ObjectMap = if (data == .object) try data.object.clone(allocator) else .empty;
    try object.put(allocator, "configPath", .{
        .string = try node_api.config_file.getConfigPath(allocator),
    });
    return .{
        .object = object,
    };
}

//
// read-config: no required payload. The reply is the sections of the config file the background work plans from: the automatic import
// section, the syncing section and whether each has ever been written, and every setting that has a value under the name the page uses.
//
pub fn readConfigTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var native_caller_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(&services, context, &native_caller_storage, &uuid_generator, &timestamp_provider);
    const result = try node_api.config_worker.readConfigHandler(allocator, io, timers, try withConfigPath(allocator, data), task_context);
    return try std.json.Stringify.valueAlloc(allocator, result, .{});
}

//
// write-config: the payload holds the section to write (autoImport, sync) or the settings (entries). Changes only what it is given and
// leaves the rest of the config file as it is. The reply is null.
//
pub fn writeConfigTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var native_caller_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(&services, context, &native_caller_storage, &uuid_generator, &timestamp_provider);
    const result = try node_api.config_worker.writeConfigHandler(allocator, io, timers, try withConfigPath(allocator, data), task_context);
    return try std.json.Stringify.valueAlloc(allocator, result, .{});
}

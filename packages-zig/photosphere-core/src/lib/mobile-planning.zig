//
// The planning tasks the phone's background loop asks of the core: plan-auto-import, plan-sync and plan-prefetch. They work out, from the settings on disk, whether the loop should
// run, with what, and how long to pause.
//
// plan-sync and plan-prefetch ask the platform for the connection type. The shell is asked through the core's host request
// callback, which only a task in Ziggy's runner can reach, so the three are Ziggy task types registered with the app and not
// handlers registered with Ziggy's task queue. They ignore their ITaskContext, so the one they are given is the minimum the
// interface needs.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy-core").task_queue;
const node_api = @import("node-api-zig");
const mobile_worker = @import("mobile-worker-zig");
const background_work = @import("background-work.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const ITaskContext = task_queue_zig.types.ITaskContext;
const INetworkStatusHost = mobile_worker.network_status.INetworkStatusHost;

//
// What the planning handlers' ITaskContext reaches: the Ziggy context of the task they run in.
//
const ContextBridge = struct {
    // The task's context in Ziggy's runner.
    context: *TaskContext,

    // What the task's host requester asks through.
    host_requester_storage: ziggy.task_runner.TaskHostRequester,

    const vtable: ITaskContext.VTable = .{
        .sendMessage = sendMessageErased,
        .isCancelled = isCancelledErased,
    };

    fn sendMessageErased(ptr: *anyopaque, message: std.json.Value) void {
        const self: *ContextBridge = @ptrCast(@alignCast(ptr));
        self.context.sendMessage(message) catch |err| {
            utils.log.log.exception("Error sending a task message", err);
        };
    }

    fn isCancelledErased(ptr: *anyopaque) bool {
        const self: *ContextBridge = @ptrCast(@alignCast(ptr));
        return self.context.isCancelled();
    }
};

//
// Asks the shell for the connection type through the host request callback, by the method `networkConnectionType`, and gives its
// answer, which is a JSON string such as "wifi". On Windows, whose shell has no such callback, the core answers it (windows-host.zig).
// Another platform with no such callback, and a shell that cannot answer, are errors with a
// sentence the user can act on.
//
const ShellNetworkStatus = struct {
    // The task's context in Ziggy's runner.
    context: *TaskContext,

    const vtable: INetworkStatusHost.VTable = .{
        .networkConnectionType = networkConnectionTypeErased,
    };

    fn networkConnectionTypeErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *ShellNetworkStatus = @ptrCast(@alignCast(ptr));
        const answer = try background_work.askShell(self.context, "networkConnectionType", "null");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, answer, .{}) catch {
            return utils.errors.throwError("The phone's answer to networkConnectionType could not be read.", .{});
        };
        if (parsed != .string) {
            return utils.errors.throwError("The phone's answer to networkConnectionType was not text.", .{});
        }
        return parsed.string;
    }
};

//
// Runs a handler with the minimum context the interface needs, and gives its result as JSON text.
//
fn bridgedContext(context: *TaskContext, bridge: *ContextBridge, uuid_generator: *utils.random_uuid_generator.RandomUuidGenerator, timestamp_provider: *utils.timestamp_provider.TimestampProvider) ITaskContext {
    bridge.* = .{
        .context = context,
        .host_requester_storage = undefined,
    };
    return .{
        .uuidGenerator = uuid_generator.uuidGenerator(),
        .timestampProvider = timestamp_provider.timestampProvider(),
        .sessionId = context.source(),
        .taskId = context.taskId(),
        .maxConcurrentChildTasks = context.maxConcurrentChildTasks(),
        .hostRequester = context.hostRequester(&bridge.host_requester_storage),
        .toolRunner = null,
        .ptr = bridge,
        .vtable = &ContextBridge.vtable,
    };
}

//
// plan-auto-import: no payload. The reply is the plan for automatic import.
//
pub fn planAutoImportTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    // The phone's working directory is not the app's data directory, so the default database is given a place in it.
    var request: std.json.ObjectMap = .empty;
    try request.put(context.arena, "appDataPath", .{
        .string = std.mem.span(context.config().data_dir),
    });
    var bridge: ContextBridge = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(context, &bridge, &uuid_generator, &timestamp_provider);
    const result = try mobile_worker.plan_auto_import_worker.planAutoImportHandler(context.arena, context.io(), .{
        .object = request,
    }, task_context);
    return try std.json.Stringify.valueAlloc(context.arena, result, .{});
}

//
// plan-sync: no payload. The reply is the plan for the background sync.
//
pub fn planSyncTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var bridge: ContextBridge = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(context, &bridge, &uuid_generator, &timestamp_provider);
    var shell: ShellNetworkStatus = .{
        .context = context,
    };
    const host: INetworkStatusHost = .{
        .ptr = &shell,
        .vtable = &ShellNetworkStatus.vtable,
    };
    const result = try mobile_worker.plan_sync_worker.planSyncHandler(context.arena, context.io(), data, task_context, host);
    return try std.json.Stringify.valueAlloc(context.arena, result, .{});
}

//
// plan-prefetch: no payload. The reply is the plan for the background prefetch.
//
pub fn planPrefetchTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var bridge: ContextBridge = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(context, &bridge, &uuid_generator, &timestamp_provider);
    var shell: ShellNetworkStatus = .{
        .context = context,
    };
    const host: INetworkStatusHost = .{
        .ptr = &shell,
        .vtable = &ShellNetworkStatus.vtable,
    };
    const result = try mobile_worker.plan_prefetch_worker.planPrefetchHandler(context.arena, context.io(), data, task_context, host);
    return try std.json.Stringify.valueAlloc(context.arena, result, .{});
}

//
// Gives the config tasks the path of the config file the core reads and writes, whatever path the request names. The page does not
// know where the settings directory is, and the planning tasks above read the same file.
//
fn withConfigPath(arena: std.mem.Allocator, data: std.json.Value) !std.json.Value {
    var object: std.json.ObjectMap = if (data == .object) try data.object.clone(arena) else .empty;
    try object.put(arena, "configPath", .{
        .string = try node_api.config_file.getConfigPath(arena),
    });
    return .{
        .object = object,
    };
}

//
// read-config: no required payload. The reply is the sections of the config file the background work plans from: the automatic import
// section, the syncing section and whether each has ever been written, and every setting that has a value under the name the page uses.
//
pub fn readConfigTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var bridge: ContextBridge = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(context, &bridge, &uuid_generator, &timestamp_provider);
    const result = try node_api.config_worker.readConfigHandler(context.arena, context.io(), try withConfigPath(context.arena, data), task_context);
    return try std.json.Stringify.valueAlloc(context.arena, result, .{});
}

//
// write-config: the payload holds the section to write (autoImport, sync) or the settings (entries). Changes only what it is given and
// leaves the rest of the config file as it is. The reply is null.
//
pub fn writeConfigTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    var bridge: ContextBridge = undefined;
    var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
    const task_context = bridgedContext(context, &bridge, &uuid_generator, &timestamp_provider);
    const result = try node_api.config_worker.writeConfigHandler(context.arena, context.io(), try withConfigPath(context.arena, data), task_context);
    return try std.json.Stringify.valueAlloc(context.arena, result, .{});
}

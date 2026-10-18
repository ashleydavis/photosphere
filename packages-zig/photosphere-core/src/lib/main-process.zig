//
// What the main process does about databases being opened and closed, about syncing and about
// the tasks the worker pool reports on: the `notify-database-opened`, `notify-database-closed` and `notify-database-edited` channels,
// the `main-command` channel, and the functions that hear every task end and every task message from the worker pool.
//
// The state these use is in main-state.zig.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api_zig = @import("api-zig");
const databases = @import("databases.zig");
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const background_work = @import("background-work.zig");
const logExceptions = @import("log-exceptions.zig").logExceptions;

const Core = ziggy.core.Core;
const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const databases_config = node_api.databases_config;
const MainState = main_state.MainState;

//
// The source tag every automatic import task is queued under, so it can be cancelled as a group when the setting is switched off or
// the app quits.
//
const AUTO_IMPORT_TASK_SOURCE = node_api.auto_import_desktop.AUTO_IMPORT_TASK_SOURCE;

//
// notify-database-opened: the payload is the path of the database the page opened. Records the database in the databases list (adding
// an entry for it when it has none, and refreshing its origin when that changed), moves it to the front of the recently opened ones,
// remembers it as the one to reopen at the next start, and tells the main process's state, which resets syncing for it.
//
// Ziggy's menu is written once and the page decides what each item does, so there is no menu to rebuild when a database is opened.
//
fn notifyDatabaseOpened(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const io = context.io();
    if (data != .string) {
        return utils.errors.throwError("The database that was opened needs a path.", .{});
    }
    const database_path = data.string;
    const state = main_state.fromContext(context);
    const all_databases = try databases_config.getDatabases(arena, io);
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    const opened = try databases.openDatabaseStorage(arena, io, all_databases, database_path, context.hostRequester(&requester_storage));
    const database_config = try api_zig.database_config.loadDatabaseConfig(arena, io, opened.rawStorage);
    const origin: ?[]const u8 = if (database_config) |config| json_util.getString(config, "origin") else null;
    if (opened.entry) |existing| {
        if (!optionalStringsEqual(existing.origin, origin)) {
            var updated_entry = existing;
            updated_entry.origin = origin;
            try databases_config.updateDatabaseEntry(arena, io, existing.name, updated_entry);
        }
        try databases_config.markDatabaseOpened(arena, io, existing.name);
    }
    else {
        const new_entry: databases_config.IDatabaseEntry = .{
            .name = node_utils.path.basename(database_path),
            .description = "",
            .path = database_path,
            .origin = origin,
        };
        try databases_config.addDatabaseEntry(arena, io, new_entry);
        try databases_config.markDatabaseOpened(arena, io, new_entry.name);
    }

    // Recorded beside the recents update above, because it is the same fact written twice: this is the database the user is in, so it
    // is the one to reopen next time the app starts.
    try databases_config.setLastDatabase(arena, io, database_path);
    {
        state.lock();
        defer state.unlock();
        state.is_database_open = true;
    }
    try state.resetSyncState(database_path);
    {
        state.lock();
        defer state.unlock();
        try state.setOwned(&state.current_database_path, database_path);
    }
    utils.log.log.event(try std.fmt.allocPrint(arena, "Database opened: {s}", .{node_utils.path.basename(database_path)}));
    return try arena.dupe(u8, "null");
}

//
// The notify-database-opened channel's handler: notifyDatabaseOpened, with its errors logged.
//
pub const notifyDatabaseOpenedHandler = logExceptions(notifyDatabaseOpened, "Error notifying database opened");

//
// notify-database-closed: no payload. Forgets the database to reopen, so a database the user closed is not reopened for them at the
// next start, and tells the main process's state that none is open.
//
// There is no menu to rebuild, see notifyDatabaseOpenedHandler.
//
fn notifyDatabaseClosed(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const state = main_state.fromContext(context);
    try databases_config.setLastDatabase(context.arena, context.io(), null);
    {
        state.lock();
        defer state.unlock();
        state.is_database_open = false;
    }
    try state.resetSyncState(null);
    {
        state.lock();
        defer state.unlock();
        state.freeOwned(&state.current_database_path);
    }
    return try context.arena.dupe(u8, "null");
}

//
// The notify-database-closed channel's handler: notifyDatabaseClosed, with its errors logged.
//
pub const notifyDatabaseClosedHandler = logExceptions(notifyDatabaseClosed, "Error notifying database closed");

//
// notify-database-edited: no payload and no reply. Schedules a debounced sync.
//
pub fn notifyDatabaseEditedHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = data;
    main_state.fromCore(core).scheduleSync();
    return try arena.dupe(u8, "null");
}

//
// main-command: the payload is the name of a command, or an object with the name in `command` and the command's arguments beside it.
// A generic channel that lets the page trigger named actions in the main process. The commands are:
//
//  - toggle-devtools: opens the developer tools, or closes them when they are open, which the shell does as it does for the menu item.
//  - page-loaded: says the page has loaded and is listening for events, which starts the checks for an update and for news. Only the
//    first one does anything.
//  - set-sync-allowed: records whether the page's decision permits syncing automatically (`allowed`), and schedules a sync at once
//    when it does, to catch up one that was waiting.
//
// toggle-devtools needs the shell's help, so it is an error when the shell offers no way to do it. A payload with no command name
// is an unknown command called "undefined".
//
pub fn mainCommandHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const command: []const u8 = switch (data) {
        .string => |text| text,
        else => json_util.getString(data, "command") orelse "undefined",
    };
    if (std.mem.eql(u8, command, "toggle-devtools")) {
        const menu_action = core.config.menu_action orelse {
            return utils.errors.throwError("The developer tools are not available on this platform.", .{});
        };
        menu_action(core.config.user_data, "toggle-devtools");
    }
    else if (std.mem.eql(u8, command, "page-loaded")) {
        try main_state.fromCore(core).pageLoaded();
    }
    else if (std.mem.eql(u8, command, "set-sync-allowed")) {
        const state = main_state.fromCore(core);
        const allowed = data == .object and data.object.get("allowed") != null and data.object.get("allowed").? == .bool and data.object.get("allowed").?.bool;
        {
            state.lock();
            defer state.unlock();
            state.sync_allowed = allowed;
        }
        // The smoke tests wait for this line, so its wording must not change.
        utils.log.log.info(try std.fmt.allocPrint(arena, "Sync gate set to {s}", .{if (allowed) "true" else "false"}));
        // Catch up a pending sync as soon as syncing is allowed.
        if (allowed) {
            state.scheduleSync();
        }
    }
    else {
        utils.console.errorFormat("Unknown main-command: {s}", .{command});
    }
    return try arena.dupe(u8, "null");
}

//
// Whether two optional strings are both absent or both the same text (the `!==` between two string-or-undefined values).
//
fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) {
        return left == null and right == null;
    }
    return std.mem.eql(u8, left.?, right.?);
}

//
// The inputs of a replicate-database task that the main process needs when it ends (IReplicateDatabaseData).
//
const IReplicateInputs = struct {
    // The path the database was replicated to.
    destPath: []const u8,
    // The path it was replicated from.
    sourcePath: ?[]const u8 = null,
    // The vault secret name of the destination's encryption key.
    destEncryptionKey: ?[]const u8 = null,
    // The vault secret name of the destination's S3 credentials.
    destS3Key: ?[]const u8 = null,
};

//
// The inputs of a sync-database task that the main process needs when it ends (ISyncDatabaseData).
//
const ISyncInputs = struct {
    // The path of the database that was synced.
    databasePath: ?[]const u8 = null,
};

//
// Registers the destination of a successful replicate-database task in the databases list (so it shows up on the Manage Databases
// page) and notifies the user.
//
fn handleReplicateSucceeded(core: *Core, arena: std.mem.Allocator, inputs: IReplicateInputs) !void {
    const io = core.io();
    const existing_databases = try databases_config.getDatabases(arena, io);
    var already_registered = false;
    for (existing_databases) |entry| {
        if (std.mem.eql(u8, entry.path, inputs.destPath)) {
            already_registered = true;
            break;
        }
    }
    if (!already_registered) {
        try databases_config.addDatabaseEntry(arena, io, .{
            .name = node_utils.path.basename(inputs.destPath),
            .description = "",
            .path = inputs.destPath,
            .origin = inputs.sourcePath,
            .encryptionKey = inputs.destEncryptionKey,
            .s3Key = inputs.destS3Key,
        });

        // Tell the page the set of configured databases changed so the Manage Databases list refreshes without a manual refresh.
        try events.sendDatabasesChanged(core, arena);
    }
    const message = try std.fmt.allocPrint(arena, "Replication completed for \"{s}\"", .{node_utils.path.basename(inputs.destPath)});
    utils.log.log.event(message);
    try events.sendShowNotification(core, arena, .{
        .message = message,
        .color = "success",
    });
}

//
// Drops local originals the origin already holds, after the default database has synced. Only the default database is considered: it is
// the one automatic import fills, and the only one the app decides retention for on the user's behalf.
//
fn enqueueEvictOriginals(core: *Core, arena: std.mem.Allocator, database_path: []const u8) !void {
    const state = main_state.fromCore(core);
    {
        state.lock();
        defer state.unlock();
        if (state.auto_import_database_path == null or !std.mem.eql(u8, state.auto_import_database_path.?, database_path)) {
            return;
        }
    }
    const session_id = try state.uuid_generator.generate(arena, core.io());
    const evict_data = try json_util.stringify(arena, .{
        .databasePath = database_path,
        .sessionId = session_id,
    });
    const task_id = try state.uuid_generator.generate(arena, core.io());
    try core.runner.addTask(task_id, "evict-originals", AUTO_IMPORT_TASK_SOURCE, evict_data, .background, null);
}

//
// Creates the default private database and records it. The same create-default-database task a phone's background import runs: it
// makes the database, lists it, and remembers it as the default. The main process queues it rather than writing the config and the
// database list itself, so the default database comes to exist one way rather than one way per platform.
//
// The task is a child of the one running ensureAutoImport, so it takes that task's source.
//
fn createDefaultDatabase(context: *TaskContext, database_path: []const u8) !void {
    const arena = context.arena;
    utils.log.log.info(try std.fmt.allocPrint(arena, "Creating the default photo database at \"{s}\".", .{database_path}));
    const task_id = try context.queueChild("create-default-database", .{
        .databasePath = database_path,
        .configPath = try node_api.config_file.getConfigPath(arena),
        .databasesConfigPath = try databases_config.getDatabasesConfigPath(arena),

        // The user switched automatic import on and photos are about to start arriving in this database, so it is asked for on screen
        // as well as on disk. The same thing a phone's pass asks for, said the same way: in the request that makes the database.
        .open = true,
    }, null);
    const completion = try context.awaitTask(task_id);
    if (completion.status != .succeeded) {
        return utils.errors.throwError("Failed to create the default photo database at \"{s}\": {s}", .{ database_path, completion.error_message orelse "" });
    }
    try events.sendDatabasesChanged(main_state.fromContext(context).core, arena);
}

//
// Forgets that automatic import is running, and which database and settings it was started with, and says whether it was running. The
// caller cancels its tasks after this, with no lock held, because cancelling can end tasks on this thread and the end of a task takes the
// lock.
//
fn clearAutoImportState(state: *MainState) bool {
    state.lock();
    defer state.unlock();
    const was_running = state.auto_import_running;
    if (was_running) {
        state.auto_import_running = false;
        state.freeOwned(&state.auto_import_database_path);
        state.freeOwned(&state.auto_import_settings_json);
    }
    return was_running;
}

//
// Starts or stops automatic import to match the current config. Called whenever one of the automatic import settings is written, so
// switching the toggle takes effect without restarting the app.
//
// It runs as part of a task, so that it can wait for the task that creates the default database.
//
pub fn ensureAutoImport(context: *TaskContext) !void {
    // A phone does not watch folders. Its automatic import is the background work the page starts and stops (startBackgroundImport and
    // stopBackgroundImport), which reads the device photo library.
    if (builtin.os.tag == .ios or builtin.abi.isAndroid()) {
        return;
    }
    const arena = context.arena;
    const io = context.io();
    const state = main_state.fromContext(context);
    {
        state.lock();
        defer state.unlock();
        if (state.auto_import_starting) {
            return;
        }
    }

    const config = try node_api.app_config.loadAppConfig(arena, io);
    const plan = try node_api.auto_import_desktop.planDesktopAutoImport(arena, config, try node_utils.photo_folders.getDefaultPhotoFolders(arena, io), std.mem.span(context.config().data_dir));

    const planned_settings_json = try json_util.stringify(arena, try api_zig.auto_import_settings.autoImportSettingsToJson(arena, plan.settings));

    if (!plan.shouldRun) {
        if (clearAutoImportState(state)) {
            utils.log.log.info("Stopping automatic import.");
            state.core.runner.cancelSource(AUTO_IMPORT_TASK_SOURCE);
        }
        return;
    }

    // Already running against the right database with the same settings.
    {
        state.lock();
        defer state.unlock();
        if (state.auto_import_running and state.auto_import_database_path != null and std.mem.eql(u8, state.auto_import_database_path.?, plan.databasePath) and state.auto_import_settings_json != null and std.mem.eql(u8, state.auto_import_settings_json.?, planned_settings_json)) {
            return;
        }
    }

    {
        state.lock();
        defer state.unlock();
        state.auto_import_starting = true;
    }
    defer {
        state.lock();
        defer state.unlock();
        state.auto_import_starting = false;
    }

    if (clearAutoImportState(state)) {
        state.core.runner.cancelSource(AUTO_IMPORT_TASK_SOURCE);
    }

    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    if (plan.isNewDefault or !(try node_api.media_file_database.checkDatabaseExists(arena, io, plan.databasePath, context.hostRequester(&requester_storage)))) {
        try createDefaultDatabase(context, plan.databasePath);
    }

    utils.log.log.info(try std.fmt.allocPrint(arena, "Starting automatic import into \"{s}\".", .{plan.databasePath}));
    // The import task itself, fed by a scanner that watches the configured folders. There used to be a separate `auto-import` task that
    // ran a loop and started one of these for every handful of photos it released; one task doing both is what removed that cost.
    const session_id = try state.uuid_generator.generate(arena, io);
    const job_id = try std.mem.concat(arena, u8, &.{ "auto-import:", plan.databasePath });
    const import_data = try json_util.stringify(arena, .{
        .paths = [_][]const u8{},
        .storageDescriptor = .{
            .databasePath = plan.databasePath,
        },
        .sessionId = session_id,
        .dryRun = false,
        .options = .{
            .auto = true,
            .enabled = plan.settings.enabled,
            .sources = try api_zig.auto_import_settings.autoImportSourcesToJson(arena, plan.settings.sources),
        },
        .job = .{
            .id = job_id,
            .name = "Automatic import",
            .cancelSource = AUTO_IMPORT_TASK_SOURCE,
        },
    });
    const task_id = try state.uuid_generator.generate(arena, io);

    // What is remembered about the task is recorded before the task is queued. The task runs on
    // another thread and can end before this one gets to record anything, and the end is told apart from a manual import's by the
    // remembered id, so recorded afterwards a task that ended at once would be remembered as running for good.
    {
        state.lock();
        defer state.unlock();
        try state.setOwned(&state.auto_import_task_id, task_id);
        state.auto_import_running = true;
        try state.setOwned(&state.auto_import_database_path, plan.databasePath);
        try state.setOwned(&state.auto_import_settings_json, planned_settings_json);
    }
    errdefer {
        _ = clearAutoImportState(state);
        state.lock();
        defer state.unlock();
        state.freeOwned(&state.auto_import_task_id);
    }
    try state.core.runner.addTask(task_id, "import-assets", AUTO_IMPORT_TASK_SOURCE, import_data, .background, null);
}

//
// ensure-auto-import: no payload. Makes automatic import match the config, as ensureAutoImport does. Queued by the timer thread of
// main-state.zig at the start and then on every tick of the automatic import check (AUTO_IMPORT_RESTART_CHECK_MS), as a task because the function waits for the
// task that creates the default database and only a task can wait. A failure is logged when the task ends (see handleTaskEnd).
//
pub fn ensureAutoImportTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try ensureAutoImport(context);
    return try context.arena.dupe(u8, "null");
}

//
// Told when any task ends. Resets syncing when a sync ends, starts the
// eviction of originals after a sync that succeeded, tells the user when an import or a replication fails, registers the destination of
// a replication that worked, and notices when automatic import stops. The page is told of every task's end by the core.
//
pub fn onTaskEnd(core: *Core, end: ziggy.types.TaskEnd) void {
    var arena_state = std.heap.ArenaAllocator.init(core.allocator);
    defer arena_state.deinit();
    handleTaskEnd(core, arena_state.allocator(), end) catch |err| {
        utils.log.log.exception("Error handling the end of a task", err);
    };
}

//
// The text of a task's error, or "Unknown error" when it has none or it is empty (`result.errorMessage || 'Unknown error'`).
//
fn errorMessageOrUnknown(error_message: ?[]const u8) []const u8 {
    const message = error_message orelse {
        return "Unknown error";
    };
    if (message.len == 0) {
        return "Unknown error";
    }
    return message;
}

//
// What the main process does when the asset server task ends. The
// server is meant to run for the life of the app, so its ending is either the app quitting or a failure. After a failure the server is
// started again on the port it had, so the address the page was loaded with stays valid.
//
// A task ends with a status and a message, so the failure is logged with its message.
// A server that ended before it said which port it bound is not started again: the start here is the page's query asking for the
// port, which reports the same failure to the shell.
//
fn handleAssetServerEnd(state: *MainState, arena: std.mem.Allocator, end: ziggy.types.TaskEnd) !void {
    if (end.status == .failed) {
        utils.log.log.@"error"(try std.fmt.allocPrint(arena, "The asset server stopped: {s}", .{errorMessageOrUnknown(end.error_message)}));
    }
    var port: u16 = 0;
    {
        state.lock();
        defer state.unlock();
        port = state.asset_server_port;
        if (port == 0 or state.stopping.load(.acquire)) {
            state.asset_server_ended = true;
            if (port == 0) {
                try state.setOwned(&state.asset_server_error, errorMessageOrUnknown(end.error_message));
            }
            return;
        }
    }
    utils.console.log("Restarting REST API worker...");
    state.queueAssetServer(port) catch |err| {
        utils.log.log.exception("Failed to restart REST API worker", err);
    };
}

//
// What the main process does when the MCP server task ends. A server that never started (its port is taken, say) is logged and the app carries on
// without it. One that was running and failed is started again, unless the app is stopping.
//
fn handleMcpServerEnd(state: *MainState, arena: std.mem.Allocator, end: ziggy.types.TaskEnd) !void {
    const was_serving = state.mcp_bridge.port.swap(0, .acq_rel) != 0;
    if (end.status != .failed) {
        return;
    }
    if (!was_serving) {
        utils.log.log.@"error"(try std.fmt.allocPrint(arena, "MCP server failed to start, continuing without it: {s}", .{errorMessageOrUnknown(end.error_message)}));
        return;
    }
    utils.log.log.@"error"(try std.fmt.allocPrint(arena, "The MCP server stopped: {s}", .{errorMessageOrUnknown(end.error_message)}));
    if (state.stopping.load(.acquire)) {
        return;
    }
    utils.console.log("Restarting MCP worker...");
    state.queueMcpServer() catch |err| {
        utils.log.log.exception("Failed to restart MCP worker", err);
    };
}

//
// What the main process does when a task ends.
//
fn handleTaskEnd(core: *Core, arena: std.mem.Allocator, end: ziggy.types.TaskEnd) !void {
    const state = main_state.fromCore(core);
    if (background_work.Pass.fromTaskType(end.task_type)) |pass| {
        state.releaseBackgroundPass(pass);
        if (end.status == .failed) {
            utils.log.log.@"error"(try std.fmt.allocPrint(arena, "The background {s} pass failed: {s}", .{ pass.label(), errorMessageOrUnknown(end.error_message) }));
        }
    }
    if (std.mem.eql(u8, end.task_type, "ensure-auto-import") and end.status == .failed) {
        // ensureAutoImport runs as a task, see ensureAutoImportTask. The error is logged as 'Error starting automatic import' at
        // startup and 'Error restarting automatic import' on the timer.
        // A task's end carries the text of the error and not the error, so the text follows the message.
        const what = if (std.mem.eql(u8, end.input_json, main_state.ENSURE_AUTO_IMPORT_RESTARTING_INPUT)) "restarting" else "starting";
        utils.log.log.@"error"(try std.fmt.allocPrint(arena, "Error {s} automatic import: {s}", .{ what, errorMessageOrUnknown(end.error_message) }));
    }
    if (std.mem.eql(u8, end.task_type, "asset-server")) {
        try handleAssetServerEnd(state, arena, end);
    }
    if (std.mem.eql(u8, end.task_type, "mcp-server")) {
        try handleMcpServerEnd(state, arena, end);
    }
    if (std.mem.eql(u8, end.task_type, "sync-database")) {
        state.syncStopped();
        if (end.status != .succeeded) {
            try events.sendSyncCompleted(core, arena);
        }
        else {
            // Only what the origin now holds may be dropped, so eviction waits for a sync that actually succeeded rather than being
            // scheduled alongside it.
            const sync_inputs = try std.json.parseFromSliceLeaky(ISyncInputs, arena, end.input_json, .{
                .ignore_unknown_fields = true,
            });
            // (`syncInputs?.databasePath` is false for an empty path as well as for none.)
            if (sync_inputs.databasePath) |database_path| {
                if (database_path.len > 0) {
                    try enqueueEvictOriginals(core, arena, database_path);
                }
            }
        }
    }
    if (std.mem.eql(u8, end.task_type, "import-assets")) {
        var is_auto_import_task = false;
        {
            state.lock();
            defer state.unlock();
            if (state.auto_import_task_id) |auto_import_task_id| {
                is_auto_import_task = std.mem.eql(u8, auto_import_task_id, end.task_id);
            }
            if (is_auto_import_task) {
                // Automatic import is not meant to end while the setting is on, so this is either a crash or a cancellation. Either
                // way the app owns restarting it: a task that died silently looks exactly like automatic import finding nothing to
                // do, and used to stay dead until the app was restarted.
                state.auto_import_running = false;
                state.freeOwned(&state.auto_import_task_id);
                state.freeOwned(&state.auto_import_database_path);
                state.freeOwned(&state.auto_import_settings_json);
            }
        }
        if (is_auto_import_task) {
            if (end.status != .succeeded) {
                utils.log.log.@"error"(try std.fmt.allocPrint(arena, "Automatic import stopped: {s}", .{errorMessageOrUnknown(end.error_message)}));
            }
            return;
        }
        if (end.status == .succeeded) {
            utils.log.log.event("Import task completed");
        }
        else {
            try events.sendShowNotification(core, arena, .{
                .message = try std.fmt.allocPrint(arena, "Import failed: {s}", .{errorMessageOrUnknown(end.error_message)}),
                .color = "danger",
                .duration = 8000,
            });
        }
    }
    if (std.mem.eql(u8, end.task_type, "replicate-database")) {
        if (end.status == .succeeded) {
            const inputs = try std.json.parseFromSliceLeaky(IReplicateInputs, arena, end.input_json, .{
                .ignore_unknown_fields = true,
            });
            handleReplicateSucceeded(core, arena, inputs) catch |err| {
                utils.log.log.exception("Error finalising replicate-database", err);
            };
        }
        else {
            try events.sendShowNotification(core, arena, .{
                .message = try std.fmt.allocPrint(arena, "Replication failed: {s}", .{errorMessageOrUnknown(end.error_message)}),
                .color = "danger",
                .duration = 8000,
            });
        }
    }
    if (std.mem.eql(u8, end.task_type, "add-paths") and end.status == .succeeded) {
        utils.log.log.info("Import task completed");
    }
}

//
// Told when any task sends a message. Tells the page when a sync starts and
// when it completes. The page is told of every task message by the core.
//
pub fn onTaskMessage(core: *Core, sent: ziggy.types.TaskSentMessage) void {
    var arena_state = std.heap.ArenaAllocator.init(core.allocator);
    defer arena_state.deinit();
    handleTaskMessage(core, arena_state.allocator(), sent) catch |err| {
        utils.log.log.exception("Error handling a task message", err);
    };
}

fn handleTaskMessage(core: *Core, arena: std.mem.Allocator, sent: ziggy.types.TaskSentMessage) !void {
    const message = try std.json.parseFromSliceLeaky(std.json.Value, arena, sent.message_json, .{});
    const message_type = json_util.getString(message, "type") orelse {
        return;
    };
    if (std.mem.eql(u8, message_type, "sync-started")) {
        utils.log.log.event("Sync started");
        try events.sendSyncStarted(core, arena);
    }
    else if (std.mem.eql(u8, message_type, "sync-completed")) {
        // The suffix says whether the sync moved anything, which is the only way to tell a sync that ran and found both sides
        // identical from one that pushed changes. "Sync completed" stays the start of the line, so a wait on that text alone still
        // matches.
        const synced_field = if (message == .object) message.object.get("synced") else null;
        const moved_changes = synced_field != null and synced_field.? == .bool and synced_field.?.bool;
        if (moved_changes) {
            utils.log.log.event("Sync completed: changes synced");
        }
        else {
            utils.log.log.event("Sync completed: nothing to sync");
        }
        try events.sendSyncCompleted(core, arena);
    }
    else if (std.mem.eql(u8, message_type, "asset-server-ready")) {
        // The asset server says which port it bound.
        const port = json_util.getInteger(message, "port") orelse {
            return utils.errors.throwError("The asset server's ready message has no port.", .{});
        };
        if (port <= 0 or port > std.math.maxInt(u16)) {
            return utils.errors.throwError("The asset server's ready message has a port that is not a port: {d}.", .{port});
        }
        const state = main_state.fromCore(core);
        state.lock();
        defer state.unlock();
        state.asset_server_port = @intCast(port);
        utils.log.log.info(try std.fmt.allocPrint(arena, "REST API initialized on port {d}", .{port}));
    }
}

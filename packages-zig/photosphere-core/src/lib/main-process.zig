//
// What the Electron main process of apps/desktop/src/main.ts does about databases being opened and closed, about syncing and about
// the tasks the worker pool reports on: the `notify-database-opened`, `notify-database-closed` and `notify-database-edited` channels,
// the `main-command` channel, and the functions `initWorkers` hands the worker pool to hear every task end and every task message.
//
// The state these use is in main-state.zig.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api_zig = @import("api-zig");
const databases = @import("databases.zig");
const events = @import("events.zig");
const main_state = @import("main-state.zig");

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
// (Zig: main.ts rebuilds the application menu here (`updateMenu`) so that its items follow whether a database is open. Ziggy's menu is
// written once and the page decides what each item does, so there is no menu to rebuild.)
//
pub fn notifyDatabaseOpenedHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const io = context.io();
    if (data != .string) {
        return utils.errors.throwError("The database that was opened needs a path.", .{});
    }
    const database_path = data.string;
    const state = main_state.fromContext(context);
    const all_databases = try databases_config.getDatabases(arena, io);
    const opened = try databases.openDatabaseStorage(arena, io, all_databases, database_path);
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
// notify-database-closed: no payload. Forgets the database to reopen, so a database the user closed is not reopened for them at the
// next start, and tells the main process's state that none is open.
//
// (Zig: there is no menu to rebuild (`updateMenu` in main.ts), see notifyDatabaseOpenedHandler.)
//
pub fn notifyDatabaseClosedHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
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
//  - set-sync-allowed: records whether the page's decision permits syncing automatically (`allowed`), and schedules a sync at once
//    when it does, to catch up one that was waiting.
//
// (Zig: an unknown command, or a payload with no command name, is an error reply, where TypeScript wrote the unknown command to the
// console and replied nothing. Zig also needs the shell's help for toggle-devtools, where TypeScript called the main window's
// `toggleDevTools()`, so it is an error when the shell offers no way to do it.)
//
pub fn mainCommandHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const command: []const u8 = switch (data) {
        .string => |text| text,
        else => json_util.getString(data, "command") orelse {
            return utils.errors.throwError("The main command needs the name of a command.", .{});
        },
    };
    if (std.mem.eql(u8, command, "toggle-devtools")) {
        const menu_action = core.config.menu_action orelse {
            return utils.errors.throwError("The developer tools are not available on this platform.", .{});
        };
        menu_action(core.config.user_data, "toggle-devtools");
    }
    else if (std.mem.eql(u8, command, "set-sync-allowed")) {
        const state = main_state.fromCore(core);
        const allowed = data == .object and data.object.get("allowed") != null and data.object.get("allowed").? == .bool and data.object.get("allowed").?.bool;
        {
            state.lock();
            defer state.unlock();
            state.sync_allowed = allowed;
        }
        utils.log.log.info(try std.fmt.allocPrint(arena, "Sync allowed set to {s}", .{if (allowed) "true" else "false"}));
        // Catch up a pending sync as soon as syncing is allowed.
        if (allowed) {
            state.scheduleSync();
        }
    }
    else {
        return utils.errors.throwError("Unknown main-command: {s}", .{command});
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
    try core.runner.addTask(task_id, "evict-originals", AUTO_IMPORT_TASK_SOURCE, evict_data, 0, null);
}

//
// Creates the default private database and records it. The same create-default-database task a phone's background import runs: it
// makes the database, lists it, and remembers it as the default. The main process queues it rather than writing the config and the
// database list itself, so the default database comes to exist one way rather than one way per platform.
//
// (Zig: the task is a child of the one running ensureAutoImport, so it takes that task's source, where main.ts queues it under the
// database's path so that opening another database cancels it.)
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
    });
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
// (Zig: it runs as part of a task, so that it can wait for the task that creates the default database.)
//
pub fn ensureAutoImport(context: *TaskContext) !void {
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

    if (plan.isNewDefault or !(try node_api.media_file_database.checkDatabaseExists(arena, io, plan.databasePath))) {
        try createDefaultDatabase(context, plan.databasePath);
    }

    utils.log.log.info(try std.fmt.allocPrint(arena, "Starting automatic import into \"{s}\".", .{plan.databasePath}));
    // The import task itself, fed by a scanner that watches the configured folders. There used to be a separate `auto-import` task that
    // ran a loop and started one of these for every handful of photos it released; one task doing both is what removed that cost.
    const session_id = try state.uuid_generator.generate(arena, io);
    const job_id = try std.fmt.allocPrint(arena, "auto-import:{s}", .{plan.databasePath});
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

    // (Zig: what is remembered about the task is recorded before the task is queued, where main.ts records it after. The task runs on
    // another thread and can end before this one gets to record anything, and the end is told apart from a manual import's by the
    // remembered id, so recorded afterwards a task that ended at once would be remembered as running for good. In main.ts nothing can
    // run between the two, so the order does not show.)
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
    try state.core.runner.addTask(task_id, "import-assets", AUTO_IMPORT_TASK_SOURCE, import_data, 0, null);
}

//
// ensure-auto-import: no payload. Makes automatic import match the config, as ensureAutoImport does. Queued by the timer thread of
// main-state.zig at the start and then on every tick of the automatic import check (AUTO_IMPORT_RESTART_CHECK_MS), where main.ts calls the function itself, because the function waits for the
// task that creates the default database and only a task can wait. A failure is logged when the task ends (see handleTaskEnd).
//
pub fn ensureAutoImportTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try ensureAutoImport(context);
    return try context.arena.dupe(u8, "null");
}

//
// Told when any task ends (`workerPool.onTaskComplete` of initWorkers in main.ts). Resets syncing when a sync ends, starts the
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
// What the main process does when a task ends, in the order of the callback `initWorkers` gives `workerPool.onTaskComplete`.
//
fn handleTaskEnd(core: *Core, arena: std.mem.Allocator, end: ziggy.types.TaskEnd) !void {
    const state = main_state.fromCore(core);
    if (std.mem.eql(u8, end.task_type, "ensure-auto-import") and end.status == .failed) {
        // (Zig: ensureAutoImport runs as a task here, see ensureAutoImportTask. main.ts logged the error where it called the function,
        // as 'Error starting automatic import' at startup and 'Error restarting automatic import' on the timer.)
        utils.log.log.@"error"(try std.fmt.allocPrint(arena, "Error starting automatic import: {s}", .{errorMessageOrUnknown(end.error_message)}));
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
            if (sync_inputs.databasePath) |database_path| {
                try enqueueEvictOriginals(core, arena, database_path);
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
                utils.log.log.@"error"(try std.fmt.allocPrint(arena, "Automatic import stopped: {s}", .{end.error_message orelse ""}));
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
// Told when any task sends a message (`workerPool.onAnyTaskMessage` of initWorkers in main.ts). Tells the page when a sync starts and
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
        utils.log.log.event("Sync completed");
        try events.sendSyncCompleted(core, arena);
    }
}

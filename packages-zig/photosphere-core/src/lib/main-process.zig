//
// What the main process does about databases being opened and closed, about syncing and about
// the tasks the worker pool reports on: the `notify-database-opened`, `notify-database-closed` and `notify-database-edited` messages,
// the `main-command` message, and the functions that hear every task end and every task event from the worker pool.
//
// The state these use is in main-state.zig, and only the main thread uses it. A task never reaches it: it gets what it needs in its
// data, and sends back what the main thread should know as its result or as events, which the functions here apply when the task ends
// or sends them.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api_zig = @import("api-zig");
const databases = @import("databases.zig");
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const background_work = @import("background-work.zig");
const saving_assets = @import("saving-assets.zig");
const logExceptions = @import("log-exceptions.zig").logExceptions;

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const databases_config = node_api.databases_config;
const MainState = main_state.MainState;

//
// The source tag every automatic import task is queued under, so it can be cancelled as a group when the setting is switched off or
// the app quits.
//
const AUTO_IMPORT_TASK_SOURCE = node_api.auto_import_desktop.AUTO_IMPORT_TASK_SOURCE;

//
// notify-database-opened: the payload is the path of the database the page opened. Records the database in the databases list (adding
// an entry for it when it has none, and refreshing its origin when that changed), moves it to the front of the recently opened ones and
// remembers it as the one to reopen at the next start. The main thread resets syncing for it when the task ends (see handleTaskEnd).
//
// Ziggy's menu is written once and the page decides what each item does, so there is no menu to rebuild when a database is opened.
//
fn notifyDatabaseOpened(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    const arena = allocator;
    if (data != .string) {
        return utils.errors.throwError("The database that was opened needs a path.", .{});
    }
    const database_path = data.string;
    const all_databases = try databases_config.getDatabases(arena, io);
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const opened = try databases.openDatabaseStorage(arena, io, all_databases, database_path, services.nativeCaller(&requester_storage));
    const database_config = try api_zig.database_config.loadDatabaseConfig(arena, io, opened.rawStorage);
    const origin: ?[]const u8 = if (database_config) |config| json.getString(config, "origin") else null;
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
    utils.log.log.event(try std.fmt.allocPrint(arena, "Database opened: {s}", .{node_utils.path.basename(database_path)}));
    return try arena.dupe(u8, "null");
}

//
// The notify-database-opened message's handler: notifyDatabaseOpened, with its errors logged.
//
pub const notifyDatabaseOpenedHandler = logExceptions(notifyDatabaseOpened, "Error notifying database opened");

//
// notify-database-closed: no payload. Forgets the database to reopen, so a database the user closed is not reopened for them at the
// next start. The main thread records that none is open when the task ends (see handleTaskEnd).
//
// There is no menu to rebuild, see notifyDatabaseOpenedHandler.
//
fn notifyDatabaseClosed(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    _ = data;
    try databases_config.setLastDatabase(allocator, io, null);
    return try allocator.dupe(u8, "null");
}

//
// The notify-database-closed message's handler: notifyDatabaseClosed, with its errors logged.
//
pub const notifyDatabaseClosedHandler = logExceptions(notifyDatabaseClosed, "Error notifying database closed");

//
// The data of notify-database-closed and notify-database-edited, which have none.
//
pub const NoRequest = struct {};

//
// notify-database-opened: the data is the path of the database the page opened, which the notify-database-opened task is given. The
// response is null.
//
pub fn notifyDatabaseOpenedMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: []const u8) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "notify-database-opened",
            .data = try json.stringify(allocator, payload),
        },
    };
}

//
// notify-database-closed: the response is the notify-database-closed task's, null.
//
pub fn notifyDatabaseClosedMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: NoRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "notify-database-closed",
            .data = try json.stringify(allocator, payload),
        },
    };
}

//
// notify-database-edited: no payload and no reply. Schedules a debounced sync.
//
pub fn notifyDatabaseEditedHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: NoRequest) !void {
    _ = services;
    _ = allocator;
    _ = payload;
    try main_state.current().scheduleSync(timers, io);
}

//
// The data of main-command: the command's name, or an object with the name in `command` and its arguments beside it. The page
// sends both, so the data is taken as it comes.
//
pub const MainCommandRequest = std.json.Value;

//
// main-command: the payload is the name of a command, or an object with the name in `command` and the command's arguments beside it.
// A generic message that lets the page trigger named actions in the main process. The commands are:
//
//  - toggle-devtools: opens the developer tools, or closes them when they are open, which the native app does as it does for the
//    menu item. A native app with no menu actions ignores it.
//  - page-loaded: says the page has loaded and is listening for events, which starts the checks for an update and for news. Only the
//    first one does anything.
//  - set-sync-allowed: records whether the page's decision permits syncing automatically (`allowed`), and schedules a sync at once
//    when it does, to catch up one that was waiting.
//  - cancel-tasks: cancels the tasks of a source (`source`).
//
// A payload with no command name is an unknown command called "undefined".
//
pub fn mainCommandHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, payload: MainCommandRequest) !void {
    const command: []const u8 = switch (payload) {
        .string => |text| text,
        else => json.getString(payload, "command") orelse "undefined",
    };
    if (std.mem.eql(u8, command, "toggle-devtools")) {
        services.menuAction(io, allocator, "toggle-devtools");
    }
    else if (std.mem.eql(u8, command, "page-loaded")) {
        try main_state.current().pageLoaded(services, io, main_state.stateAllocator());
    }
    else if (std.mem.eql(u8, command, "set-sync-allowed")) {
        const state = main_state.current();
        const allowed = payload == .object and payload.object.get("allowed") != null and payload.object.get("allowed").? == .bool and payload.object.get("allowed").?.bool;
        state.sync_allowed = allowed;
        // The smoke tests wait for this line, so its wording must not change.
        utils.log.log.info(try std.fmt.allocPrint(allocator, "Sync gate set to {s}", .{if (allowed) "true" else "false"}));
        // Catch up a pending sync as soon as syncing is allowed.
        if (allowed) {
            try state.scheduleSync(timers, io);
        }
    }
    else if (std.mem.eql(u8, command, "cancel-tasks")) {
        // The page's cancel. Cancelling in the worker pool drops the source's queued tasks, tells the workers running its tasks, and
        // tells the task queues of the source, which stop awaiting them, as the original app's worker pool does
        // (apps/desktop/src/lib/worker-pool-electron-main.ts cancelTasks, apps/desktop/src/worker.ts "cancel-tasks").
        const source = json.getString(payload, "source") orelse {
            return utils.errors.throwError("main-command cancel-tasks needs the source of the tasks to cancel.", .{});
        };
        services.cancelTasks(io, allocator, source);
    }
    else {
        utils.console.errorFormat("Unknown main-command: {s}", .{command});
    }
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
fn handleReplicateSucceeded(services: HandlerServices, io: std.Io, arena: std.mem.Allocator, inputs: IReplicateInputs) !void {
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
        try events.sendDatabasesChanged(services, io, arena);
    }
    const message = try std.fmt.allocPrint(arena, "Replication completed for \"{s}\"", .{node_utils.path.basename(inputs.destPath)});
    utils.log.log.event(message);
    try events.sendShowNotification(services, io, arena, .{
        .message = message,
        .color = "success",
    });
}

//
// Drops local originals the origin already holds, after the default database has synced. Only the default database is considered: it is
// the one automatic import fills, and the only one the app decides retention for on the user's behalf.
//
fn enqueueEvictOriginals(state: *MainState, services: HandlerServices, io: std.Io, arena: std.mem.Allocator, database_path: []const u8) !void {
    if (state.auto_import_database_path == null or !std.mem.eql(u8, state.auto_import_database_path.?, database_path)) {
        return;
    }
    const session_id = try state.uuid_generator.uuidGenerator().generate(arena, io);
    const evict_data = try json.stringify(arena, .{
        .databasePath = database_path,
        .sessionId = session_id,
    });
    const task_id = try state.uuid_generator.uuidGenerator().generate(arena, io);
    try services.addTask(io, arena, task_id, "evict-originals", AUTO_IMPORT_TASK_SOURCE, evict_data, .background);
}

//
// Creates the default private database and records it. The same create-default-database task a phone's background import runs: it
// makes the database, lists it, and remembers it as the default. The main process queues it rather than writing the config and the
// database list itself, so the default database comes to exist one way rather than one way per platform.
//
// The task is a child of the one running ensureAutoImport, so it takes that task's source.
//
fn createDefaultDatabase(services: TaskServices, timers: Timers, io: std.Io, arena: std.mem.Allocator, database_path: []const u8) !void {
    utils.log.log.info(try std.fmt.allocPrint(arena, "Creating the default photo database at \"{s}\".", .{database_path}));
    const task_id = try services.queueChild(io, arena, timers, "create-default-database", .{
        .databasePath = database_path,
        .configPath = try node_api.config_file.getConfigPath(arena),
        .databasesConfigPath = try databases_config.getDatabasesConfigPath(arena),

        // The user switched automatic import on and photos are about to start arriving in this database, so it is requested on screen
        // as well as on disk. The same thing a phone's pass requests, put the same way: in the request that makes the database.
        .open = true,
    }, null);
    const completion = try services.awaitTask(io, arena, timers, task_id);
    if (completion.status != .succeeded) {
        return utils.errors.throwError("Failed to create the default photo database at \"{s}\": {s}", .{ database_path, completion.error_message orelse "" });
    }
    try events.sendDatabasesChanged(services, io, arena);
}

//
// What the `ensure-auto-import` task found automatic import should do, which the main thread does when the task ends.
//
pub const IEnsureAutoImportResult = struct {
    // "none" when automatic import is already doing what the config says (or this is a phone), "stop" when it should not run, and
    // "start" when it should be started into the database, with the settings, given here.
    action: []const u8,
    // The database to import into, for "start".
    databasePath: ?[]const u8 = null,
    // The settings, as JSON, for "start".
    settingsJson: ?[]const u8 = null,
    // Whether the settings switch automatic import on, for "start".
    enabled: bool = false,
    // The sources to watch, for "start".
    sources: ?std.json.Value = null,
};

//
// Finds out what automatic import should be doing to match the current config, and creates the default database when it is needed.
// Run whenever one of the automatic import settings is written, so switching the toggle takes effect without restarting the app.
//
// It runs as a task, so that it can wait for the task that creates the default database. The main thread does what it found when the
// task ends (see applyEnsureAutoImport).
//
pub fn ensureAutoImport(services: TaskServices, timers: Timers, io: std.Io, arena: std.mem.Allocator, context: TaskContext, given: main_state.IEnsureAutoImportData) !IEnsureAutoImportResult {
    // A phone does not watch folders. Its automatic import is the background work the page starts and stops (startBackgroundImport and
    // stopBackgroundImport), which reads the device photo library.
    if (builtin.os.tag == .ios or builtin.abi.isAndroid()) {
        return .{
            .action = "none",
        };
    }

    const config = try node_api.app_config.loadAppConfig(arena, io);
    const plan = try node_api.auto_import_desktop.planDesktopAutoImport(arena, config, try node_utils.photo_folders.getDefaultPhotoFolders(arena, io), context.data_dir);

    const planned_settings_json = try json.stringify(arena, try api_zig.auto_import_settings.autoImportSettingsToJson(arena, plan.settings));

    if (!plan.shouldRun) {
        return .{
            .action = "stop",
        };
    }

    // Already running against the right database with the same settings.
    if (given.runningDatabasePath != null and std.mem.eql(u8, given.runningDatabasePath.?, plan.databasePath) and given.runningSettingsJson != null and std.mem.eql(u8, given.runningSettingsJson.?, planned_settings_json)) {
        return .{
            .action = "none",
        };
    }

    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    if (plan.isNewDefault or !(try node_api.media_file_database.checkDatabaseExists(arena, io, plan.databasePath, services.nativeCaller(&requester_storage)))) {
        try createDefaultDatabase(services, timers, io, arena, plan.databasePath);
    }
    return .{
        .action = "start",
        .databasePath = plan.databasePath,
        .settingsJson = planned_settings_json,
        .enabled = plan.settings.enabled,
        .sources = try api_zig.auto_import_settings.autoImportSourcesToJson(arena, plan.settings.sources),
    };
}

//
// ensure-auto-import: the payload is what the main thread knows (IEnsureAutoImportData). Finds out what automatic import should do,
// as ensureAutoImport does, and gives it back as the result. Queued by the main thread at the start and then on every tick of the
// automatic import check (AUTO_IMPORT_RESTART_CHECK_MS), and when a setting of automatic import is written, as a task because it waits
// for the task that creates the default database and only a task can wait. A failure is logged when the task ends (see handleTaskEnd).
//
pub fn ensureAutoImportTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const given = try std.json.parseFromValueLeaky(main_state.IEnsureAutoImportData, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    return try json.stringify(allocator, try ensureAutoImport(services, timers, io, allocator, context, given));
}

//
// Forgets that automatic import is running, and which database and settings it was started with, and returns whether it was running.
//
fn clearAutoImportState(state: *MainState, allocator: std.mem.Allocator) bool {
    const was_running = state.auto_import_running;
    if (was_running) {
        state.auto_import_running = false;
        main_state.freeOwned(allocator, &state.auto_import_database_path);
        main_state.freeOwned(allocator, &state.auto_import_settings_json);
    }
    return was_running;
}

//
// Does what an ensure-auto-import task found automatic import should do: stops it, or starts it into the database it named.
//
fn applyEnsureAutoImport(state: *MainState, services: HandlerServices, io: std.Io, arena: std.mem.Allocator, result_json: []const u8) !void {
    const allocator = main_state.stateAllocator();
    const found = try std.json.parseFromSliceLeaky(IEnsureAutoImportResult, arena, result_json, .{
        .ignore_unknown_fields = true,
    });
    if (std.mem.eql(u8, found.action, "stop")) {
        if (clearAutoImportState(state, allocator)) {
            utils.log.log.info("Stopping automatic import.");
            services.cancelTasks(io, arena, AUTO_IMPORT_TASK_SOURCE);
        }
        return;
    }
    if (!std.mem.eql(u8, found.action, "start") or state.stopping) {
        return;
    }
    const database_path = found.databasePath orelse {
        return utils.errors.throwError("The check of automatic import gave no database to import into.", .{});
    };
    if (clearAutoImportState(state, allocator)) {
        services.cancelTasks(io, arena, AUTO_IMPORT_TASK_SOURCE);
    }

    utils.log.log.info(try std.fmt.allocPrint(arena, "Starting automatic import into \"{s}\".", .{database_path}));
    // The import task itself, fed by a scanner that watches the configured folders. There used to be a separate `auto-import` task that
    // ran a loop and started one of these for every handful of photos it released; one task doing both is what removed that cost.
    const session_id = try state.uuid_generator.uuidGenerator().generate(arena, io);
    const job_id = try std.mem.concat(arena, u8, &.{ "auto-import:", database_path });
    const import_data = try json.stringify(arena, .{
        .paths = [_][]const u8{},
        .storageDescriptor = .{
            .databasePath = database_path,
        },
        .sessionId = session_id,
        .dryRun = false,
        .options = .{
            .auto = true,
            .enabled = found.enabled,
            .sources = found.sources orelse std.json.Value{ .array = std.json.Array.init(arena) },
        },
        .job = .{
            .id = job_id,
            .name = "Automatic import",
            .cancelSource = AUTO_IMPORT_TASK_SOURCE,
        },
    });
    const task_id = try state.uuid_generator.uuidGenerator().generate(arena, io);

    // What is remembered about the task is recorded before the task is queued, because its end is told apart from a manual import's
    // by the remembered id.
    try main_state.setOwned(allocator, &state.auto_import_task_id, task_id);
    state.auto_import_running = true;
    try main_state.setOwned(allocator, &state.auto_import_database_path, database_path);
    try main_state.setOwned(allocator, &state.auto_import_settings_json, found.settingsJson);
    errdefer {
        _ = clearAutoImportState(state, allocator);
        main_state.freeOwned(allocator, &state.auto_import_task_id);
    }
    try services.addTask(io, arena, task_id, "import-assets", AUTO_IMPORT_TASK_SOURCE, import_data, .background);
}

//
// Told when any task ends, on the main thread. Records what the database notifications, the background passes and the check of
// automatic import found, resets syncing when a sync ends, starts the eviction of originals after a sync that succeeded, tells the user
// when an import or a replication fails, registers the destination of a replication that worked, and notices when automatic import
// stops. The page is told of every task's end by the core.
//
pub fn onTaskEnd(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, end: ziggy.types.TaskEnd) void {
    handleTaskEnd(services, timers, io, allocator, end) catch |err| {
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
// What the main process does when a task ends.
//
fn handleTaskEnd(services: HandlerServices, timers: Timers, io: std.Io, arena: std.mem.Allocator, end: ziggy.types.TaskEnd) !void {
    const allocator = main_state.stateAllocator();
    const state = main_state.current();
    if (background_work.Pass.fromTaskType(end.task_type)) |pass| {
        var result: ?background_work.IPassTaskResult = null;
        if (end.status == .succeeded) {
            if (end.result_json) |text| {
                result = try std.json.parseFromSliceLeaky(background_work.IPassTaskResult, arena, text, .{
                    .ignore_unknown_fields = true,
                });
            }
        }
        else if (end.status == .failed) {
            utils.log.log.@"error"(try std.fmt.allocPrint(arena, "The background {s} pass failed: {s}", .{ pass.label(), errorMessageOrUnknown(end.error_message) }));
        }
        state.backgroundPassEnded(services, timers, io, allocator, pass, result);
    }
    if (std.mem.eql(u8, end.task_type, "notify-database-opened") and end.status == .succeeded) {
        const database_path = try std.json.parseFromSliceLeaky([]const u8, arena, end.input_json, .{});
        state.is_database_open = true;
        state.resetSyncState(services, timers, io, allocator, database_path);
        try main_state.setOwned(allocator, &state.current_database_path, database_path);
    }
    if (std.mem.eql(u8, end.task_type, "notify-database-closed") and end.status == .succeeded) {
        state.is_database_open = false;
        state.resetSyncState(services, timers, io, allocator, null);
        main_state.freeOwned(allocator, &state.current_database_path);
    }
    if (std.mem.eql(u8, end.task_type, "startBackgroundImport") and end.status == .succeeded) {
        state.startBackgroundWork(services, timers, io, allocator);
        utils.log.log.info("Started the background automatic import.");
    }
    if (std.mem.eql(u8, end.task_type, "ensure-auto-import")) {
        state.auto_import_starting = false;
        if (end.status == .failed) {
            // The error is logged as 'Error starting automatic import' at startup and 'Error restarting automatic import' on the timer.
            // A task's end carries the text of the error and not the error, so the text follows the message.
            const given = std.json.parseFromSliceLeaky(main_state.IEnsureAutoImportData, arena, end.input_json, .{
                .ignore_unknown_fields = true,
            }) catch main_state.IEnsureAutoImportData{};
            const what = if (given.restarting) "restarting" else "starting";
            utils.log.log.@"error"(try std.fmt.allocPrint(arena, "Error {s} automatic import: {s}", .{ what, errorMessageOrUnknown(end.error_message) }));
        }
        else if (end.status == .succeeded) {
            if (end.result_json) |text| {
                try applyEnsureAutoImport(state, services, io, arena, text);
            }
        }
    }
    if (std.mem.eql(u8, end.task_type, "sync-database")) {
        state.syncStopped();
        if (end.status != .succeeded) {
            try events.sendSyncCompleted(services, io, arena);
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
                    try enqueueEvictOriginals(state, services, io, arena, database_path);
                }
            }
        }
    }
    if (std.mem.eql(u8, end.task_type, "import-assets")) {
        var is_auto_import_task = false;
        if (state.auto_import_task_id) |auto_import_task_id| {
            is_auto_import_task = std.mem.eql(u8, auto_import_task_id, end.task_id);
        }
        if (is_auto_import_task) {
            // Automatic import is not meant to end while the setting is on, so this is either a crash or a cancellation. Either
            // way the app owns restarting it: a task that died silently looks exactly like automatic import finding nothing to
            // do, and used to stay dead until the app was restarted.
            state.auto_import_running = false;
            main_state.freeOwned(allocator, &state.auto_import_task_id);
            main_state.freeOwned(allocator, &state.auto_import_database_path);
            main_state.freeOwned(allocator, &state.auto_import_settings_json);
            if (end.status != .succeeded) {
                utils.log.log.@"error"(try std.fmt.allocPrint(arena, "Automatic import stopped: {s}", .{errorMessageOrUnknown(end.error_message)}));
            }
            return;
        }
        if (end.status == .succeeded) {
            utils.log.log.event("Import task completed");
        }
        else {
            try events.sendShowNotification(services, io, arena, .{
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
            handleReplicateSucceeded(services, io, arena, inputs) catch |err| {
                utils.log.log.exception("Error finalising replicate-database", err);
            };
        }
        else {
            try events.sendShowNotification(services, io, arena, .{
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
// Told when any task sends an event, on the main thread. Sends the page the events a task sends it (events.APP_EVENT_TYPE), queues the
// save-asset task a save-asset-request task requests, holds the computer awake or lets it go for a background pass on Windows and
// MacOS, and tells the page when a sync starts and when it completes. The page is told of every task event by the core.
//
pub fn onTaskEvent(services: HandlerServices, _: Timers, io: std.Io, allocator: std.mem.Allocator, sent: ziggy.types.TaskSentEvent) void {
    handleTaskEvent(services, io, allocator, sent) catch |err| {
        utils.log.log.exception("Error handling a task event", err);
    };
}

fn handleTaskEvent(services: HandlerServices, io: std.Io, arena: std.mem.Allocator, sent: ziggy.types.TaskSentEvent) !void {
    const event = try std.json.parseFromSliceLeaky(std.json.Value, arena, sent.event_json, .{});
    const event_type = json.getString(event, "type") orelse {
        return;
    };
    if (std.mem.eql(u8, event_type, events.APP_EVENT_TYPE)) {
        const page_event = event.object.get("event") orelse {
            return utils.errors.throwError("A task's event for the page has no event.", .{});
        };
        try services.sendEvent(io, arena, try json.stringify(arena, page_event));
    }
    else if (std.mem.eql(u8, event_type, saving_assets.QUEUE_SAVE_ASSET_EVENT_TYPE)) {
        const save_data = event.object.get("data") orelse {
            return utils.errors.throwError("A request to save an asset has no data.", .{});
        };
        const database_path = json.getString(save_data, "databasePath") orelse {
            return utils.errors.throwError("A request to save an asset has no database.", .{});
        };
        const state = main_state.current();
        const task_id = try state.uuid_generator.uuidGenerator().generate(arena, io);
        try services.addTask(io, arena, task_id, "save-asset", database_path, try json.stringify(arena, save_data), .background);
    }
    else if (std.mem.eql(u8, event_type, background_work.HOLD_AWAKE_EVENT_TYPE)) {
        const request = event.object.get("request") orelse {
            return utils.errors.throwError("A request to hold the computer awake has no request.", .{});
        };
        try main_state.current().holdAwake(arena, try json.stringify(arena, request));
    }
    else if (std.mem.eql(u8, event_type, "sync-started")) {
        utils.log.log.event("Sync started");
        try events.sendSyncStarted(services, io, arena);
    }
    else if (std.mem.eql(u8, event_type, "sync-completed")) {
        // The suffix says whether the sync moved anything, which is the only way to tell a sync that ran and found both sides
        // identical from one that pushed changes. "Sync completed" stays the start of the line, so a wait on that text alone still
        // matches.
        const synced_field = if (event == .object) event.object.get("synced") else null;
        const moved_changes = synced_field != null and synced_field.? == .bool and synced_field.?.bool;
        if (moved_changes) {
            utils.log.log.event("Sync completed: changes synced");
        }
        else {
            utils.log.log.event("Sync completed: nothing to sync");
        }
        try events.sendSyncCompleted(services, io, arena);
    }
}

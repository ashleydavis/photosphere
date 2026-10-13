//
// What the main process remembers while the app runs: whether a database is open and which one, whether
// syncing is allowed, whether a sync is running, the debounce and periodic sync timers, and what automatic import is doing. Zig has
// no global process state, so these are one value that the core holds for the app (Ziggy's app state), and
// the handlers reach it through the core or through their task's context.
//
// The timers (the debounce after an edit, the periodic sync for the life of the app, and the check that automatic import
// is still running, which also runs once at the start) are one thread, which wakes often,
// finds out which deadline has passed and does what that timer is for.
//
// ensureAutoImport waits for the task that creates the default database, so it can only run as a task. The timer thread
// queues the `ensure-auto-import` task.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const mobile_worker = @import("mobile-worker-zig");
const media_tools = @import("media-tools-zig");
const node_utils = @import("node-utils-zig");
const storage = @import("storage-zig");
const config = @import("config-zig");
const environment = @import("environment.zig");
const file_logger = @import("file-logger.zig");
const background_work = @import("background-work.zig");
const mcp_bridge = @import("mcp-bridge.zig");
const single_instance = @import("single-instance.zig");

const Core = ziggy.core.Core;
const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// How long the sync debounce waits after the last edit notification, in milliseconds.
//
pub const SYNC_DEBOUNCE_MS = 10_000;

//
// How often the periodic sync runs, in milliseconds.
//
pub const SYNC_PERIODIC_MS = 5 * 60 * 1_000;

//
// How often to check that automatic import is still running, in milliseconds.
//
pub const AUTO_IMPORT_RESTART_CHECK_MS = 30_000;

//
// How long to wait for the asset server to say which port it bound, in milliseconds.
//
pub const ASSET_SERVER_START_TIMEOUT_MS = 60_000;

//
// The source the asset server task is queued under, so cancelling it stops the server.
//
pub const ASSET_SERVER_TASK_SOURCE = "asset-server";

//
// The source the MCP server task is queued under, so cancelling it stops the server.
//
pub const MCP_SERVER_TASK_SOURCE = "mcp-server";

//
// The source the `check-for-update` task is queued under.
//
pub const CHECK_FOR_UPDATE_TASK_SOURCE = "check-for-update";

//
// The source the `check-for-news` task is queued under.
//
pub const CHECK_FOR_NEWS_TASK_SOURCE = "check-for-news";

//
// The source the `ensure-auto-import` task is queued under. It is not the source of the automatic import tasks, because ensureAutoImport
// cancels that source and must not cancel itself.
//
pub const ENSURE_AUTO_IMPORT_TASK_SOURCE = "ensure-auto-import";

//
// The input of the `ensure-auto-import` task queued by mainWindowCreated, the call of ensureAutoImport at startup.
//
pub const ENSURE_AUTO_IMPORT_STARTING_INPUT = "\"starting\"";

//
// The input of the `ensure-auto-import` task queued on every tick of the check, the call from the automatic import restart timer.
//
pub const ENSURE_AUTO_IMPORT_RESTARTING_INPUT = "\"restarting\"";

//
// How often the timer thread looks at the deadlines, in milliseconds.
//
const TIMER_TICK_MS = 20;

//
// How often the first copy of the app looks for the signal a second copy leaves, in milliseconds.
//
pub const SINGLE_INSTANCE_CHECK_MS = 500;

//
// What the main process remembers.
//
pub const MainState = struct {
    // Allocates everything the state owns.
    allocator: std.mem.Allocator,
    // The core the state belongs to, for the task runner and for sending events.
    core: *Core,
    // The Io the timer thread sleeps with and the mutex is used with.
    io: std.Io,
    // Guards every field below except `stopping`.
    mutex: std.Io.Mutex,
    // Whether a database is currently open. Nothing reads it, because
    // Ziggy's menu is written once and the page decides what each item does, but the page's notifications keep it true to the app.
    is_database_open: bool,
    // The path of the database that is open, or null when none is (`currentDatabasePath`). Owned by the state.
    current_database_path: ?[]u8,
    // Whether the page's computed decision currently allows syncing automatically (`syncAllowed`). Starts false and is set when the
    // page sends set-sync-allowed.
    sync_allowed: bool,
    // Whether a sync task is queued or running (`isSyncRunning`).
    is_sync_running: bool,
    // When the debounced sync is due, in milliseconds of the awake clock, or null when none is waiting (`syncDebounceTimer`).
    sync_debounce_at: ?i64,
    // When the periodic sync is next due, or null before it is started or after it is stopped (`syncPeriodicTimer`).
    sync_periodic_at: ?i64,
    // When automatic import is next checked (at startup and then on the restart timer), or null
    // before the main window has been created, which is when both start. Due at once when armed, then every
    // `auto_import_check_ms`.
    auto_import_check_at: ?i64,
    // How often automatic import is checked. A field so that a test can shorten it.
    auto_import_check_ms: i64,
    // How long the debounce waits. A field so that a test can shorten it.
    sync_debounce_ms: i64,
    // How often the periodic sync runs. A field so that a test can shorten it.
    sync_periodic_ms: i64,
    // Whether automatic import is running (`autoImportRunning`).
    auto_import_running: bool,
    // The id of the running automatic import task, or null (`autoImportTaskId`). Owned by the state.
    auto_import_task_id: ?[]u8,
    // The database automatic import is writing to, or null (`autoImportDatabasePath`). Owned by the state.
    auto_import_database_path: ?[]u8,
    // The settings the running automatic import was started with, as JSON, or null (`autoImportSettingsJson`). Owned by the state.
    auto_import_settings_json: ?[]u8,
    // Set while ensureAutoImport is part way through, so two config writes arriving together do not both create the default database
    // (`autoImportStarting`).
    auto_import_starting: bool,
    // Whether the checks made once the page has loaded (for an update and for news) have been queued, which happens once.
    startup_checks_queued: bool,
    // Whether the asset server task has been queued.
    asset_server_requested: bool,
    // The port the asset server bound, from its asset-server-ready message, or 0 before that (`restApiPort`).
    asset_server_port: u16,
    // Set when the asset server task ended, so a wait for its port can stop waiting for a message that will never come.
    asset_server_ended: bool,
    // Why the asset server ended before it said which port it bound, or null when it did not end that way. Owned by the state.
    asset_server_error: ?[]u8,
    // How long to wait for the asset server to say which port it bound. A field so that a test can shorten it.
    asset_server_start_timeout_ms: i64,
    // The meeting point of the MCP server and the page, which holds the tool calls waiting for the page and the port the server bound.
    mcp_bridge: mcp_bridge.McpBridge,
    // The lock this copy holds so that no other copy runs, or null when the rule does not apply to it (a build with no version, a test or a phone).
    single_instance: ?single_instance.SingleInstance,
    // When the signal of a second copy is next looked for, or null when this copy holds no lock.
    single_instance_check_at: ?i64,
    // Which of the phone's background loops (see background-work.zig) are queued or running, by loop, so starting one that is already
    // running does nothing and one that ended is started again.
    background_loops_running: [background_work.LOOP_COUNT]bool,
    // What the last completed background prefetch pass said about the replica, which the background sync loop holds back for.
    prefetch_replica_state: std.atomic.Value(background_work.ReplicaState),
    // Makes the ids of the tasks the main process queues.
    uuid_generator: utils.random_uuid_generator.RandomUuidGenerator,
    // Tells the timer thread to end.
    stopping: std.atomic.Value(bool),
    // The timer thread.
    timer_thread: ?std.Thread,
    // The tools built into the program (ImageMagick), started before the file logger and stopped after it. Owned.
    media_tools: *media_tools.MediaTools,
    // The file logger (`fileLogger`), made first when the state is made and closed last when the core is destroyed. Owned.
    logger: *file_logger.FileLogger,
    // The log that was installed before the file logger took its place, put back when the file logger is closed.
    previous_log: utils.log.ILog,

    //
    // Makes the state and starts the periodic sync, which runs for the life of the app.
    //
    pub fn create(core: *Core) anyerror!*MainState {
        // A core a shell hosts has no `main` to hand it the environment, so it is read from the process (see environment.zig). The map
        // stays for the life of the process, because the tasks still running while the core is destroyed read it too.
        _ = try environment.adoptProcessEnvironment(core.allocator);
        // ImageMagick is built into the program and runs in its process, for the tasks (through the queue backend) and for the file
        // logger's header, which asks it for its version.
        const media = try core.allocator.create(media_tools.MediaTools);
        errdefer core.allocator.destroy(media);
        media.* = media_tools.MediaTools.init(core.io());
        errdefer media.deinit();
        core.queue_backend.tool_runner = media.runner();
        // The file logger is made first so everything after it is logged.
        const previous_log = utils.log.log;
        const logger = try startFileLogger(core.allocator, core.io(), media.runner());
        errdefer stopFileLogger(logger, previous_log);
        // The task handlers register with Ziggy's task queue, which is where the runner finds them.
        try node_api.task_handlers.initTaskHandlers();
        // A phone has a photo library to import from, which only its shell can read.
        if (core.config.host_request != null) {
            try mobile_worker.device_media_source.registerDeviceMediaSourceBuilder();
        }
        utils.console.log("Worker pool initialized");
        const state = try core.allocator.create(MainState);
        errdefer core.allocator.destroy(state);
        state.* = .{
            .media_tools = media,
            .logger = logger,
            .previous_log = previous_log,
            .allocator = core.allocator,
            .core = core,
            .io = core.io(),
            .mutex = .init,
            .is_database_open = false,
            .current_database_path = null,
            .sync_allowed = false,
            .is_sync_running = false,
            .sync_debounce_at = null,
            .sync_periodic_at = null,
            .auto_import_check_at = null,
            .auto_import_check_ms = AUTO_IMPORT_RESTART_CHECK_MS,
            .sync_debounce_ms = SYNC_DEBOUNCE_MS,
            .sync_periodic_ms = SYNC_PERIODIC_MS,
            .auto_import_running = false,
            .auto_import_task_id = null,
            .auto_import_database_path = null,
            .auto_import_settings_json = null,
            .auto_import_starting = false,
            .startup_checks_queued = false,
            .asset_server_requested = false,
            .asset_server_port = 0,
            .asset_server_ended = false,
            .asset_server_error = null,
            .asset_server_start_timeout_ms = ASSET_SERVER_START_TIMEOUT_MS,
            .mcp_bridge = mcp_bridge.McpBridge.init(core.allocator, core.io()),
            .single_instance = null,
            .single_instance_check_at = null,
            .background_loops_running = [_]bool{false} ** background_work.LOOP_COUNT,
            .prefetch_replica_state = .init(.unknown),
            .uuid_generator = .{},
            .stopping = .init(false),
            .timer_thread = null,
        };
        try state.applySingleInstanceRule();
        state.startPeriodicSync();
        state.timer_thread = try std.Thread.spawn(.{}, timerMain, .{state});
        return state;
    }

    //
    // Does what is needed before the worker pool goes: stops the periodic sync, cancels the automatic
    // import task if one is running, clears the debounce, and logs that the app is shutting down. Then stops the timer thread.
    // The state stays valid, because tasks that are still running read it.
    //
    pub fn stop(self: *MainState) void {
        // Set first, so that nothing the stopping tasks do restarts the asset server.
        self.stopping.store(true, .release);
        self.stopPeriodicSync();
        var cancel_auto_import = false;
        {
            self.lock();
            defer self.unlock();
            // The automatic import task holds filesystem watchers and a temporary directory, so it is told to stop before the worker pool
            // goes away under it.
            if (self.auto_import_running) {
                cancel_auto_import = true;
                self.auto_import_running = false;
                self.freeOwned(&self.auto_import_database_path);
            }
            self.sync_debounce_at = null;
        }
        if (cancel_auto_import) {
            self.core.runner.cancelSource(node_api.auto_import_desktop.AUTO_IMPORT_TASK_SOURCE);
        }
        self.logger.handleWorkerLogMessage(.{
            .level = .info,
            .message = "Photosphere Desktop shutting down...",
            .@"error" = null,
            .tool_data = null,
        }, "Main") catch |err| {
            utils.log.log.exception("Could not log that the app is shutting down", err);
        };
        if (self.timer_thread) |thread| {
            thread.join();
            self.timer_thread = null;
        }
    }

    //
    // Takes the right to start a background loop. Returns true when the loop was not queued or running, in which case the caller must
    // queue it (and give the right back with releaseBackgroundLoop if it cannot), and false when it already is.
    //
    pub fn claimBackgroundLoop(self: *MainState, loop: background_work.Loop) bool {
        self.lock();
        defer self.unlock();
        const index = @intFromEnum(loop);
        if (self.background_loops_running[index]) {
            return false;
        }
        self.background_loops_running[index] = true;
        return true;
    }

    //
    // Says a background loop is no longer queued or running, because its task ended.
    //
    pub fn releaseBackgroundLoop(self: *MainState, loop: background_work.Loop) void {
        self.lock();
        defer self.unlock();
        self.background_loops_running[@intFromEnum(loop)] = false;
    }

    //
    // Releases everything the state owns, after the task runner has stopped. The file logger is closed last
    // to capture all shutdown logs, and the log that was installed before it takes its place again.
    //
    pub fn destroy(self: *MainState) void {
        self.freeOwned(&self.current_database_path);
        self.freeOwned(&self.auto_import_task_id);
        self.freeOwned(&self.auto_import_database_path);
        self.freeOwned(&self.auto_import_settings_json);
        self.freeOwned(&self.asset_server_error);
        self.mcp_bridge.deinit();
        if (self.single_instance) |*instance| {
            instance.release(self.io);
        }
        stopFileLogger(self.logger, self.previous_log);
        self.media_tools.deinit();
        self.allocator.destroy(self.media_tools);
        self.allocator.destroy(self);
    }

    //
    // The time now, in milliseconds of the awake clock.
    //
    pub fn now(self: *MainState) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    //
    // Replaces a string the state owns with a copy of a new one, or with null, freeing the old one. The caller holds the mutex, or is
    // the only user of the state.
    //
    pub fn setOwned(self: *MainState, field: *?[]u8, value: ?[]const u8) !void {
        const copy: ?[]u8 = if (value) |text| try self.allocator.dupe(u8, text) else null;
        if (field.*) |old| {
            self.allocator.free(old);
        }
        field.* = copy;
    }

    //
    // Frees a string the state owns and sets it to null. The caller holds the mutex, or is the only user of the state.
    //
    pub fn freeOwned(self: *MainState, field: *?[]u8) void {
        if (field.*) |old| {
            self.allocator.free(old);
        }
        field.* = null;
    }

    //
    // Takes the mutex that guards the state.
    //
    pub fn lock(self: *MainState) void {
        self.mutex.lockUncancelable(self.io);
    }

    //
    // Releases the mutex that guards the state.
    //
    pub fn unlock(self: *MainState) void {
        self.mutex.unlock(self.io);
    }

    //
    // Resets the isSyncRunning flag. Called when a sync task finishes (success, skip, or failure).
    //
    pub fn syncStopped(self: *MainState) void {
        self.lock();
        defer self.unlock();
        self.is_sync_running = false;
    }

    //
    // Cancels any running sync task for the current database, resets the running flag, and clears the debounce timer. Call this whenever
    // the active database changes.
    //
    // next_database_path is the database about to become active, or null when none is. Tasks are cancelled only when that is a
    // different database from the one running now. Cancelling is by database path, and the load that fills the gallery is tagged with
    // that same path, so cancelling on a reopen of the database already open kills the load the page has just started for it.
    //
    pub fn resetSyncState(self: *MainState, next_database_path: ?[]const u8) !void {
        var to_cancel: ?[]u8 = null;
        defer if (to_cancel) |path| self.allocator.free(path);
        {
            self.lock();
            defer self.unlock();
            // (`currentDatabasePath &&` is false for an empty path as well as for none.)
            if (self.current_database_path) |current| {
                const next_is_different = if (next_database_path) |next| !std.mem.eql(u8, current, next) else true;
                if (current.len > 0 and next_is_different) {
                    to_cancel = try self.allocator.dupe(u8, current);
                }
            }
        }
        if (to_cancel) |path| {
            self.core.runner.cancelSource(path);
        }
        self.lock();
        defer self.unlock();
        self.is_sync_running = false;
        self.sync_debounce_at = null;
    }

    //
    // Schedules a debounced sync after the last edit notification. Resets the debounce timer if called again before it fires.
    //
    pub fn scheduleSync(self: *MainState) void {
        utils.log.log.info("Sync debounce triggered");
        self.lock();
        defer self.unlock();
        self.sync_debounce_at = self.now() + self.sync_debounce_ms;
    }

    //
    // Starts the periodic sync timer. It runs for the lifetime of the app. A second call changes nothing.
    //
    pub fn startPeriodicSync(self: *MainState) void {
        self.lock();
        defer self.unlock();
        if (self.sync_periodic_at != null) {
            return;
        }
        self.sync_periodic_at = self.now() + self.sync_periodic_ms;
    }

    //
    // Stops the periodic sync timer.
    //
    pub fn stopPeriodicSync(self: *MainState) void {
        self.lock();
        defer self.unlock();
        self.sync_periodic_at = null;
    }

    //
    // Queues a sync task if a database is open and no sync is already running. Connectivity checking and the sync-started and
    // sync-completed messages are the task's responsibility.
    //
    // When the task cannot be queued the running flag is put back before the error is returned, otherwise the flag would stay
    // set and no sync would ever run again.
    //
    pub fn enqueueSyncTask(self: *MainState) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var database_path: []u8 = undefined;
        {
            self.lock();
            defer self.unlock();
            // Never auto-sync unless the page's decision permits it (sync enabled, online, and the Wi-Fi restriction satisfied).
            // (`!currentDatabasePath` is true for an empty path as well as for none.)
            if (!self.sync_allowed or self.current_database_path == null or self.current_database_path.?.len == 0 or self.is_sync_running) {
                return;
            }
            self.is_sync_running = true;
            database_path = try arena.dupe(u8, self.current_database_path.?);
        }
        errdefer self.syncStopped();
        utils.log.log.info(try std.fmt.allocPrint(arena, "Queuing sync task for \"{s}\"", .{database_path}));
        // No cancel source: the page lists this job but must not be able to stop it, because syncing is switched off from Settings and
        // a sync cancelled from a list would start again on the next timer anyway.
        const job_id = try std.mem.concat(arena, u8, &.{ "sync:", database_path });
        const sync_data = try json_util.stringify(arena, .{
            .databasePath = database_path,
            .job = .{
                .id = job_id,
                .name = "Syncing database",
            },
        });
        const task_id = try self.uuid_generator.generate(arena, self.io);
        try self.core.runner.addTask(task_id, "sync-database", database_path, sync_data, .background, null);
    }

    //
    // Starts the asset server the first time it is called and returns the port the server bound, once the
    // server has said so. The page needs the address before it can render, so the page's query asks for it. A later call returns the
    // port without starting another server. The port is the OS's choice, because the server is asked for port 0.
    //
    // The server is a task and the message is its
    // asset-server-ready message, which onTaskMessage records. A server that ended before it said anything, or that said nothing for
    // as long as the timeout, is an error the page's query reports.)
    //
    pub fn startAssetServer(self: *MainState) !u16 {
        var needs_task = false;
        {
            self.lock();
            defer self.unlock();
            if (!self.asset_server_requested) {
                self.asset_server_requested = true;
                needs_task = true;
            }
        }
        if (needs_task) {
            try self.queueAssetServer(0);
        }
        const deadline = self.now() + self.asset_server_start_timeout_ms;
        while (true) {
            {
                self.lock();
                defer self.unlock();
                if (self.asset_server_port != 0) {
                    return self.asset_server_port;
                }
                if (self.asset_server_ended) {
                    return utils.errors.throwError("REST API failed to start: {s}", .{self.asset_server_error orelse "the asset server ended before it said which port it was using"});
                }
            }
            if (self.now() >= deadline) {
                return utils.errors.throwError("REST API failed to start within timeout", .{});
            }
            try self.io.sleep(.fromMilliseconds(TIMER_TICK_MS), .awake);
        }
    }

    //
    // Takes the lock that keeps a second copy of the packaged app from running, or, when another copy holds it, logs that this one is quitting
    // and asks the shell to quit. The rule does not apply to a build with no version, a test or a phone, which all log that the lock was acquired.
    //
    pub fn applySingleInstanceRule(self: *MainState) !void {
        try self.enforceSingleInstance(single_instance.ruleApplies());
    }

    //
    // Does what applySingleInstanceRule does once it has decided whether the rule applies to this copy.
    //
    pub fn enforceSingleInstance(self: *MainState, rule_applies: bool) !void {
        const pid = storage.storage.processId();
        const packaged: []const u8 = if (single_instance.isUnpackaged()) "false" else "true";
        if (rule_applies) {
            switch (try single_instance.acquire(self.allocator, self.io, std.mem.span(self.core.config.data_dir))) {
                .acquired => |instance| {
                    self.lock();
                    defer self.unlock();
                    self.single_instance = instance;
                    self.single_instance_check_at = self.now() + SINGLE_INSTANCE_CHECK_MS;
                },
                .denied => {
                    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena_state.deinit();
                    utils.log.log.event(try std.fmt.allocPrint(arena_state.allocator(), "Single instance lock denied (pid={d}, packaged={s}); quitting", .{ pid, packaged }));
                    const quit = self.core.config.quit orelse {
                        return utils.errors.throwError("Another copy of the app is running and this platform gives no way to quit this one.", .{});
                    };
                    quit(self.core.config.user_data);
                    return;
                },
            }
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        utils.log.log.event(try std.fmt.allocPrint(arena_state.allocator(), "Single instance lock acquired (pid={d}, packaged={s})", .{ pid, packaged }));
    }

    //
    // Looks for the signal a second copy of the app leaves when it is started and quits, and brings this copy's window to the front when it is
    // there. The shell does the bringing to the front, as the `focus-window` action.
    //
    pub fn checkSecondInstance(self: *MainState) !void {
        const instance = if (self.single_instance) |*held| held else {
            return;
        };
        if (!try instance.takeSignal(self.io)) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        utils.log.log.event(try std.fmt.allocPrint(arena_state.allocator(), "Second-instance signal received by pid={d}", .{storage.storage.processId()}));
        const menu_action = self.core.config.menu_action orelse {
            return;
        };
        menu_action(self.core.config.user_data, "focus-window");
    }

    //
    // Looks at the deadlines and does what a timer's callback did for each one that has passed.
    //
    fn runDueTimers(self: *MainState) void {
        var run_debounced = false;
        var run_periodic = false;
        var run_auto_import_check = false;
        var run_single_instance_check = false;
        {
            self.lock();
            defer self.unlock();
            const current = self.now();
            if (self.single_instance_check_at) |due| {
                if (current >= due) {
                    self.single_instance_check_at = current + SINGLE_INSTANCE_CHECK_MS;
                    run_single_instance_check = true;
                }
            }
            if (self.auto_import_check_at) |due| {
                if (current >= due) {
                    self.auto_import_check_at = current + self.auto_import_check_ms;
                    run_auto_import_check = true;
                }
            }
            if (self.sync_debounce_at) |due| {
                if (current >= due) {
                    self.sync_debounce_at = null;
                    run_debounced = true;
                }
            }
            if (self.sync_periodic_at) |due| {
                if (current >= due) {
                    self.sync_periodic_at = current + self.sync_periodic_ms;
                    run_periodic = true;
                }
            }
        }
        if (run_debounced or run_periodic) {
            self.enqueueSyncTask() catch |err| {
                utils.log.log.exception("Error queuing a sync task", err);
            };
        }
        if (run_auto_import_check) {
            self.enqueueEnsureAutoImportTask(true) catch |err| {
                utils.log.log.exception("Error queuing the check that automatic import is running", err);
            };
        }
        if (run_single_instance_check) {
            self.checkSecondInstance() catch |err| {
                utils.log.log.exception("Error looking for a second instance of the app", err);
            };
        }
    }

    //
    // Queues the task that makes automatic import match the config. The task's input says whether it
    // is the call at startup or a tick of the check, which are worded differently when it fails ('Error starting automatic import'
    // and 'Error restarting automatic import').
    //
    pub fn enqueueEnsureAutoImportTask(self: *MainState, restarting: bool) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const task_id = try self.uuid_generator.generate(arena_state.allocator(), self.io);
        const data_json: []const u8 = if (restarting) ENSURE_AUTO_IMPORT_RESTARTING_INPUT else ENSURE_AUTO_IMPORT_STARTING_INPUT;
        try self.core.runner.addTask(task_id, "ensure-auto-import", ENSURE_AUTO_IMPORT_TASK_SOURCE, data_json, .background, null);
    }

    //
    // Does what is needed once the main window has been created: logs that the main window was created, makes
    // automatic import match the config, and starts the check that keeps it running. The page's query starts the asset server
    // and reads the theme, so it calls this when it has built the query. Only the
    // first call does anything, because these steps run once and a window made again later does not repeat them.
    //
    pub fn mainWindowCreated(self: *MainState) !void {
        {
            self.lock();
            defer self.unlock();
            if (self.auto_import_check_at != null) {
                return;
            }
            self.auto_import_check_at = self.now() + self.auto_import_check_ms;
        }
        utils.log.log.event("Main window created");
        // Automatic import picks up where it left off, so a machine that was backing photos up before it was shut down carries on
        // without the user having to open anything.
        try self.enqueueEnsureAutoImportTask(false);
        // A phone has no MCP server. A server that cannot start is not worth stopping the app for, so the app carries on without it.
        if (builtin.os.tag != .ios and !builtin.abi.isAndroid()) {
            self.queueMcpServer() catch |err| {
                utils.log.log.exception("MCP server failed to start, continuing without it", err);
            };
        }
    }

    //
    // Does what is needed once the page has loaded and is listening for events: queues the check for a newer release (on a desktop, as
    // a phone is updated by its store) and the check of the news feed, which announce what they find to the page as events. Only the
    // first call does anything, because the checks run once however many times the page loads.
    //
    pub fn pageLoaded(self: *MainState) !void {
        {
            self.lock();
            defer self.unlock();
            if (self.startup_checks_queued) {
                return;
            }
            self.startup_checks_queued = true;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        if (builtin.os.tag != .ios and !builtin.abi.isAndroid()) {
            const update_task_id = try self.uuid_generator.generate(arena_state.allocator(), self.io);
            try self.core.runner.addTask(update_task_id, "check-for-update", CHECK_FOR_UPDATE_TASK_SOURCE, "null", .background, null);
        }
        const news_task_id = try self.uuid_generator.generate(arena_state.allocator(), self.io);
        try self.core.runner.addTask(news_task_id, "check-for-news", CHECK_FOR_NEWS_TASK_SOURCE, "null", .background, null);
    }

    //
    // Queues the task that is the MCP server.
    //
    pub fn queueMcpServer(self: *MainState) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const task_id = try self.uuid_generator.generate(arena_state.allocator(), self.io);
        try self.core.runner.addTask(task_id, "mcp-server", MCP_SERVER_TASK_SOURCE, "null", .background, null);
    }

    //
    // Queues the task that is the asset server, asking it to bind the port. The port is 0 on the first start, so that the operating system chooses a free one, and the
    // port already chosen on a restart, so that the address the page was loaded with stays valid.
    //
    pub fn queueAssetServer(self: *MainState, port: u16) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const data_json = try json_util.stringify(arena, .{
            .port = port,
        });
        const task_id = try self.uuid_generator.generate(arena, self.io);
        try self.core.runner.addTask(task_id, "asset-server", ASSET_SERVER_TASK_SOURCE, data_json, .background, null);
    }
};

//
// The timer thread.
//
fn timerMain(state: *MainState) void {
    while (!state.stopping.load(.acquire)) {
        state.io.sleep(.fromMilliseconds(TIMER_TICK_MS), .awake) catch {
            return;
        };
        state.runDueTimers();
    }
}

//
// The main process's state, from the core a handler runs in.
//
pub fn fromCore(core: *Core) *MainState {
    return @ptrCast(@alignCast(core.app_state.?));
}

//
// The main process's state, from the context of a task.
//
pub fn fromContext(context: *TaskContext) *MainState {
    return @ptrCast(@alignCast(context.appState().?));
}

//
// Makes the file logger and installs it as the log first, then logs that the app is starting. The
// logs are in the `logs` folder of PHOTOSPHERE_LOG_DIR, or of `photosphere` in the operating system's temporary folder when it is not
// set.
//
// The tasks run in this process and write to the log themselves, so the file logger is the log.
// A build that has been given a version is the packaged one.
//
fn startFileLogger(allocator: std.mem.Allocator, io: std.Io, tool_runner: ?node_utils.in_process_tools.InProcessRunner) !*file_logger.FileLogger {
    var log_root: []const u8 = "";
    if (node_utils.process_env.getEnv("PHOTOSPHERE_LOG_DIR")) |directory| {
        log_root = directory;
    }
    var tmp_root: ?[]const u8 = null;
    defer if (tmp_root) |text| allocator.free(text);
    if (log_root.len == 0) {
        tmp_root = try std.fs.path.join(allocator, &.{ try node_utils.fs.osTmpDir(allocator), "photosphere" });
        log_root = tmp_root.?;
    }
    const logs_dir = try std.fs.path.join(allocator, &.{ log_root, "logs" });
    defer allocator.free(logs_dir);
    const logger = try file_logger.FileLogger.init(allocator, io, tool_runner, logs_dir, config.version);
    errdefer logger.deinit();
    utils.log.setLog(logger.ilog());
    try logger.handleWorkerLogMessage(.{
        .level = .info,
        .message = "Photosphere Desktop starting...",
        .@"error" = null,
        .tool_data = null,
    }, "Main");
    const packaged = !std.mem.eql(u8, config.version, "dev");
    const started = try std.fmt.allocPrint(allocator, "Instance started (pid={d}, packaged={s})", .{ storage.storage.processId(), if (packaged) "true" else "false" });
    defer allocator.free(started);
    utils.log.log.event(started);
    return logger;
}

//
// Puts back the log that was installed before the file logger and closes the file logger, which writes the end of both files and waits
// for everything queued to be written.
//
fn stopFileLogger(logger: *file_logger.FileLogger, previous_log: utils.log.ILog) void {
    utils.log.setLog(previous_log);
    logger.deinit();
}

fn createForCore(core: *Core) anyerror!*anyopaque {
    return try MainState.create(core);
}

fn stopForCore(core: *Core, state: *anyopaque) void {
    _ = core;
    const main_state: *MainState = @ptrCast(@alignCast(state));
    main_state.stop();
}

fn destroyForCore(core: *Core, state: *anyopaque) void {
    _ = core;
    const main_state: *MainState = @ptrCast(@alignCast(state));
    main_state.destroy();
}

//
// How the core makes, stops and destroys the state.
//
pub const state_hooks = ziggy.core.AppState{
    .create = createForCore,
    .stop = stopForCore,
    .destroy = destroyForCore,
};

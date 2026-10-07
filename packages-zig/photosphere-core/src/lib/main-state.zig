//
// What the main process of apps/desktop/src/main.ts remembers while the app runs: whether a database is open and which one, whether
// syncing is allowed, whether a sync is running, the debounce and periodic sync timers, and what automatic import is doing. In the
// Electron app these are module-level variables; here they are one value that the core holds for the app (Ziggy's app state), and
// the handlers reach it through the core or through their task's context.
//
// The timers of `main.ts` (the debounce after an edit, the periodic sync for the life of the app, and the check that automatic import
// is still running, which also runs once at the start) are one thread here, which wakes often,
// finds out which deadline has passed and does what the timer's callback did.
//
// (Zig: ensureAutoImport waits for the task that creates the default database, so it can only run as a task. The timer thread
// queues the `ensure-auto-import` task where main.ts called the function.)
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");

const Core = ziggy.core.Core;
const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// How long the sync debounce waits after the last edit notification, in milliseconds (`10_000` in scheduleSync of main.ts).
//
pub const SYNC_DEBOUNCE_MS = 10_000;

//
// How often the periodic sync runs, in milliseconds (`5 * 60 * 1_000` in startPeriodicSync of main.ts).
//
pub const SYNC_PERIODIC_MS = 5 * 60 * 1_000;

//
// How often to check that automatic import is still running, in milliseconds (`AUTO_IMPORT_RESTART_CHECK_MS` in main.ts).
//
pub const AUTO_IMPORT_RESTART_CHECK_MS = 30_000;

//
// The source the `ensure-auto-import` task is queued under. It is not the source of the automatic import tasks, because ensureAutoImport
// cancels that source and must not cancel itself.
//
pub const ENSURE_AUTO_IMPORT_TASK_SOURCE = "ensure-auto-import";

//
// How often the timer thread looks at the deadlines, in milliseconds. (No TypeScript counterpart: Node wakes a timer at its time.)
//
const TIMER_TICK_MS = 20;

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
    // Whether a database is currently open (`isDatabaseOpen`, which the menu state reads in main.ts). Nothing reads it here, because
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
    // When automatic import is next checked (`ensureAutoImport()` at startup and the `autoImportRestartTimer` of main.ts). Due at the
    // start, then every `auto_import_check_ms`.
    auto_import_check_at: i64,
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
    // Makes the ids of the tasks the main process queues.
    uuid_generator: utils.random_uuid_generator.RandomUuidGenerator,
    // Tells the timer thread to end.
    stopping: std.atomic.Value(bool),
    // The timer thread.
    timer_thread: ?std.Thread,

    //
    // Makes the state and starts the periodic sync (`startPeriodicSync()` after `initWorkers()` in main.ts), which runs for the life of the app.
    //
    pub fn create(core: *Core) anyerror!*MainState {
        const state = try core.allocator.create(MainState);
        errdefer core.allocator.destroy(state);
        state.* = .{
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
            .auto_import_check_at = 0,
            .auto_import_check_ms = AUTO_IMPORT_RESTART_CHECK_MS,
            .sync_debounce_ms = SYNC_DEBOUNCE_MS,
            .sync_periodic_ms = SYNC_PERIODIC_MS,
            .auto_import_running = false,
            .auto_import_task_id = null,
            .auto_import_database_path = null,
            .auto_import_settings_json = null,
            .auto_import_starting = false,
            .uuid_generator = .{},
            .stopping = .init(false),
            .timer_thread = null,
        };
        state.startPeriodicSync();
        state.timer_thread = try std.Thread.spawn(.{}, timerMain, .{state});
        return state;
    }

    //
    // Stops the timer thread and releases everything the state owns.
    //
    pub fn destroy(self: *MainState) void {
        self.stopping.store(true, .release);
        if (self.timer_thread) |thread| {
            thread.join();
        }
        self.freeOwned(&self.current_database_path);
        self.freeOwned(&self.auto_import_task_id);
        self.freeOwned(&self.auto_import_database_path);
        self.freeOwned(&self.auto_import_settings_json);
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
            if (self.current_database_path) |current| {
                const next_is_different = if (next_database_path) |next| !std.mem.eql(u8, current, next) else true;
                if (next_is_different) {
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
    // (Zig: when the task cannot be queued the running flag is put back before the error is returned. main.ts sets the flag, then calls
    // addTask, and a throw there would leave the flag set so that no sync ever ran again.)
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
            if (!self.sync_allowed or self.current_database_path == null or self.is_sync_running) {
                return;
            }
            self.is_sync_running = true;
            database_path = try arena.dupe(u8, self.current_database_path.?);
        }
        errdefer self.syncStopped();
        utils.log.log.info(try std.fmt.allocPrint(arena, "Queuing sync task for \"{s}\"", .{database_path}));
        // No cancel source: the page lists this job but must not be able to stop it, because syncing is switched off from Settings and
        // a sync cancelled from a list would start again on the next timer anyway.
        const job_id = try std.fmt.allocPrint(arena, "sync:{s}", .{database_path});
        const sync_data = try json_util.stringify(arena, .{
            .databasePath = database_path,
            .job = .{
                .id = job_id,
                .name = "Syncing database",
            },
        });
        const task_id = try self.uuid_generator.generate(arena, self.io);
        try self.core.runner.addTask(task_id, "sync-database", database_path, sync_data, 0, null);
    }

    //
    // Looks at the deadlines and does what a timer's callback did for each one that has passed.
    //
    fn runDueTimers(self: *MainState) void {
        var run_debounced = false;
        var run_periodic = false;
        var run_auto_import_check = false;
        {
            self.lock();
            defer self.unlock();
            const current = self.now();
            if (current >= self.auto_import_check_at) {
                self.auto_import_check_at = current + self.auto_import_check_ms;
                run_auto_import_check = true;
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
            self.enqueueEnsureAutoImportTask() catch |err| {
                utils.log.log.exception("Error queuing the check that automatic import is running", err);
            };
        }
    }

    //
    // Queues the task that makes automatic import match the config (`ensureAutoImport()` of main.ts, called at startup and on every
    // tick of the check).
    //
    pub fn enqueueEnsureAutoImportTask(self: *MainState) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const task_id = try self.uuid_generator.generate(arena_state.allocator(), self.io);
        try self.core.runner.addTask(task_id, "ensure-auto-import", ENSURE_AUTO_IMPORT_TASK_SOURCE, "null", 0, null);
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

fn createForCore(core: *Core) anyerror!*anyopaque {
    return try MainState.create(core);
}

fn destroyForCore(core: *Core, state: *anyopaque) void {
    _ = core;
    const main_state: *MainState = @ptrCast(@alignCast(state));
    main_state.destroy();
}

//
// How the core makes and destroys the state.
//
pub const state_hooks = ziggy.core.AppState{
    .create = createForCore,
    .destroy = destroyForCore,
};

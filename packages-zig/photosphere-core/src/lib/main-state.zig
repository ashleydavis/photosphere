//
// What the main process remembers while the app runs: whether a database is open and which one, whether
// syncing is allowed, whether a sync is running, the debounce and periodic sync timers, what automatic import is doing, the background
// work, and the asset server and MCP server. These are one value, made by onCreate when Ziggy creates the core and freed by onDestroy
// when Ziggy destroys it. Only the main thread uses it, with the handler services each function is given, so it needs no lock. A task
// never reaches it: it gets what it needs in its data, and the main thread applies what it sends back (see main-process.zig).
//
// The timers (the debounce after an edit, the periodic sync for the life of the app, the check that automatic import is still running,
// the look for a second copy of the app and the background passes) are the main thread's timers, whose callbacks run on the main
// thread, as in the TypeScript app.
//
// ensureAutoImport waits for the task that creates the default database, so it runs as a task, the `ensure-auto-import` task, and the
// main thread does what its result names.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const mobile_worker = @import("mobile-worker-zig");
const media_tools = @import("media-tools-zig");
const node_utils = @import("node-utils-zig");
const storage = @import("storage-zig");
const config = @import("config-zig");
const environment = @import("environment.zig");
const tools = @import("tools-zig");
const background_work = @import("background-work.zig");
const mcp_server = @import("mcp-server.zig");
const single_instance = @import("single-instance.zig");
const windows_native_calls = @import("windows-native-calls.zig");
const macos_native_calls = @import("macos-native-calls.zig");

const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const TimerId = ziggy.core.TimerId;
const json = ziggy.json;
const ThreadAllocator = ziggy.utils.thread_allocator.ThreadAllocator;

//
// How long the debounce waits after the last edit before a sync, in milliseconds.
//
pub const SYNC_DEBOUNCE_MS = 10_000;

//
// How often the periodic sync runs, in milliseconds.
//
pub const SYNC_PERIODIC_MS = 5 * 60 * 1_000;

//
// How often the app checks that automatic import is running when it should be, in milliseconds.
//
pub const AUTO_IMPORT_RESTART_CHECK_MS = 30_000;

//
// The source tag of the check for a newer release.
//
pub const CHECK_FOR_UPDATE_TASK_SOURCE = "check-for-update";

//
// The source tag of the check of the news feed.
//
pub const CHECK_FOR_NEWS_TASK_SOURCE = "check-for-news";

//
// The source tag of the task that makes automatic import match the config.
//
pub const ENSURE_AUTO_IMPORT_TASK_SOURCE = "ensure-auto-import";

//
// How often the signal of a second copy of the app is looked for, in milliseconds.
//
pub const SINGLE_INSTANCE_CHECK_MS = 500;

//
// What the main thread gives the `ensure-auto-import` task: whether it is a tick of the check (worded "restarting" when it fails) or
// the call at startup, and what automatic import is running now, so the task does nothing when that already matches the config.
//
pub const IEnsureAutoImportData = struct {
    // Whether this is a tick of the check rather than the call at startup.
    restarting: bool = false,
    // The database automatic import is writing to, or null when it is not running.
    runningDatabasePath: ?[]const u8 = null,
    // The settings it was started with, as JSON, or null when it is not running.
    runningSettingsJson: ?[]const u8 = null,
};

//
// Holds the app's state, the main thread's own: set by onCreate on the core's main thread, before any message or task can reach the
// app, and null again once onDestroy has destroyed it, after every task has ended. No other thread has it.
//
threadlocal var main_state: ?*MainState = null;

//
// The main thread's allocator for what the state keeps, which lives as long as the main thread and only the main thread uses. Ziggy
// gives a handler an arena that is freed when the handler returns, so what outlives a handler is allocated with this, which each
// function of the state that keeps something is given (see stateAllocator).
//
threadlocal var state_allocator: ThreadAllocator = .init;

//
// The main thread's allocator for what the state keeps (see state_allocator).
//
pub fn stateAllocator() std.mem.Allocator {
    return state_allocator.allocator();
}

//
// What the main process remembers. It keeps no system service: each function is given the handler services, the timers, the Io and
// the allocator it uses, those of the main thread, and the allocator is the state's own (see stateAllocator).
//
pub const MainState = struct {
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
    // The debounced sync's timer, or null when none is set (`syncDebounceTimer`).
    sync_debounce_timer: ?TimerId,
    // The periodic sync's timer, or null before it is started or after it is stopped (`syncPeriodicTimer`).
    sync_periodic_timer: ?TimerId,
    // The timer of the check that automatic import is running, or null before the main window has been created.
    auto_import_check_timer: ?TimerId,
    // How often automatic import is checked. A field so that a test can shorten it.
    auto_import_check_ms: u64,
    // How long the debounce waits. A field so that a test can shorten it.
    sync_debounce_ms: u64,
    // How often the periodic sync runs. A field so that a test can shorten it.
    sync_periodic_ms: u64,
    // Whether automatic import is running (`autoImportRunning`).
    auto_import_running: bool,
    // The id of the running automatic import task, or null (`autoImportTaskId`). Owned by the state.
    auto_import_task_id: ?[]u8,
    // The database automatic import is writing to, or null (`autoImportDatabasePath`). Owned by the state.
    auto_import_database_path: ?[]u8,
    // The settings the running automatic import was started with, as JSON, or null (`autoImportSettingsJson`). Owned by the state.
    auto_import_settings_json: ?[]u8,
    // Set while an ensure-auto-import task is queued or running, so two config writes arriving together do not both create the default
    // database (`autoImportStarting`).
    auto_import_starting: bool,
    // Whether the main window has been created, which happens once.
    main_window_created: bool,
    // Whether the checks made once the page has loaded (for an update and for news) have been queued, which happens once.
    startup_checks_queued: bool,
    // The asset server while it runs, or null before it starts and after the app stops.
    asset_server: ?*node_api.asset_server.AssetServer,
    // The MCP server while it runs, or null before it starts, when it could not start and after the app stops.
    mcp_server: ?*mcp_server.RunningMcpServer,
    // The lock this copy holds so that no other copy runs, or null when the rule does not apply to it (a build with no version, a test or a phone).
    single_instance: ?single_instance.SingleInstance,
    // The timer that looks for the signal of a second copy, or null when this copy holds no lock.
    single_instance_timer: ?TimerId,
    // Which pieces of background work (see background-work.zig) are switched on, by pass.
    background_passes_on: [background_work.PASS_COUNT]bool,
    // The timer of each pass that is switched on and not yet due, by pass.
    background_pass_timers: [background_work.PASS_COUNT]?TimerId,
    // Which passes are queued or running, by pass, so a pass is never run twice at once.
    background_passes_running: [background_work.PASS_COUNT]bool,
    // Whether the next sync pass is the first since the sync was switched on, which only reads the gap (see runSyncPass).
    first_sync_pass: bool,
    // What the last completed background prefetch pass said about the replica, which the background sync pass holds back for.
    prefetch_replica_state: background_work.ReplicaState,
    // The arguments of the background pass timers, one for each pass, which name the pass a timer is for.
    background_pass_targets: [background_work.PASS_COUNT]PassTimer,
    // Makes the ids of the tasks the main process queues.
    uuid_generator: utils.random_uuid_generator.RandomUuidGenerator,
    // What makes the background work's native calls on Windows, whose native app has no native call callback (see
    // windows-native-calls.zig).
    windows_native_calls: windows_native_calls.WindowsNativeCalls,
    // What makes the background work's native calls on MacOS, whose bridge has no native call callback (see macos-native-calls.zig).
    macos_native_calls: macos_native_calls.MacosNativeCalls,
    // Set once the app is stopping, so that nothing the stopping tasks do restarts anything.
    stopping: bool,
    // The environment read from the process, which this thread reads, or null when the thread already had one. Owned.
    environment: ?*std.process.Environ.Map,
    // The tools built into the program (ImageMagick and FFmpeg). Owned.
    media_tools: *media_tools.MediaTools,

    //
    // Makes the state and starts the periodic sync, which runs for the life of the app. It runs in onCreate, on the main thread, before
    // any message or task can reach the app, and logs to the file log Ziggy started meanwhile. The allocator is the state's own (see
    // stateAllocator), because the state lives for as long as the main thread.
    //
    pub fn create(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!*MainState {
        const log = services.log;
        // A core a native app hosts has no `main` to hand it the environment, so it is read from the process (see environment.zig).
        const process_environment = try environment.adoptProcessEnvironment(allocator);
        errdefer freeEnvironment(allocator, process_environment);
        try logStarting(log, allocator);
        // ImageMagick and FFmpeg are built into the program and run in its process, for the tasks (each makes its own runner of them).
        const media = try allocator.create(media_tools.MediaTools);
        errdefer allocator.destroy(media);
        media.* = try media_tools.MediaTools.init();
        errdefer media.deinit();
        try logToolVersions(allocator, io, log, media.runner());
        utils.console.log("Worker pool initialized");
        const state = try allocator.create(MainState);
        errdefer allocator.destroy(state);
        state.* = .{
            .environment = process_environment,
            .media_tools = media,
            .is_database_open = false,
            .current_database_path = null,
            .sync_allowed = false,
            .is_sync_running = false,
            .sync_debounce_timer = null,
            .sync_periodic_timer = null,
            .auto_import_check_timer = null,
            .auto_import_check_ms = AUTO_IMPORT_RESTART_CHECK_MS,
            .sync_debounce_ms = SYNC_DEBOUNCE_MS,
            .sync_periodic_ms = SYNC_PERIODIC_MS,
            .auto_import_running = false,
            .auto_import_task_id = null,
            .auto_import_database_path = null,
            .auto_import_settings_json = null,
            .auto_import_starting = false,
            .main_window_created = false,
            .startup_checks_queued = false,
            .asset_server = null,
            .mcp_server = null,
            .single_instance = null,
            .single_instance_timer = null,
            .background_passes_on = [_]bool{false} ** background_work.PASS_COUNT,
            .background_pass_timers = [_]?TimerId{null} ** background_work.PASS_COUNT,
            .background_passes_running = [_]bool{false} ** background_work.PASS_COUNT,
            .first_sync_pass = false,
            .prefetch_replica_state = .unknown,
            .background_pass_targets = undefined,
            .uuid_generator = .{},
            .windows_native_calls = windows_native_calls.WindowsNativeCalls.init(),
            .macos_native_calls = macos_native_calls.MacosNativeCalls.init(),
            .stopping = false,
        };
        inline for (std.meta.fields(background_work.Pass)) |field| {
            state.background_pass_targets[field.value] = .{
                .state = state,
                .pass = @enumFromInt(field.value),
            };
        }
        // Undoes what the state now owns, in the order destroy uses, when applying the single instance rule fails. The rule can fail after
        // taking the lock (logging that it was acquired), so the lock is released too.
        errdefer {
            state.windows_native_calls.deinit();
            state.macos_native_calls.deinit();
            if (state.single_instance) |*instance| {
                instance.release(io);
            }
        }
        try state.applySingleInstanceRule(services, timers, io, allocator);
        try state.startPeriodicSync(timers, io);
        return state;
    }

    //
    // Does what is needed before the worker pool goes: stops the servers and the periodic sync, cancels the automatic import task if
    // one is running, clears the debounce, and logs that the app is shutting down. Ziggy clears the timers after this.
    //
    pub fn stop(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) void {
        const log = services.log;
        // Set first, so that nothing the stopping tasks do restarts anything.
        self.stopping = true;
        self.stopMcpServer(io, allocator);
        if (self.asset_server) |server| {
            server.stop(io, allocator);
            self.asset_server = null;
        }
        self.stopPeriodicSync(timers);
        // The automatic import task holds filesystem watchers and a temporary directory, so it is told to stop before the worker pool
        // goes away under it.
        if (self.auto_import_running) {
            self.auto_import_running = false;
            freeOwned(allocator, &self.auto_import_database_path);
            services.cancelTasks(io, allocator, node_api.auto_import_desktop.AUTO_IMPORT_TASK_SOURCE);
        }
        clearTimer(timers, &self.sync_debounce_timer);
        log.info("Photosphere Desktop shutting down...");
    }

    //
    // Switches the background work on, as the page's startBackgroundImport request calls for. Each pass that was off is due at once. Switching on
    // a pass that is already on changes nothing, and a pass that finished (the import when automatic import was switched off, the
    // prefetch when its replica was complete) is switched on again, which is how switching the feature back on, or opening a database,
    // brings it back.
    //
    pub fn startBackgroundWork(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(background_work.Pass)) |field| {
            const pass: background_work.Pass = @enumFromInt(field.value);
            // A desktop imports by watching folders (ensureAutoImport), so a second import here would import everything twice.
            if (pass != .import or builtin.os.tag == .ios or builtin.abi.isAndroid()) {
                self.switchOnBackgroundPass(services, timers, io, allocator, pass);
            }
        }
    }

    //
    // Switches the background work off and stops the passes in flight, as the page's stopBackgroundImport request calls for.
    //
    pub fn stopBackgroundWork(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) void {
        self.switchOffBackgroundPasses(services, timers, io, allocator);
        inline for (std.meta.fields(background_work.Pass)) |field| {
            const pass: background_work.Pass = @enumFromInt(field.value);
            services.cancelTasks(io, allocator, pass.source());
        }
    }

    //
    // Switches a piece of background work on. A pass that was off is due at once. One that is already on changes nothing. While any of
    // the work is on the app is held running, so the passes go on with the app off screen.
    //
    pub fn switchOnBackgroundPass(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, pass: background_work.Pass) void {
        const log = services.log;
        const index = @intFromEnum(pass);
        if (self.background_passes_on[index]) {
            return;
        }
        self.background_passes_on[index] = true;
        if (pass == .sync) {
            self.first_sync_pass = true;
        }
        self.scheduleBackgroundPass(timers, io, log, pass, 0);
        services.holdKeepAlive(io, allocator, true);
    }

    //
    // Switches all the background work off, and lets the app go. A pass in flight still ends, and nothing is due after it.
    //
    pub fn switchOffBackgroundPasses(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) void {
        self.background_passes_on = [_]bool{false} ** background_work.PASS_COUNT;
        for (&self.background_pass_timers) |*timer| {
            clearTimer(timers, timer);
        }
        services.holdKeepAlive(io, allocator, false);
    }

    //
    // Sets the timer that queues a pass after the gap.
    //
    fn scheduleBackgroundPass(self: *MainState, timers: Timers, io: std.Io, log: ILog, pass: background_work.Pass, gap_ms: u64) void {
        const index = @intFromEnum(pass);
        clearTimer(timers, &self.background_pass_timers[index]);
        self.background_pass_timers[index] = timers.setTimeout(io, .{
            .context = &self.background_pass_targets[index],
            .function = backgroundPassDue,
        }, gap_ms) catch |err| {
            log.exception("Error setting the timer of a background pass", err);
            return;
        };
    }

    //
    // Queues a pass whose time has come, when it is switched on and not queued or running already. One that cannot be queued is logged
    // and tried again after the fallback gap.
    //
    pub fn queueDueBackgroundPass(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, pass: background_work.Pass) void {
        const log = services.log;
        const index = @intFromEnum(pass);
        self.background_pass_timers[index] = null;
        if (!self.background_passes_on[index] or self.background_passes_running[index]) {
            return;
        }
        self.queueBackgroundPass(services, io, allocator, pass) catch |err| {
            log.exception("Error queuing a background pass", err);
            self.scheduleBackgroundPass(timers, io, log, pass, background_work.FALLBACK_PAUSE_MS);
            return;
        };
        self.background_passes_running[index] = true;
    }

    //
    // Queues one pass as a task of its own, under its own source, with what the pass needs to know.
    //
    fn queueBackgroundPass(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator, pass: background_work.Pass) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const first = pass == .sync and self.first_sync_pass;
        const data_json = try json.stringify(arena, background_work.IPassTaskData{
            .first = first,
            .replicaState = self.prefetch_replica_state,
        });
        const task_id = try self.uuid_generator.uuidGenerator().generate(arena, io);
        try services.addTask(io, arena, task_id, pass.taskType(), pass.source(), data_json, .background);
        if (first) {
            self.first_sync_pass = false;
        }
    }

    //
    // Records how a pass ended, from its task's result: what the prefetch reported about the replica, and that the next pass is due after
    // the gap it gave, unless the work is finished or has been switched off. When the last of the work finishes, the app is let go.
    // A pass that failed is tried again after the fallback gap.
    //
    pub fn backgroundPassEnded(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, pass: background_work.Pass, result: ?background_work.IPassTaskResult) void {
        const log = services.log;
        const index = @intFromEnum(pass);
        self.background_passes_running[index] = false;
        const ended = result orelse background_work.IPassTaskResult{
            .gapMs = background_work.FALLBACK_PAUSE_MS,
            .finished = false,
            .replicaState = self.prefetch_replica_state,
        };
        if (pass == .prefetch) {
            self.prefetch_replica_state = ended.replicaState;
        }
        if (!self.background_passes_on[index]) {
            return;
        }
        if (!ended.finished) {
            self.scheduleBackgroundPass(timers, io, log, pass, ended.gapMs);
            return;
        }
        self.background_passes_on[index] = false;
        for (self.background_passes_on) |on| {
            if (on) {
                return;
            }
        }
        services.holdKeepAlive(io, allocator, false);
    }

    //
    // Releases everything the state owns, after the workers have stopped, with the allocator it was made with. Ziggy stops the file log
    // after this, so the lines logged here are in it.
    //
    pub fn destroy(self: *MainState, io: std.Io, allocator: std.mem.Allocator) void {
        freeOwned(allocator, &self.current_database_path);
        freeOwned(allocator, &self.auto_import_task_id);
        freeOwned(allocator, &self.auto_import_database_path);
        freeOwned(allocator, &self.auto_import_settings_json);
        // A state that was never stopped still has its servers.
        self.stopMcpServer(io, allocator);
        if (self.asset_server) |server| {
            server.stop(io, allocator);
            self.asset_server = null;
        }
        self.windows_native_calls.deinit();
        self.macos_native_calls.deinit();
        if (self.single_instance) |*instance| {
            instance.release(io);
        }
        self.media_tools.deinit();
        allocator.destroy(self.media_tools);
        freeEnvironment(allocator, self.environment);
        allocator.destroy(self);
    }

    //
    // Resets the isSyncRunning flag. Called when a sync task finishes (success, skip, or failure).
    //
    pub fn syncStopped(self: *MainState) void {
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
    pub fn resetSyncState(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, next_database_path: ?[]const u8) void {
        // (`currentDatabasePath &&` is false for an empty path as well as for none.)
        if (self.current_database_path) |current_path| {
            const next_is_different = if (next_database_path) |next| !std.mem.eql(u8, current_path, next) else true;
            if (current_path.len > 0 and next_is_different) {
                services.cancelTasks(io, allocator, current_path);
            }
        }
        self.is_sync_running = false;
        clearTimer(timers, &self.sync_debounce_timer);
    }

    //
    // Schedules a debounced sync after the last edit notification. Resets the debounce timer if called again before it fires.
    //
    pub fn scheduleSync(self: *MainState, timers: Timers, io: std.Io, log: ILog) !void {
        log.info("Sync debounce triggered");
        clearTimer(timers, &self.sync_debounce_timer);
        self.sync_debounce_timer = try timers.setTimeout(io, .{
            .context = self,
            .function = syncDebounceDue,
        }, self.sync_debounce_ms);
    }

    //
    // Starts the periodic sync timer. It runs for the lifetime of the app. A second call changes nothing.
    //
    pub fn startPeriodicSync(self: *MainState, timers: Timers, io: std.Io) !void {
        if (self.sync_periodic_timer != null) {
            return;
        }
        self.sync_periodic_timer = try timers.setInterval(io, .{
            .context = self,
            .function = syncTimerDue,
        }, self.sync_periodic_ms);
    }

    //
    // Stops the periodic sync timer.
    //
    pub fn stopPeriodicSync(self: *MainState, timers: Timers) void {
        if (self.sync_periodic_timer) |id| {
            timers.clearInterval(id);
            self.sync_periodic_timer = null;
        }
    }

    //
    // Queues a sync task if a database is open and no sync is already running. Connectivity checking and the sync-started and
    // sync-completed events are the task's responsibility.
    //
    // When the task cannot be queued the running flag is put back before the error is returned, otherwise the flag would stay
    // set and no sync would ever run again.
    //
    pub fn enqueueSyncTask(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator) !void {
        const log = services.log;
        // Never auto-sync unless the page's decision permits it (sync enabled, online, and the Wi-Fi restriction satisfied).
        // (`!currentDatabasePath` is true for an empty path as well as for none.)
        if (!self.sync_allowed or self.current_database_path == null or self.current_database_path.?.len == 0 or self.is_sync_running) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const database_path = try arena.dupe(u8, self.current_database_path.?);
        self.is_sync_running = true;
        errdefer self.syncStopped();
        log.info(try std.fmt.allocPrint(arena, "Queuing sync task for \"{s}\"", .{database_path}));
        // No cancel source: the page lists this job but must not be able to stop it, because syncing is switched off from Settings and
        // a sync cancelled from a list would start again on the next timer anyway.
        const job_id = try std.mem.concat(arena, u8, &.{ "sync:", database_path });
        const sync_data = try json.stringify(arena, .{
            .databasePath = database_path,
            .job = .{
                .id = job_id,
                .name = "Syncing database",
            },
        });
        const task_id = try self.uuid_generator.uuidGenerator().generate(arena, io);
        try services.addTask(io, arena, task_id, "sync-database", database_path, sync_data, .background);
    }

    //
    // Starts the asset server the first time it is called and returns the port it is listening on. The page needs the address before
    // it can render, so the page's query requests it. The main thread opens the server's socket itself, so it knows the port at once.
    // A later call returns the port without starting another server. The port is the OS's choice, because the server requests
    // port 0.
    //
    pub fn startAssetServer(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator) !u16 {
        const log = services.log;
        if (self.asset_server) |server| {
            return server.port;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const listener = node_utils.http_server.open(io, node_api.asset_server.HOST, 0) catch |err| {
            return utils.errors.throwError("REST API failed to start: {s}", .{utils.errors.errorMessage(err)});
        };
        const session_id = try self.uuid_generator.uuidGenerator().generate(arena, io);
        const server = node_api.asset_server.AssetServer.start(allocator, io, log, listener, .{
            .sessionId = session_id,
            .nativeCallbacks = services.nativeCallbacks(),
        }) catch |err| {
            return utils.errors.throwError("REST API failed to start: {s}", .{utils.errors.errorMessage(err)});
        };
        self.asset_server = server;
        log.info(try std.fmt.allocPrint(arena, "REST API initialized on port {d}", .{server.port}));
        return server.port;
    }

    //
    // Takes the lock that keeps a second copy of the packaged app from running, or, when another copy holds it, logs that this one is quitting
    // and asks the native app to quit. The rule does not apply to a build with no version, a test or a phone, which all log that the lock
    // was acquired.
    //
    pub fn applySingleInstanceRule(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.enforceSingleInstance(services, timers, io, allocator, single_instance.ruleApplies());
    }

    //
    // Does what applySingleInstanceRule does once it has decided whether the rule applies to this copy.
    //
    pub fn enforceSingleInstance(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, rule_applies: bool) !void {
        const log = services.log;
        const pid = storage.storage.processId();
        const packaged: []const u8 = if (single_instance.isUnpackaged()) "false" else "true";
        if (rule_applies) {
            switch (try single_instance.acquire(allocator, io, services.dataDir())) {
                .acquired => |instance| {
                    self.single_instance = instance;
                    self.single_instance_timer = try timers.setInterval(io, .{
                        .context = self,
                        .function = singleInstanceDue,
                    }, SINGLE_INSTANCE_CHECK_MS);
                },
                .denied => {
                    var arena_state = std.heap.ArenaAllocator.init(allocator);
                    defer arena_state.deinit();
                    log.event(try std.fmt.allocPrint(arena_state.allocator(), "Single instance lock denied (pid={d}, packaged={s}); quitting", .{ pid, packaged }));
                    services.quit(io, arena_state.allocator());
                    return;
                },
            }
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        log.event(try std.fmt.allocPrint(arena_state.allocator(), "Single instance lock acquired (pid={d}, packaged={s})", .{ pid, packaged }));
    }

    //
    // Looks for the signal a second copy of the app leaves when it is started and quits, and brings this copy's window to the front when it is
    // there. The native app does the bringing to the front, as the `focus-window` action.
    //
    pub fn checkSecondInstance(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator) !void {
        const log = services.log;
        const instance = if (self.single_instance) |*held| held else {
            return;
        };
        if (!try instance.takeSignal(io)) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        log.event(try std.fmt.allocPrint(arena_state.allocator(), "Second-instance signal received by pid={d}", .{storage.storage.processId()}));
        services.menuAction(io, arena_state.allocator(), "focus-window");
    }

    //
    // Takes one hold on the computer staying awake for a background pass, or lets one go, from the JSON text of a holdAwake request a
    // pass task sent as an event (see background_work.callOnDesktop). The hold belongs to the main thread, which keeps it across
    // passes. Windows and MacOS only: no other platform's tasks send the event.
    //
    pub fn holdAwake(self: *MainState, arena: std.mem.Allocator, request_json: []const u8) !void {
        if (builtin.os.tag == .windows) {
            _ = try self.windows_native_calls.call(arena, "holdAwake", request_json);
            return;
        }
        if (builtin.os.tag == .macos) {
            _ = try self.macos_native_calls.call(arena, "holdAwake", request_json);
            return;
        }
        return utils.errors.throwError("The computer is held awake on Windows and MacOS only, and this is {s}.", .{@tagName(builtin.os.tag)});
    }

    //
    // Queues the task that makes automatic import match the config, unless one is queued or running already. The task's input gives
    // whether it is the call at startup or a tick of the check, which are worded differently when it fails ('Error starting automatic
    // import' and 'Error restarting automatic import'), and what automatic import is running now.
    //
    pub fn enqueueEnsureAutoImportTask(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator, restarting: bool) !void {
        if (self.auto_import_starting) {
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const running = self.auto_import_running;
        const data_json = try json.stringify(arena, IEnsureAutoImportData{
            .restarting = restarting,
            .runningDatabasePath = if (running) self.auto_import_database_path else null,
            .runningSettingsJson = if (running) self.auto_import_settings_json else null,
        });
        const task_id = try self.uuid_generator.uuidGenerator().generate(arena, io);
        try services.addTask(io, arena, task_id, "ensure-auto-import", ENSURE_AUTO_IMPORT_TASK_SOURCE, data_json, .background);
        self.auto_import_starting = true;
    }

    //
    // Does what is needed once the main window has been created: logs that the main window was created, makes
    // automatic import match the config, and starts the check that keeps it running. The page's query starts the asset server
    // and reads the theme, so it calls this when it has built the query. Only the
    // first call does anything, because these steps run once and a window made again later does not repeat them.
    //
    pub fn mainWindowCreated(self: *MainState, services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) !void {
        const log = services.log;
        if (self.main_window_created) {
            return;
        }
        self.main_window_created = true;
        self.auto_import_check_timer = try timers.setInterval(io, .{
            .context = self,
            .function = autoImportCheckDue,
        }, self.auto_import_check_ms);
        log.event("Main window created");
        // Automatic import picks up where it left off, so a machine that was backing photos up before it was shut down carries on
        // without the user having to open anything.
        try self.enqueueEnsureAutoImportTask(services, io, allocator, false);
        // A phone has no MCP server. A server that cannot start is not worth stopping the app for, so the app carries on without it.
        if (builtin.os.tag != .ios and !builtin.abi.isAndroid()) {
            self.startMcpServer(services, io, allocator) catch |err| {
                log.exception("MCP server failed to start, continuing without it", err);
            };
        }
    }

    //
    // Does what is needed once the page has loaded and is listening for events: queues the check for a newer release (on a desktop, as
    // a phone is updated by its store) and the check of the news feed, which announce what they find to the page as events. Only the
    // first call does anything, because the checks run once however many times the page loads.
    //
    pub fn pageLoaded(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator) !void {
        if (self.startup_checks_queued) {
            return;
        }
        self.startup_checks_queued = true;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (builtin.os.tag != .ios and !builtin.abi.isAndroid()) {
            const update_task_id = try self.uuid_generator.uuidGenerator().generate(arena, io);
            try services.addTask(io, arena, update_task_id, "check-for-update", CHECK_FOR_UPDATE_TASK_SOURCE, "null", .background);
        }
        const news_task_id = try self.uuid_generator.uuidGenerator().generate(arena, io);
        try services.addTask(io, arena, news_task_id, "check-for-news", CHECK_FOR_NEWS_TASK_SOURCE, "null", .background);
    }

    //
    // Starts the MCP server, unless it is already running. It is a server of its own, not a task, so it holds no worker.
    //
    pub fn startMcpServer(self: *MainState, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator) !void {
        const log = services.log;
        if (self.mcp_server != null) {
            return;
        }
        self.mcp_server = try mcp_server.startMcpServer(allocator, io, log, services.nativeCallbacks());
    }

    //
    // Stops the MCP server if it is running.
    //
    pub fn stopMcpServer(self: *MainState, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.mcp_server) |server| {
            self.mcp_server = null;
            server.stop(io, allocator);
        }
    }
};

//
// Clears a timer that is set, and forgets it.
//
fn clearTimer(timers: Timers, timer: *?TimerId) void {
    if (timer.*) |id| {
        timers.clearTimeout(id);
        timer.* = null;
    }
}

//
// Replaces a string the state owns with a copy of a new one, or with null, freeing the old one, with the state's allocator.
//
pub fn setOwned(allocator: std.mem.Allocator, field: *?[]u8, value: ?[]const u8) !void {
    const copy: ?[]u8 = if (value) |text| try allocator.dupe(u8, text) else null;
    if (field.*) |old| {
        allocator.free(old);
    }
    field.* = copy;
}

//
// Frees a string the state owns, with the state's allocator, and sets it to null.
//
pub fn freeOwned(allocator: std.mem.Allocator, field: *?[]u8) void {
    if (field.*) |old| {
        allocator.free(old);
    }
    field.* = null;
}

//
// Frees the environment the state read from the process, when it read one, and takes it from the thread.
//
fn freeEnvironment(allocator: std.mem.Allocator, map: ?*std.process.Environ.Map) void {
    const given = map orelse {
        return;
    };
    node_utils.process_env.setEnvironMap(null);
    given.deinit();
    allocator.destroy(given);
}

//
// Which pass a background pass timer is for.
//
pub const PassTimer = struct {
    // The state.
    state: *MainState,
    // The pass.
    pass: background_work.Pass,
};

//
// The timer of a background pass. A timer on the main thread is given its handler services.
//
fn backgroundPassDue(context: ?*anyopaque, io: std.Io, _: std.mem.Allocator, timers: Timers, services: ?*const anyopaque) void {
    const target: *PassTimer = @ptrCast(@alignCast(context.?));
    target.state.queueDueBackgroundPass(ziggy.core.handlerServicesOf(services), timers, io, stateAllocator(), target.pass);
}

//
// The debounce timer: queues the sync the last edit called for.
//
fn syncDebounceDue(context: ?*anyopaque, io: std.Io, _: std.mem.Allocator, _: Timers, services: ?*const anyopaque) void {
    const state: *MainState = @ptrCast(@alignCast(context.?));
    const log = ziggy.core.handlerServicesOf(services).log;
    state.sync_debounce_timer = null;
    state.enqueueSyncTask(ziggy.core.handlerServicesOf(services), io, stateAllocator()) catch |err| {
        log.exception("Error queuing a sync task", err);
    };
}

//
// The periodic sync timer.
//
fn syncTimerDue(context: ?*anyopaque, io: std.Io, _: std.mem.Allocator, _: Timers, services: ?*const anyopaque) void {
    const state: *MainState = @ptrCast(@alignCast(context.?));
    const log = ziggy.core.handlerServicesOf(services).log;
    state.enqueueSyncTask(ziggy.core.handlerServicesOf(services), io, stateAllocator()) catch |err| {
        log.exception("Error queuing a sync task", err);
    };
}

//
// The timer of the check that automatic import is running.
//
fn autoImportCheckDue(context: ?*anyopaque, io: std.Io, _: std.mem.Allocator, _: Timers, services: ?*const anyopaque) void {
    const state: *MainState = @ptrCast(@alignCast(context.?));
    const log = ziggy.core.handlerServicesOf(services).log;
    state.enqueueEnsureAutoImportTask(ziggy.core.handlerServicesOf(services), io, stateAllocator(), true) catch |err| {
        log.exception("Error queuing the check that automatic import is running", err);
    };
}

//
// The timer that looks for a second copy of the app.
//
fn singleInstanceDue(context: ?*anyopaque, io: std.Io, _: std.mem.Allocator, _: Timers, services: ?*const anyopaque) void {
    const state: *MainState = @ptrCast(@alignCast(context.?));
    const log = ziggy.core.handlerServicesOf(services).log;
    state.checkSecondInstance(ziggy.core.handlerServicesOf(services), io, stateAllocator()) catch |err| {
        log.exception("Error looking for a second instance of the app", err);
    };
}
//
// The main process's state, for a handler on the main thread. Panics when there is none, because onCreate makes it before any
// handler can run and onDestroy frees it only once none can.
//
pub fn current() *MainState {
    return main_state orelse {
        std.debug.panic("The main process's state does not exist: it is made by onCreate when the core is created and freed by onDestroy when the core is destroyed", .{});
    };
}

//
// Registers, on a task's thread before the task runs, the builders of the media sources automatic import reads: a folder's everywhere,
// and on a phone, whose native app is the one that reaches the platform (the task's context can reach it), the photo library's too.
//
pub fn registerMediaSources(context: ziggy.task_queue.types.ITaskContext) anyerror!void {
    try node_api.task_handlers.registerMediaSourceBuilders();
    if (context.nativeCaller != null) {
        try mobile_worker.device_media_source.registerDeviceMediaSourceBuilder();
    }
}

//
// Makes the main process's state when Ziggy creates the core, on the core's main thread, before any message or task can reach the app.
// Ziggy has started the file log by then, and the log is configured first, from the options on the app's command line. The state is
// made with the state's allocator, not the arena Ziggy gives.
//
pub fn onCreate(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void {
    _ = allocator;
    try services.configureLog(logOptions(arguments));
    const state = try MainState.create(services, timers, io, stateAllocator());
    main_state = state;
}

//
// The log options on the app's command line: --verbose, --debug and --tools each turn on their lines, as the CLI's do. Every other
// argument is left to whatever else reads the command line.
//
pub fn logOptions(arguments: []const []const u8) ziggy.log.ILogOptions {
    var options: ziggy.log.ILogOptions = .{
        .verbose = false,
        .debug = false,
        .tools = false,
    };
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--verbose")) {
            options.verbose = true;
        }
        else if (std.mem.eql(u8, argument, "--debug")) {
            options.debug = true;
        }
        else if (std.mem.eql(u8, argument, "--tools")) {
            options.tools = true;
        }
    }
    return options;
}

//
// Stops the main process's state before the workers stop, while tasks can still be queued, and destroys it once the workers have
// stopped and no task can run. Ziggy destroys only a core it created, so onCreate has made the state. Both run on the main thread. The
// state's allocator goes with the state, ready for a core made again on this thread.
//
pub fn onDestroy(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, phase: ziggy.core.DestroyPhase) void {
    _ = allocator;
    const state = current();
    switch (phase) {
        .before_tasks_stop => state.stop(services, timers, io, stateAllocator()),
        .after_tasks_stopped => {
            main_state = null;
            state.destroy(io, stateAllocator());
            state_allocator.deinit();
            state_allocator = .init;
        },
    }
}

//
// Logs, as the first lines of the run, that the app is starting and which instance this is. A build that has been given a version is
// the packaged one.
//
fn logStarting(log: ILog, allocator: std.mem.Allocator) !void {
    log.info("Photosphere Desktop starting...");
    const packaged = !std.mem.eql(u8, config.version, "dev");
    const started = try std.fmt.allocPrint(allocator, "Instance started (pid={d}, packaged={s})", .{ storage.storage.processId(), if (packaged) "true" else "false" });
    defer allocator.free(started);
    log.event(started);
}

//
// Logs the versions of the tools built into the program (ImageMagick, FFmpeg and FFprobe), each on a line of its own.
//
fn logToolVersions(allocator: std.mem.Allocator, io: std.Io, log: ILog, tool_runner: node_utils.in_process_tools.InProcessRunner) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    for (try toolVersionLines(arena_state.allocator(), io, log, tool_runner)) |line| {
        log.info(line);
    }
}

//
// The lines the log gives for the tools the app runs: ImageMagick, FFmpeg and FFprobe, each with its version, or "not
// found". ImageMagick's check failing is written into its line rather than stopping the app. Allocated with the arena.
//
fn toolVersionLines(arena: std.mem.Allocator, io: std.Io, log: ILog, tool_runner: node_utils.in_process_tools.InProcessRunner) ![]const []const u8 {
    const image_magick_line = blk: {
        const status = tools.Image.verifyImageMagick(arena, io, log, tool_runner) catch {
            break :blk "ImageMagick: error checking version";
        };
        if (!status.available) {
            break :blk "ImageMagick: not found";
        }
        break :blk try std.fmt.allocPrint(arena, "ImageMagick: {s}", .{status.version orelse "unknown"});
    };
    const ffmpeg_status = try tools.Video.verifyFfmpeg(arena, io, log, tool_runner);
    const ffmpeg_line = if (ffmpeg_status.available)
        try std.fmt.allocPrint(arena, "FFmpeg: {s}", .{ffmpeg_status.version orelse "unknown"})
    else
        "FFmpeg: not found";
    const ffprobe_status = try tools.Video.verifyFfprobe(arena, io, log, tool_runner);
    const ffprobe_line = if (ffprobe_status.available)
        try std.fmt.allocPrint(arena, "FFprobe: {s}", .{ffprobe_status.version orelse "unknown"})
    else
        "FFprobe: not found";
    return try arena.dupe([]const u8, &.{
        "--- Tool Versions ---",
        image_magick_line,
        ffmpeg_line,
        ffprobe_line,
    });
}

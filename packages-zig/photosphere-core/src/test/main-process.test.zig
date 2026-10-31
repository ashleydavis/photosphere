const std = @import("std");
const ziggy = @import("ziggy");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const main_process = @import("photosphere-core").main_process;

const TestApp = support.TestApp;

//
// Makes a database directory that holds a .db/config.json with the text, and returns its path. The caller frees it.
//
fn makeDatabase(app: *TestApp, name: []const u8, config_json: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const database_path = try std.fs.path.join(allocator, &.{ app.tmp_path, name });
    const config_path = try std.fs.path.join(allocator, &.{ database_path, ".db", "config.json" });
    defer allocator.free(config_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(config_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = config_path,
        .data = config_json,
    });
    return database_path;
}

//
// A task that sends an event and then runs until it is cancelled.
//
fn spinTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    _ = data;
    try services.sendEvent(io, allocator, .{ .spinning = true });
    while (true) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

fn waitFor(app: *TestApp, text: []const u8) !void {
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, text);
}

//
// Creates the main window, which asks for the page's query, and waits until the check that automatic import is running, which the main
// process makes as soon as the window is created, has ended, so that a test that sets what the state remembers about automatic
// import by hand is not undone by it.
//
fn waitForStartupCheck(app: *TestApp) !void {
    std.testing.allocator.free(try app.native_app.uiQuery(std.testing.allocator));
    // The check reports what it found automatic import should do, which the main thread then does.
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":{\"action\":\"");
}

const endTask = support.endTask;
const sendTaskEvent = support.sendTaskEvent;

test "notify-database-opened adds an entry for a database that has none, with the origin from its config.json" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "opened-new", "{\"origin\":\"/the/origin\"}");
    defer allocator.free(database_path);
    const path_json = try utils.json.stringify(allocator, database_path);
    defer allocator.free(path_json);
    const reply = try app.requestOk("notify-database-opened", path_json);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = (try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "opened-new")).?;
    try std.testing.expectEqualStrings(database_path, entry.path);
    try std.testing.expectEqualStrings("/the/origin", entry.origin.?);
    const last = (try node_api.databases_config.getLastDatabase(arena.allocator(), std.testing.io)).?;
    try std.testing.expectEqualStrings(database_path, last);
    const recents = try node_api.databases_config.getRecentDatabases(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), recents.len);
    try app.onState(@as([]const u8, database_path), struct {
        fn check(path: []const u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(state.is_database_open);
            try std.testing.expectEqualStrings(path, state.current_database_path.?);
        }
    }.check);
}

test "notify-database-opened refreshes the origin of a database that is already listed" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "opened-existing", "{\"origin\":\"/new/origin\"}");
    defer allocator.free(database_path);
    const path_json = try utils.json.stringify(allocator, database_path);
    defer allocator.free(path_json);
    const entry_json = try utils.json.stringify(allocator, .{
        .name = "listed",
        .description = "mine",
        .path = database_path,
        .origin = "/old/origin",
    });
    defer allocator.free(entry_json);
    allocator.free(try app.requestOk("add-database", entry_json));
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = (try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "listed")).?;
    try std.testing.expectEqualStrings("/new/origin", entry.origin.?);
    try std.testing.expectEqualStrings("mine", entry.description);
    const recents = try node_api.databases_config.getRecentDatabases(arena.allocator(), std.testing.io);
    try std.testing.expectEqualStrings("listed", recents[0].name);
}

test "notify-database-opened without a path is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("notify-database-opened", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "notify-database-closed forgets the database to reopen and the open database" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "closed-one", "{}");
    defer allocator.free(database_path);
    const path_json = try utils.json.stringify(allocator, database_path);
    defer allocator.free(path_json);
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    const reply = try app.requestOk("notify-database-closed", "null");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expect((try node_api.databases_config.getLastDatabase(arena.allocator(), std.testing.io)) == null);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(!state.is_database_open);
            try std.testing.expect(state.current_database_path == null);
        }
    }.check);
}

//
// Whether the state records a sync as running.
//
fn isSyncRunning(app: *TestApp) !bool {
    return try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!bool {
            return state.is_sync_running;
        }
    }.check);
}

//
// Sets how long the debounce of a sync waits, on the main thread.
//
fn setSyncDebounceMs(app: *TestApp, milliseconds: u64) !void {
    try app.onState(milliseconds, struct {
        fn check(given: u64, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.sync_debounce_ms = given;
        }
    }.check);
}

//
// Waits until the state says no sync is running, which the main process says when it hears that the sync task ended, a moment after the
// page is told.
//
fn waitForSyncToStop(app: *TestApp) !void {
    var waited_ms: i64 = 0;
    while (true) {
        if (!try isSyncRunning(app)) {
            return;
        }
        if (waited_ms >= 5000) {
            return error.SyncNeverStopped;
        }
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
        waited_ms += 10;
    }
}

test "main-command set-sync-allowed records the decision, and an edit then queues a sync after the debounce" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try setSyncDebounceMs(&app, 30);
    const database_path = try makeDatabase(&app, "sync-me", "{}");
    defer allocator.free(database_path);
    const path_json = try utils.json.stringify(allocator, database_path);
    defer allocator.free(path_json);
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    // Syncing is not allowed yet, so an edit queues nothing.
    allocator.free(try app.requestOk("notify-database-edited", "null"));
    ziggy.fake_native_app.sleepMs(std.testing.io, 200);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "sync-database"));
    allocator.free(try app.requestOk("main-command", "{\"command\":\"set-sync-allowed\",\"allowed\":true}"));
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Sync gate set to true") != null);
    // The sync-database task runs against a database with no origin and ends, which is how the end of a sync is seen: the page is
    // told the task completed and the running flag is reset.
    try waitFor(&app, "\"type\":\"sync-database\"");
    try waitForSyncToStop(&app);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(state.sync_allowed);
        }
    }.check);
}

test "main-command set-sync-allowed with allowed false schedules nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try setSyncDebounceMs(&app, 30);
    allocator.free(try app.requestOk("main-command", "{\"command\":\"set-sync-allowed\",\"allowed\":false}"));
    ziggy.fake_native_app.sleepMs(std.testing.io, 200);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(!state.sync_allowed);
            try std.testing.expect(state.sync_debounce_timer == null);
        }
    }.check);
}

test "main-command toggle-devtools asks the shell to toggle the developer tools" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("main-command", "\"toggle-devtools\""));
    const actions = try app.native_app.chosenActions(std.testing.io, allocator);
    defer allocator.free(actions);
    try std.testing.expectEqualStrings("toggle-devtools\n", actions);
}

test "main-command with an unknown command writes it to the console and replies nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("main-command", "\"fly-to-the-moon\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Unknown main-command: fly-to-the-moon") != null);
}

//
// The source the children of awaitChildrenTask are queued under, and the source it is itself queued under, as an import's are.
//
const AWAIT_CHILDREN_SOURCE = "await-children-session";

//
// A task that does what import-assets does with its children: queues them under its own source through a task queue and waits for
// them all. More are queued than the test app has workers, so at least one is still waiting for a worker when the source is cancelled.
//
fn awaitChildrenTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const log = services.log;
    _ = context;
    _ = data;
    var uuid_generator: ziggy.utils.random_uuid_generator.RandomUuidGenerator = .{};
    const queue = try ziggy.task_queue.task_queue.TaskQueue.init(allocator, uuid_generator.uuidGenerator(), AWAIT_CHILDREN_SOURCE);
    defer queue.deinit(io, allocator, log);
    var child_index: usize = 0;
    while (child_index < 4) : (child_index += 1) {
        _ = try queue.addTask(io, allocator, log, "spin", .null, null, null);
    }
    try services.sendEvent(io, allocator, .{
        .childrenQueued = true,
    });
    try queue.awaitAllTasks(io, allocator, timers, log);
    return try allocator.dupe(u8, "null");
}

test "main-command cancel-tasks lets a task waiting on its children end when some of them never started" {
    // The cancel the Import page sends. Ziggy's own cancel-tasks message cancels in the runner alone, which drops a child that was
    // still waiting for a worker without saying so, and the task queue counting it waits for it for good. That is what the Release
    // Zig workflow's desktop smoke tests on ubuntu-latest saw in 33-import-cancel: on a runner with four workers the cancelled import
    // never ended and held a worker, and the import after it timed out waiting for "1 assets imported".
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{
        .{
            .name = "spin",
            .handler = spinTask,
        },
        .{
            .name = "await-children",
            .handler = awaitChildrenTask,
        },
    });
    defer app.stop();
    // Lets the waiting task go when the cancel below did not, so a failure is reported rather than hanging the stop.
    errdefer app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            services.cancelTasks(main_io, main_state.stateAllocator(), AWAIT_CHILDREN_SOURCE);
        }
    }.check) catch {};
    const allocator = std.testing.allocator;
    const message = try utils.json.stringify(allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = "await-children-parent",
            .taskType = "await-children",
            .source = AWAIT_CHILDREN_SOURCE,
            .data = null,
            .priority = "background",
        },
    });
    defer allocator.free(message);
    app.native_app.sendMessage(std.testing.allocator, message);
    try waitFor(&app, "childrenQueued");
    const cancel_json = try utils.json.stringify(allocator, .{
        .command = "cancel-tasks",
        .source = AWAIT_CHILDREN_SOURCE,
    });
    defer allocator.free(cancel_json);
    allocator.free(try app.requestOk("main-command", cancel_json));
    try waitFor(&app, "{\"taskId\":\"await-children-parent\",\"result\"");
}

test "main-command cancel-tasks without a source is an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("main-command", "{\"command\":\"cancel-tasks\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "cancel-tasks needs the source") != null);
}

test "main-command without a command is an unknown command called undefined" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("main-command", "{\"allowed\":true}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Unknown main-command: undefined") != null);
}

test "resetSyncState cancels the tasks of the database that was open when another one is opened" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{.{ .name = "spin", .handler = spinTask }});
    defer app.stop();
    const allocator = std.testing.allocator;
    const first_path = try makeDatabase(&app, "reset-first", "{}");
    defer allocator.free(first_path);
    const second_path = try makeDatabase(&app, "reset-second", "{}");
    defer allocator.free(second_path);
    const first_json = try utils.json.stringify(allocator, first_path);
    defer allocator.free(first_json);
    const second_json = try utils.json.stringify(allocator, second_path);
    defer allocator.free(second_json);
    allocator.free(try app.requestOk("notify-database-opened", first_json));
    const message = try utils.json.stringify(allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = "long-1",
            .taskType = "spin",
            .source = first_path,
            .data = null,
            .priority = "background",
        },
    });
    defer allocator.free(message);
    app.native_app.sendMessage(std.testing.allocator, message);
    try waitFor(&app, "\"kind\":\"system\",\"name\":\"task-event\"");
    allocator.free(try app.requestOk("notify-database-opened", second_json));
    try waitFor(&app, "\"errorMessage\":\"Cancelled\"");
}

test "a failed import tells the user, and an automatic import that stops clears what is remembered about it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try endTask(&app, .{
        .task_id = "import-1",
        .task_type = "import-assets",
        .source = "manual",
        .input_json = "{}",
        .status = .failed,
        .error_message = "disk on fire",
        .result_json = null,
        .started = true,
    });
    try waitFor(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"Import failed: disk on fire\",\"color\":\"danger\",\"duration\":8000}}}");
    try waitForStartupCheck(&app);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.auto_import_running = true;
            try main_state.setOwned(main_state.stateAllocator(), &state.auto_import_task_id, "auto-1");
            try main_state.setOwned(main_state.stateAllocator(), &state.auto_import_database_path, "/auto/db");
        }
    }.check);
    try endTask(&app, .{
        .task_id = "auto-1",
        .task_type = "import-assets",
        .source = "auto-import",
        .input_json = "{}",
        .status = .failed,
        .error_message = "crashed",
        .result_json = null,
        .started = true,
    });
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(!state.auto_import_running);
            try std.testing.expect(state.auto_import_task_id == null);
            try std.testing.expect(state.auto_import_database_path == null);
        }
    }.check);
    try std.testing.expectEqual(@as(usize, 1), app.native_app.countContaining(std.testing.io, std.testing.allocator, "Import failed"));
}

test "a replication that worked registers its destination and tells the user, and one that failed only tells the user" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try endTask(&app, .{
        .task_id = "rep-1",
        .task_type = "replicate-database",
        .source = "src",
        .input_json = "{\"destPath\":\"/replicas/copy\",\"sourcePath\":\"/photos\",\"destEncryptionKey\":\"key-1\"}",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    try waitFor(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"databases-changed\",\"data\":null}}");
    try waitFor(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"Replication completed for \\\"copy\\\"\",\"color\":\"success\"}}}");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = (try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "copy")).?;
    try std.testing.expectEqualStrings("/replicas/copy", entry.path);
    try std.testing.expectEqualStrings("/photos", entry.origin.?);
    try std.testing.expectEqualStrings("key-1", entry.encryptionKey.?);
    try endTask(&app, .{
        .task_id = "rep-2",
        .task_type = "replicate-database",
        .source = "src",
        .input_json = "{\"destPath\":\"/replicas/other\"}",
        .status = .failed,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    try waitFor(&app, "\"message\":\"Replication failed: Unknown error\"");
    try std.testing.expect((try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "other")) == null);
}

test "a sync that fails tells the page it completed, and one that succeeds does not" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.is_sync_running = true;
        }
    }.check);
    try endTask(&app, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .input_json = "{\"databasePath\":\"/db\"}",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    try std.testing.expect(!try isSyncRunning(&app));
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "sync-completed"));
    try endTask(&app, .{
        .task_id = "sync-2",
        .task_type = "sync-database",
        .source = "/db",
        .input_json = "{\"databasePath\":\"/db\"}",
        .status = .failed,
        .error_message = "offline",
        .result_json = null,
        .started = true,
    });
    try waitFor(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"sync-completed\",\"data\":null}}");
}

test "a sync task's started and completed messages are passed to the page as events" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendTaskEvent(&app, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .event_json ="{\"type\":\"sync-started\"}",
    });
    try waitFor(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"sync-started\",\"data\":null}}");
    try sendTaskEvent(&app, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .event_json ="{\"type\":\"sync-completed\"}",
    });
    try waitFor(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"sync-completed\",\"data\":null}}");
    try sendTaskEvent(&app, .{
        .task_id = "other",
        .task_type = "other",
        .source = "x",
        .event_json ="{\"type\":\"progress\"}",
    });
    try std.testing.expectEqual(@as(usize, 1), app.native_app.countContaining(std.testing.io, std.testing.allocator, "sync-started"));
}

test "a background pass's hold-awake event reaches the main thread's hold on the computer staying awake, and one without its request is an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendTaskEvent(&app, .{
        .task_id = "pass-1",
        .task_type = "background-pass",
        .source = "background",
        .event_json = "{\"type\":\"hold-awake\",\"request\":{\"awake\":true}}",
    });
    // Windows and MacOS take the hold; this test runs on Linux, where the main state refuses it, which shows the request reached it.
    if (@import("builtin").os.tag == .linux) {
        try std.testing.expect(std.mem.indexOf(u8, try app.consoleErr(), "The computer is held awake on Windows and MacOS only, and this is linux.") != null);
    }
    try sendTaskEvent(&app, .{
        .task_id = "pass-1",
        .task_type = "background-pass",
        .source = "background",
        .event_json = "{\"type\":\"hold-awake\"}",
    });
    try std.testing.expect(std.mem.indexOf(u8, try app.consoleErr(), "A request to hold the computer awake has no request.") != null);
}

test "the periodic sync queues a sync for the open database when syncing is allowed" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "periodic", "{}");
    defer allocator.free(database_path);
    const path_json = try utils.json.stringify(allocator, database_path);
    defer allocator.free(path_json);
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            state.sync_allowed = true;
            // The periodic sync is started again, every 40 milliseconds.
            state.stopPeriodicSync(timers);
            state.sync_periodic_ms = 40;
            try state.startPeriodicSync(timers, main_io);
        }
    }.check);
    try waitFor(&app, "\"type\":\"sync-database\"");
}

//
// A fake of the create-default-database task, which another part of the app provides: it ends at once.
//
fn createDefaultDatabaseTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    _ = data;
    try services.sendEvent(io, allocator, .{ .createdDefaultDatabase = true });
    return try allocator.dupe(u8, "null");
}

//
// A fake of the create-default-database task that fails, as it does when the database cannot be made.
//
fn createDefaultDatabaseFailsTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = data;
    return utils.errors.throwError("the default database could not be made", .{});
}

//
// A fake of the import-assets task, which another part of the app provides: it reports that it started and then runs until it is
// cancelled.
//
fn importAssetsTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    _ = data;
    try services.sendEvent(io, allocator, .{ .importing = true });
    while (true) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

//
// A fake of the import-assets task that ends as soon as it starts, as one does when it cannot open its database.
//
fn importAssetsEndsAtOnceTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = data;
    return utils.errors.throwError("the database could not be opened", .{});
}

const auto_import_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "create-default-database", .handler = createDefaultDatabaseTask },
    .{ .name = "import-assets", .handler = importAssetsTask },
};

//
// The config.yaml of a user who has switched automatic import on, with a default database at the path.
//
fn autoImportConfigYaml(allocator: std.mem.Allocator, database_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "auto_import:\n  enabled: true\n  default_database_path: \"{s}\"\n  sources:\n    - type: folder\n      path: /watched\n      recurse: true\n", .{database_path});
}

//
// Waits until the count of the messages that hold the text reaches the count wanted, for up to a few seconds.
//
fn waitForCount(app: *TestApp, text: []const u8, wanted: usize) !void {
    var waited_ms: i64 = 0;
    while (app.native_app.countContaining(std.testing.io, std.testing.allocator, text) < wanted) {
        if (waited_ms >= 5000) {
            return error.MessageNeverArrived;
        }
        ziggy.fake_native_app.sleepMs(std.testing.io, 10);
        waited_ms += 10;
    }
}

test "automatic import that was switched on before the app started is started by the app itself" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try allocator.dupe(u8, "/nowhere/startup-default-db");
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    try app.startWithTasksAndConfigFile(&auto_import_tasks, config_yaml);
    defer app.stop();
    std.testing.allocator.free(try app.native_app.uiQuery(std.testing.allocator));
    try waitFor(&app, "\"importing\":true");
    try app.onState(@as([]const u8, database_path), struct {
        fn check(path: []const u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(state.auto_import_running);
            try std.testing.expectEqualStrings(path, state.auto_import_database_path.?);
        }
    }.check);
}

//
// Sets how often automatic import is checked, before the main window is created, which starts the check.
//
fn setAutoImportCheckMs(app: *TestApp, milliseconds: u64) !void {
    try app.onState(milliseconds, struct {
        fn check(given: u64, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.auto_import_check_ms = given;
        }
    }.check);
}

test "automatic import is started again by the periodic check after its task died" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try allocator.dupe(u8, "/nowhere/restart-default-db");
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    try app.startWithTasksAndConfigFile(&auto_import_tasks, config_yaml);
    defer app.stop();
    try setAutoImportCheckMs(&app, 40);
    std.testing.allocator.free(try app.native_app.uiQuery(std.testing.allocator));
    try waitForCount(&app, "\"importing\":true", 1);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            services.cancelTasks(main_io, main_state.stateAllocator(), "auto-import");
        }
    }.check);
    try waitForCount(&app, "\"importing\":true", 2);
}

test "a failure to start automatic import at startup is logged, not lost" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try allocator.dupe(u8, "/nowhere/failing-default-db");
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    // Making the default database fails. The real create-default-database task would make it on disk wherever the path lets it.
    try app.startWithTasksAndConfigFile(&[_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "create-default-database", .handler = createDefaultDatabaseFailsTask },
    }, config_yaml);
    defer app.stop();
    std.testing.allocator.free(try app.native_app.uiQuery(std.testing.allocator));
    var waited_ms: i64 = 0;
    while (std.mem.indexOf(u8, (try app.consoleOut()), "Error starting automatic import") == null and
        std.mem.indexOf(u8, (try app.consoleErr()), "Error starting automatic import") == null)
    {
        if (waited_ms >= 5000) {
            return error.MessageNeverArrived;
        }
        ziggy.fake_native_app.sleepMs(std.testing.io, 10);
        waited_ms += 10;
    }
}

test "an automatic import that ends the moment it starts is not remembered as running" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try allocator.dupe(u8, "/nowhere/short-lived-db");
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    try app.startWithTasksAndConfigFile(&[_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "create-default-database", .handler = createDefaultDatabaseTask },
        .{ .name = "import-assets", .handler = importAssetsEndsAtOnceTask },
    }, config_yaml);
    defer app.stop();
    // The check runs every few milliseconds, so every start that loses the race to its own end would leave the state saying that the
    // import is running while no task is, and the next check would then see nothing to do. Count the starts: every end must be followed
    // by another start, because the state must say it is not running.
    try setAutoImportCheckMs(&app, 20);
    std.testing.allocator.free(try app.native_app.uiQuery(std.testing.allocator));
    try waitForCount(&app, "the database could not be opened", 8);
}

test "a sync that succeeded with an input that is not JSON is reported, not ignored" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try endTask(&app, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .input_json = "this is not json",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    const logged = (try app.consoleOut());
    const logged_errors = (try app.consoleErr());
    try std.testing.expect(std.mem.indexOf(u8, logged, "Error handling the end of a task") != null or
        std.mem.indexOf(u8, logged_errors, "Error handling the end of a task") != null);
}

test "an import that failed with an empty error message says the error is unknown" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try endTask(&app, .{
        .task_id = "import-2",
        .task_type = "import-assets",
        .source = "manual",
        .input_json = "{}",
        .status = .failed,
        .error_message = "",
        .result_json = null,
        .started = true,
    });
    try waitFor(&app, "\"message\":\"Import failed: Unknown error\"");
}

//
// A fake of the evict-originals task, which another part of the app provides: it reports what it was asked to do.
//
fn evictOriginalsTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    try services.sendEvent(io, allocator, .{ .evicting = data });
    return try allocator.dupe(u8, "null");
}

test "a sync that succeeded queues the eviction of originals only for the database automatic import fills" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{.{ .name = "evict-originals", .handler = evictOriginalsTask }});
    defer app.stop();
    try waitForStartupCheck(&app);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.auto_import_running = true;
            try main_state.setOwned(main_state.stateAllocator(), &state.auto_import_database_path, "/the/default/db");
        }
    }.check);
    try endTask(&app, .{
        .task_id = "sync-other",
        .task_type = "sync-database",
        .source = "/another/db",
        .input_json = "{\"databasePath\":\"/another/db\"}",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    ziggy.fake_native_app.sleepMs(std.testing.io, 100);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"evicting\""));
    try endTask(&app, .{
        .task_id = "sync-default",
        .task_type = "sync-database",
        .source = "/the/default/db",
        .input_json = "{\"databasePath\":\"/the/default/db\"}",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    try waitFor(&app, "\"evicting\":{\"databasePath\":\"/the/default/db\",\"sessionId\":");
}

test "a replication of a database that is already listed does not list it again or tell the page the databases changed" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const end: ziggy.types.TaskEnd = .{
        .task_id = "rep-1",
        .task_type = "replicate-database",
        .source = "src",
        .input_json = "{\"destPath\":\"/replicas/twice\",\"sourcePath\":\"/photos\"}",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    };
    try endTask(&app, end);
    try waitFor(&app, "Replication completed for");
    try endTask(&app, end);
    try waitForCount(&app, "Replication completed for", 2);
    try std.testing.expectEqual(@as(usize, 1), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"type\":\"databases-changed\""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const databases = try node_api.databases_config.getDatabases(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), databases.len);
}

//
// Whether the console, standard output or standard error, holds the text.
//
fn consoleHas(app: *TestApp, text: []const u8) !bool {
    return std.mem.indexOf(u8, (try app.consoleOut()), text) != null or
        std.mem.indexOf(u8, (try app.consoleErr()), text) != null;
}

test "automatic import is not checked until the main window is created, and creating the window again changes nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    ziggy.fake_native_app.sleepMs(std.testing.io, 200);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"type\":\"ensure-auto-import\""));
    try std.testing.expect(!try consoleHas(&app, "Main window created"));
    try waitForStartupCheck(&app);
    try std.testing.expect(try consoleHas(&app, "Main window created"));
    std.testing.allocator.free(try app.native_app.uiQuery(std.testing.allocator));
    ziggy.fake_native_app.sleepMs(std.testing.io, 200);
    try std.testing.expectEqual(@as(usize, 1), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"type\":\"ensure-auto-import\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, (try app.consoleOut()), "Main window created"));
}

test "a failed check of automatic import says whether it was the start or a later check" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try endTask(&app, .{
        .task_id = "ensure-1",
        .task_type = "ensure-auto-import",
        .source = "ensure-auto-import",
        .input_json = "{\"restarting\":false}",
        .status = .failed,
        .error_message = "no folders",
        .result_json = null,
        .started = true,
    });
    try std.testing.expect(try consoleHas(&app, "Error starting automatic import: no folders"));
    try endTask(&app, .{
        .task_id = "ensure-2",
        .task_type = "ensure-auto-import",
        .source = "ensure-auto-import",
        .input_json = "{\"restarting\":true}",
        .status = .failed,
        .error_message = "no folders",
        .result_json = null,
        .started = true,
    });
    try std.testing.expect(try consoleHas(&app, "Error restarting automatic import: no folders"));
}

test "an automatic import that stops with no error message says the error is unknown" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.auto_import_running = true;
            try main_state.setOwned(main_state.stateAllocator(), &state.auto_import_task_id, "auto-2");
        }
    }.check);
    try endTask(&app, .{
        .task_id = "auto-2",
        .task_type = "import-assets",
        .source = "auto-import",
        .input_json = "{}",
        .status = .failed,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    try std.testing.expect(try consoleHas(&app, "Automatic import stopped: Unknown error"));
}

test "a sync of a database with an empty path queues no eviction, and an empty open path queues no sync" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{.{ .name = "evict-originals", .handler = evictOriginalsTask }});
    defer app.stop();
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            state.auto_import_running = true;
            try main_state.setOwned(main_state.stateAllocator(), &state.auto_import_database_path, "");
            state.sync_allowed = true;
            try main_state.setOwned(main_state.stateAllocator(), &state.current_database_path, "");
        }
    }.check);
    try endTask(&app, .{
        .task_id = "sync-empty",
        .task_type = "sync-database",
        .source = "",
        .input_json = "{\"databasePath\":\"\"}",
        .status = .succeeded,
        .error_message = null,
        .result_json = null,
        .started = true,
    });
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            try state.enqueueSyncTask(services, main_io, main_state.stateAllocator());
        }
    }.check);
    ziggy.fake_native_app.sleepMs(std.testing.io, 200);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"evicting\""));
    try std.testing.expect(!try consoleHas(&app, "Queuing sync task"));
    try std.testing.expect(!try isSyncRunning(&app));
}

test "main-command set-sync-allowed false logs the decision as false" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    std.testing.allocator.free(try app.requestOk("main-command", "{\"command\":\"set-sync-allowed\",\"allowed\":false}"));
    try std.testing.expect(try consoleHas(&app, "Sync gate set to false"));
}

const std = @import("std");
const ziggy = @import("ziggy-core");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const support = @import("test-support.zig");
const main_state = @import("../lib/main-state.zig");
const main_process = @import("../lib/main-process.zig");

const TestApp = support.TestApp;

//
// Makes a database directory that holds a .db/config.json with the text, and returns its path. The caller frees it.
//
fn makeDatabase(app: *TestApp, name: []const u8, config_json: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app.tmp_path, name });
    const config_path = try std.fmt.allocPrint(allocator, "{s}/.db/config.json", .{database_path});
    defer allocator.free(config_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(config_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = config_path,
        .data = config_json,
    });
    return database_path;
}

//
// A task that sends a message and then runs until it is cancelled.
//
fn spinTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .spinning = true });
    while (true) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(2), .awake);
    }
}

fn waitFor(app: *TestApp, text: []const u8) !void {
    try app.shell.expectMessageContaining(text);
}

//
// Waits until the check that automatic import is running, which the main process makes as soon as it starts, has ended, so that a
// test that sets what the state remembers about automatic import by hand is not undone by it.
//
fn waitForStartupCheck(app: *TestApp) !void {
    try app.shell.expectMessageContaining("\"source\":\"ensure-auto-import\",\"status\":\"succeeded\"");
}

test "notify-database-opened adds an entry for a database that has none, with the origin from its config.json" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "opened-new", "{\"origin\":\"/the/origin\"}");
    defer allocator.free(database_path);
    const path_json = try std.json.Stringify.valueAlloc(allocator, database_path, .{});
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
    const state = main_state.fromCore(app.core);
    state.lock();
    defer state.unlock();
    try std.testing.expect(state.is_database_open);
    try std.testing.expectEqualStrings(database_path, state.current_database_path.?);
}

test "notify-database-opened refreshes the origin of a database that is already listed" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "opened-existing", "{\"origin\":\"/new/origin\"}");
    defer allocator.free(database_path);
    const path_json = try std.json.Stringify.valueAlloc(allocator, database_path, .{});
    defer allocator.free(path_json);
    const entry_json = try std.fmt.allocPrint(allocator, "{{\"name\":\"listed\",\"description\":\"mine\",\"path\":{s},\"origin\":\"/old/origin\"}}", .{path_json});
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
    try std.testing.expectEqualStrings("The database that was opened needs a path.", reply);
}

test "notify-database-closed forgets the database to reopen and the open database" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "closed-one", "{}");
    defer allocator.free(database_path);
    const path_json = try std.json.Stringify.valueAlloc(allocator, database_path, .{});
    defer allocator.free(path_json);
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    const reply = try app.requestOk("notify-database-closed", "null");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expect((try node_api.databases_config.getLastDatabase(arena.allocator(), std.testing.io)) == null);
    const state = main_state.fromCore(app.core);
    state.lock();
    defer state.unlock();
    try std.testing.expect(!state.is_database_open);
    try std.testing.expect(state.current_database_path == null);
}

test "main-command set-sync-allowed records the decision, and an edit then queues a sync after the debounce" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const state = main_state.fromCore(app.core);
    state.sync_debounce_ms = 30;
    const database_path = try makeDatabase(&app, "sync-me", "{}");
    defer allocator.free(database_path);
    const path_json = try std.json.Stringify.valueAlloc(allocator, database_path, .{});
    defer allocator.free(path_json);
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    // Syncing is not allowed yet, so an edit queues nothing.
    allocator.free(try app.requestOk("notify-database-edited", "null"));
    app.shell.sleepMs(200);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("sync-database"));
    allocator.free(try app.requestOk("main-command", "{\"command\":\"set-sync-allowed\",\"allowed\":true}"));
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Sync allowed set to true") != null);
    // No sync-database task type is registered in this core, so the task fails, which is how the end of a sync is seen: the running
    // flag is reset and the page is told the sync completed.
    try waitFor(&app, "\"channel\":\"sync-completed\"");
    state.lock();
    defer state.unlock();
    try std.testing.expect(state.sync_allowed);
    try std.testing.expect(!state.is_sync_running);
}

test "main-command set-sync-allowed with allowed false schedules nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const state = main_state.fromCore(app.core);
    state.sync_debounce_ms = 30;
    allocator.free(try app.requestOk("main-command", "{\"command\":\"set-sync-allowed\",\"allowed\":false}"));
    app.shell.sleepMs(200);
    state.lock();
    defer state.unlock();
    try std.testing.expect(!state.sync_allowed);
    try std.testing.expect(state.sync_debounce_at == null);
}

test "main-command toggle-devtools asks the shell to toggle the developer tools" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("main-command", "\"toggle-devtools\""));
    try std.testing.expectEqualStrings("toggle-devtools\n", app.shell.chosen_actions.items);
}

test "main-command with an unknown command is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("main-command", "\"fly-to-the-moon\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("Unknown main-command: fly-to-the-moon", reply);
}

test "main-command without a command is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("main-command", "{\"allowed\":true}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The main command needs the name of a command.", reply);
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
    const first_json = try std.json.Stringify.valueAlloc(allocator, first_path, .{});
    defer allocator.free(first_json);
    const second_json = try std.json.Stringify.valueAlloc(allocator, second_path, .{});
    defer allocator.free(second_json);
    allocator.free(try app.requestOk("notify-database-opened", first_json));
    const add_task = try std.fmt.allocPrint(allocator, "{{\"taskId\":\"long-1\",\"taskType\":\"spin\",\"source\":{s},\"data\":null,\"priority\":0}}", .{first_json});
    defer allocator.free(add_task);
    const message = try std.fmt.allocPrint(allocator, "{{\"channel\":\"add-task\",\"data\":{s}}}", .{add_task});
    defer allocator.free(message);
    app.core.postMessage(message);
    try waitFor(&app, "\"channel\":\"task-message\"");
    allocator.free(try app.requestOk("notify-database-opened", second_json));
    try waitFor(&app, "\"status\":\"cancelled\"");
}

test "a failed import tells the user, and an automatic import that stops clears what is remembered about it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    main_process.onTaskEnd(app.core, .{
        .task_id = "import-1",
        .task_type = "import-assets",
        .source = "manual",
        .input_json = "{}",
        .status = .failed,
        .error_message = "disk on fire",
    });
    try waitFor(&app, "{\"channel\":\"show-notification\",\"data\":{\"message\":\"Import failed: disk on fire\",\"color\":\"danger\",\"duration\":8000}}");
    try waitForStartupCheck(&app);
    const state = main_state.fromCore(app.core);
    state.lock();
    state.auto_import_running = true;
    try state.setOwned(&state.auto_import_task_id, "auto-1");
    try state.setOwned(&state.auto_import_database_path, "/auto/db");
    state.unlock();
    main_process.onTaskEnd(app.core, .{
        .task_id = "auto-1",
        .task_type = "import-assets",
        .source = "auto-import",
        .input_json = "{}",
        .status = .failed,
        .error_message = "crashed",
    });
    state.lock();
    defer state.unlock();
    try std.testing.expect(!state.auto_import_running);
    try std.testing.expect(state.auto_import_task_id == null);
    try std.testing.expect(state.auto_import_database_path == null);
    try std.testing.expectEqual(@as(usize, 1), app.shell.countContaining("Import failed"));
}

test "a replication that worked registers its destination and tells the user, and one that failed only tells the user" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    main_process.onTaskEnd(app.core, .{
        .task_id = "rep-1",
        .task_type = "replicate-database",
        .source = "src",
        .input_json = "{\"destPath\":\"/replicas/copy\",\"sourcePath\":\"/photos\",\"destEncryptionKey\":\"key-1\"}",
        .status = .succeeded,
        .error_message = null,
    });
    try waitFor(&app, "{\"channel\":\"databases-changed\",\"data\":null}");
    try waitFor(&app, "{\"channel\":\"show-notification\",\"data\":{\"message\":\"Replication completed for \\\"copy\\\"\",\"color\":\"success\"}}");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = (try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "copy")).?;
    try std.testing.expectEqualStrings("/replicas/copy", entry.path);
    try std.testing.expectEqualStrings("/photos", entry.origin.?);
    try std.testing.expectEqualStrings("key-1", entry.encryptionKey.?);
    main_process.onTaskEnd(app.core, .{
        .task_id = "rep-2",
        .task_type = "replicate-database",
        .source = "src",
        .input_json = "{\"destPath\":\"/replicas/other\"}",
        .status = .failed,
        .error_message = null,
    });
    try waitFor(&app, "\"message\":\"Replication failed: Unknown error\"");
    try std.testing.expect((try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "other")) == null);
}

test "a sync that fails tells the page it completed, and one that succeeds does not" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    state.lock();
    state.is_sync_running = true;
    state.unlock();
    main_process.onTaskEnd(app.core, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .input_json = "{\"databasePath\":\"/db\"}",
        .status = .succeeded,
        .error_message = null,
    });
    state.lock();
    try std.testing.expect(!state.is_sync_running);
    state.unlock();
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("sync-completed"));
    main_process.onTaskEnd(app.core, .{
        .task_id = "sync-2",
        .task_type = "sync-database",
        .source = "/db",
        .input_json = "{\"databasePath\":\"/db\"}",
        .status = .failed,
        .error_message = "offline",
    });
    try waitFor(&app, "{\"channel\":\"sync-completed\",\"data\":null}");
}

test "a sync task's started and completed messages are passed to the page as events" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    main_process.onTaskMessage(app.core, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .message_json = "{\"type\":\"sync-started\"}",
    });
    try waitFor(&app, "{\"channel\":\"sync-started\",\"data\":null}");
    main_process.onTaskMessage(app.core, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .message_json = "{\"type\":\"sync-completed\"}",
    });
    try waitFor(&app, "{\"channel\":\"sync-completed\",\"data\":null}");
    main_process.onTaskMessage(app.core, .{
        .task_id = "other",
        .task_type = "other",
        .source = "x",
        .message_json = "{\"type\":\"progress\"}",
    });
    try std.testing.expectEqual(@as(usize, 1), app.shell.countContaining("sync-started"));
}

test "the periodic sync queues a sync for the open database when syncing is allowed" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try makeDatabase(&app, "periodic", "{}");
    defer allocator.free(database_path);
    const path_json = try std.json.Stringify.valueAlloc(allocator, database_path, .{});
    defer allocator.free(path_json);
    allocator.free(try app.requestOk("notify-database-opened", path_json));
    const state = main_state.fromCore(app.core);
    state.lock();
    state.sync_allowed = true;
    state.sync_periodic_ms = 40;
    state.sync_periodic_at = state.now() + 40;
    state.unlock();
    try waitFor(&app, "\"channel\":\"sync-completed\"");
}

//
// A stand-in for the create-default-database task, which another part of the app provides: it ends at once.
//
fn createDefaultDatabaseTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .createdDefaultDatabase = true });
    return try context.arena.dupe(u8, "null");
}

//
// A stand-in for the import-assets task, which another part of the app provides: it reports that it started and then runs until it is
// cancelled.
//
fn importAssetsTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .importing = true });
    while (true) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(2), .awake);
    }
}

//
// A stand-in for the import-assets task that ends as soon as it starts, as one does when it cannot open its database.
//
fn importAssetsEndsAtOnceTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
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
    while (app.shell.countContaining(text) < wanted) {
        if (waited_ms >= 5000) {
            return error.MessageNeverArrived;
        }
        app.shell.sleepMs(10);
        waited_ms += 10;
    }
}

test "automatic import that was switched on before the app started is started by the app itself" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "/nowhere/startup-default-db", .{});
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    try app.startWithTasksAndConfigFile(&auto_import_tasks, config_yaml);
    defer app.stop();
    try waitFor(&app, "\"importing\":true");
    const state = main_state.fromCore(app.core);
    state.lock();
    defer state.unlock();
    try std.testing.expect(state.auto_import_running);
    try std.testing.expectEqualStrings(database_path, state.auto_import_database_path.?);
}

test "automatic import is started again by the periodic check after its task died" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "/nowhere/restart-default-db", .{});
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    try app.startWithTasksAndConfigFile(&auto_import_tasks, config_yaml);
    defer app.stop();
    try waitForCount(&app, "\"importing\":true", 1);
    const state = main_state.fromCore(app.core);
    state.lock();
    state.auto_import_check_ms = 40;
    state.auto_import_check_at = state.now() + 40;
    state.unlock();
    app.core.runner.cancelSource("auto-import");
    try waitForCount(&app, "\"importing\":true", 2);
}

test "a failure to start automatic import at startup is logged, not lost" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "/nowhere/failing-default-db", .{});
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    // No create-default-database task is registered, so making the default database fails.
    try app.startWithTasksAndConfigFile(&[_]ziggy.task_runner.TaskHandlerEntry{}, config_yaml);
    defer app.stop();
    var waited_ms: i64 = 0;
    while (std.mem.indexOf(u8, app.console_out.writer.buffered(), "Error starting automatic import") == null and
        std.mem.indexOf(u8, app.console_err.writer.buffered(), "Error starting automatic import") == null)
    {
        if (waited_ms >= 5000) {
            return error.MessageNeverArrived;
        }
        app.shell.sleepMs(10);
        waited_ms += 10;
    }
}

test "an automatic import that ends the moment it starts is not remembered as running" {
    var app: TestApp = undefined;
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "/nowhere/short-lived-db", .{});
    defer allocator.free(database_path);
    const config_yaml = try autoImportConfigYaml(allocator, database_path);
    defer allocator.free(config_yaml);
    try app.startWithTasksAndConfigFile(&[_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "create-default-database", .handler = createDefaultDatabaseTask },
        .{ .name = "import-assets", .handler = importAssetsEndsAtOnceTask },
    }, config_yaml);
    defer app.stop();
    const state = main_state.fromCore(app.core);
    // The check runs every few milliseconds, so every start that loses the race to its own end would leave the state saying that the
    // import is running while no task is, and the next check would then see nothing to do. Count the starts: every end must be followed
    // by another start, because the state must say it is not running.
    state.lock();
    state.auto_import_check_ms = 20;
    state.auto_import_check_at = state.now();
    state.unlock();
    try waitForCount(&app, "the database could not be opened", 8);
}

test "a sync that succeeded with an input that is not JSON is reported, not ignored" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    main_process.onTaskEnd(app.core, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .input_json = "this is not json",
        .status = .succeeded,
        .error_message = null,
    });
    const logged = app.console_out.writer.buffered();
    const logged_errors = app.console_err.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, logged, "Error handling the end of a task") != null or
        std.mem.indexOf(u8, logged_errors, "Error handling the end of a task") != null);
}

test "an import that failed with an empty error message says the error is unknown" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    main_process.onTaskEnd(app.core, .{
        .task_id = "import-2",
        .task_type = "import-assets",
        .source = "manual",
        .input_json = "{}",
        .status = .failed,
        .error_message = "",
    });
    try waitFor(&app, "\"message\":\"Import failed: Unknown error\"");
}

//
// A stand-in for the evict-originals task, which another part of the app provides: it reports what it was asked to do.
//
fn evictOriginalsTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    try context.sendMessage(.{ .evicting = data });
    return try context.arena.dupe(u8, "null");
}

test "a sync that succeeded queues the eviction of originals only for the database automatic import fills" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{.{ .name = "evict-originals", .handler = evictOriginalsTask }});
    defer app.stop();
    try waitForStartupCheck(&app);
    const state = main_state.fromCore(app.core);
    state.lock();
    state.auto_import_running = true;
    try state.setOwned(&state.auto_import_database_path, "/the/default/db");
    state.unlock();
    main_process.onTaskEnd(app.core, .{
        .task_id = "sync-other",
        .task_type = "sync-database",
        .source = "/another/db",
        .input_json = "{\"databasePath\":\"/another/db\"}",
        .status = .succeeded,
        .error_message = null,
    });
    app.shell.sleepMs(100);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("\"evicting\""));
    main_process.onTaskEnd(app.core, .{
        .task_id = "sync-default",
        .task_type = "sync-database",
        .source = "/the/default/db",
        .input_json = "{\"databasePath\":\"/the/default/db\"}",
        .status = .succeeded,
        .error_message = null,
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
    };
    main_process.onTaskEnd(app.core, end);
    try waitFor(&app, "Replication completed for");
    main_process.onTaskEnd(app.core, end);
    try waitForCount(&app, "Replication completed for", 2);
    try std.testing.expectEqual(@as(usize, 1), app.shell.countContaining("\"channel\":\"databases-changed\""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const databases = try node_api.databases_config.getDatabases(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), databases.len);
}

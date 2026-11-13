const std = @import("std");
const ziggy = @import("ziggy");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const utils = @import("utils-zig");

const TestApp = support.TestApp;

//
// What the state on the main thread holds of automatic import.
//
const AutoImportState = struct {
    // Whether automatic import is running.
    running: bool = false,
    // Whether an ensure-auto-import task is queued or running.
    starting: bool = false,
    // A copy of the database automatic import is writing to, or null. Freed by deinit.
    database_path: ?[]const u8 = null,

    //
    // Reads the state, which the test is sent as JSON. Runs on the main thread.
    //
    fn run(_: u8, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io, _: std.mem.Allocator) anyerror!AutoImportState {
        const state = main_state.current();
        return .{
            .running = state.auto_import_running,
            .starting = state.auto_import_starting,
            .database_path = state.auto_import_database_path,
        };
    }

    fn deinit(self: *AutoImportState) void {
        if (self.database_path) |path| {
            std.testing.allocator.free(path);
        }
    }
};

//
// Reads what the state holds of automatic import. The caller frees it with deinit.
//
fn readAutoImport(app: *TestApp) !AutoImportState {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const read = try app.onMainThreadWith(arena_state.allocator(), @as(u8, 0), AutoImportState.run);
    return .{
        .running = read.running,
        .starting = read.starting,
        .database_path = if (read.database_path) |path| try std.testing.allocator.dupe(u8, path) else null,
    };
}

fn expectReply(app: *TestApp, message_type: []const u8, data_json: []const u8, expected_json: []const u8) !void {
    const reply = try app.requestOk(message_type, data_json);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings(expected_json, reply);
}

test "set-config stores a setting that get-config then returns" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"developerMode\",\"value\":true}", "null");
    try expectReply(&app, "get-config", "\"developerMode\"", "true");
    try expectReply(&app, "set-config", "{\"key\":\"savedSearches\",\"value\":[\"cats\",\"dogs\"]}", "null");
    try expectReply(&app, "get-config", "\"savedSearches\"", "[\"cats\",\"dogs\"]");
}

test "get-config replies null for a setting nothing is stored under" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "get-config", "\"developerMode\"", "null");
}

test "set-config with a null value removes the setting" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"developerMode\",\"value\":true}", "null");
    try expectReply(&app, "set-config", "{\"key\":\"developerMode\",\"value\":null}", "null");
    try expectReply(&app, "get-config", "\"developerMode\"", "null");
}

test "set-config of the places to watch keeps each folder with whether it is searched below" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"autoImportSources\",\"value\":[{\"type\":\"folder\",\"path\":\"/photos\",\"recurse\":false}]}", "null");
    try expectReply(&app, "get-config", "\"autoImportSources\"", "[{\"type\":\"folder\",\"path\":\"/photos\",\"recurse\":false}]");
}

test "set-config of a place to watch that is not one is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("set-config", "{\"key\":\"autoImportSources\",\"value\":[{\"type\":\"banana\"}]}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "not a folder or a device album") != null);
}

test "get-config and set-config without a key are error replies" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const get_reply = try app.requestError("get-config", "null");
    defer std.testing.allocator.free(get_reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", get_reply);
    const set_reply = try app.requestError("set-config", "{\"value\":1}");
    defer std.testing.allocator.free(set_reply);
    try std.testing.expectEqualStrings("InvalidMessageData: the field \"key\" is missing", set_reply);
}

//
// A fake of the create-default-database task, which another part of the app provides: it ends at once.
//
fn createDefaultDatabaseTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    try services.sendEvent(io, allocator, .{ .createdDefaultDatabaseFor = data });
    return try allocator.dupe(u8, "null");
}

//
// A fake of the import-assets task, which another part of the app provides: it reports what it was asked to do and then runs until
// it is cancelled.
//
fn importAssetsTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    try services.sendEvent(io, allocator, .{ .importing = data });
    while (true) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

test "switching automatic import on creates the default database and starts the import, and switching it off stops it" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "create-default-database", .handler = createDefaultDatabaseTask },
        .{ .name = "import-assets", .handler = importAssetsTask },
    });
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try std.fs.path.join(allocator, &.{ app.tmp_path, "default-db" });
    defer allocator.free(database_path);
    const path_request = try utils.json.stringify(allocator, .{
        .key = "defaultDatabasePath",
        .value = database_path,
    });
    defer allocator.free(path_request);
    try expectReply(&app, "set-config", path_request, "null");
    try expectReply(&app, "set-config", "{\"key\":\"autoImportSources\",\"value\":[{\"type\":\"folder\",\"path\":\"/watched\",\"recurse\":true}]}", "null");
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "createdDefaultDatabaseFor"));
    try expectReply(&app, "set-config", "{\"key\":\"autoImportEnabled\",\"value\":true}", "null");

    // The default database does not exist at that path, so it is created, and the page is told the databases changed.
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"createdDefaultDatabaseFor\":{\"databasePath\":");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"databases-changed\",\"data\":null}}");

    // The import is started, with the job the page lists and can cancel.
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"importing\":{\"paths\":[],\"storageDescriptor\":{\"databasePath\":");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"options\":{\"auto\":true,\"enabled\":true,\"sources\":[{\"type\":\"folder\",\"path\":\"/watched\",\"recurse\":true}]}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"cancelSource\":\"auto-import\"");
    {
        var auto_import = try readAutoImport(&app);
        defer auto_import.deinit();
        try std.testing.expect(auto_import.running);
        try std.testing.expectEqualStrings(database_path, auto_import.database_path.?);
    }

    // Writing the same settings again changes nothing: no second import is started.
    try expectReply(&app, "set-config", "{\"key\":\"autoImportEnabled\",\"value\":true}", "null");
    try std.testing.expectEqual(@as(usize, 1), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"importing\""));

    try expectReply(&app, "set-config", "{\"key\":\"autoImportEnabled\",\"value\":false}", "null");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Stopping automatic import.") != null);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"errorMessage\":\"Cancelled\"");
    var stopped = try readAutoImport(&app);
    defer stopped.deinit();
    try std.testing.expect(!stopped.running);
    try std.testing.expect(stopped.database_path == null);
}

test "switching automatic import on reports a default database that could not be created" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    // A file where the default database's folder would go, so creating the database there cannot work.
    const databases_dir = try std.fs.path.join(std.testing.allocator, &.{ app.tmp_path, "dbs" });
    defer std.testing.allocator.free(databases_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, databases_dir);
    const blocked_path = try std.fs.path.join(std.testing.allocator, &.{ databases_dir, "photosphere-default" });
    defer std.testing.allocator.free(blocked_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = blocked_path,
        .data = "this is a file, not a folder",
    });
    try expectReply(&app, "set-config", "{\"key\":\"autoImportSources\",\"value\":[{\"type\":\"folder\",\"path\":\"/watched\",\"recurse\":true}]}", "null");
    const reply = try app.requestError("set-config", "{\"key\":\"autoImportEnabled\",\"value\":true}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Failed to create the default photo database at") != null);
    var auto_import = try readAutoImport(&app);
    defer auto_import.deinit();
    try std.testing.expect(!auto_import.running);
    try std.testing.expect(!auto_import.starting);
}

test "a failing config request logs the error with the message of its handler" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.queueFailingTask("get-config", "null");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error getting config value") != null);
    try app.queueFailingTask("set-config", "null");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error setting config value") != null);
}

test "config requests that succeed log nothing to the error output" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("get-config", "\"developerMode\""));
    try std.testing.expectEqual(@as(usize, 0), (try app.consoleErr()).len);
}

test "reset-app-storage on desktop empties the settings and cache directories and leaves the app's data directory, which holds the default database, alone" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // TestApp points the cache directory into the test's own directory, or the reset would empty the developer's real one.
    const cache_dir = app.environ_map.get("PHOTOSPHERE_CACHE_DIR").?;
    const config_dir = try std.fs.path.join(allocator, &.{ app.tmp_path, "config" });
    defer allocator.free(config_dir);
    const settings_path = try std.fs.path.join(allocator, &.{ config_dir, "databases.toml" });
    defer allocator.free(settings_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = settings_path,
        .data = "databases = []",
    });
    const config_path = try app.configPath(allocator);
    defer allocator.free(config_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "developer_mode = true\n" });
    const state_path = try app.statePath(allocator);
    defer allocator.free(state_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = "{\"desktop\":{\"last_folder\":\"/p\"}}" });
    const hash_cache_dir = try std.fs.path.join(allocator, &.{ cache_dir, "a-database-key" });
    defer allocator.free(hash_cache_dir);
    try std.Io.Dir.cwd().createDirPath(io, hash_cache_dir);
    // The data directory is the test's own directory (TestApp gives the core tmp_path as data_dir).
    const default_database_dir = try std.fs.path.join(allocator, &.{ app.tmp_path, "default-database", ".db" });
    defer allocator.free(default_database_dir);
    try std.Io.Dir.cwd().createDirPath(io, default_database_dir);

    const message = try utils.json.stringify(allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = "reset-1",
            .taskType = "reset-app-storage",
            .source = "reset",
            .data = utils.json.Raw{
                .text = "{}",
            },
            .priority = "interactive",
        },
    });
    defer allocator.free(message);
    app.native_app.sendMessage(std.testing.allocator, message);

    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"reset-1\",\"status\":\"succeeded\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"entriesRemoved\":2");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"configFileDeleted\":true,\"stateFileDeleted\":true");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, config_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, state_path, .{}));
    var config_contents = try std.Io.Dir.cwd().openDir(io, config_dir, .{
        .iterate = true,
    });
    defer config_contents.close(io);
    var config_iterator = config_contents.iterate();
    try std.testing.expect((try config_iterator.next(io)) == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, hash_cache_dir, .{}));
    try std.Io.Dir.cwd().access(io, default_database_dir, .{});
}

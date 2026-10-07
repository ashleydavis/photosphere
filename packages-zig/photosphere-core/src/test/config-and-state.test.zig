const std = @import("std");
const ziggy = @import("ziggy-core");
const support = @import("test-support.zig");
const main_state = @import("../lib/main-state.zig");

const TestApp = support.TestApp;

fn expectReply(app: *TestApp, channel: []const u8, data_json: []const u8, expected_json: []const u8) !void {
    const reply = try app.requestOk(channel, data_json);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings(expected_json, reply);
}

test "set-state stores a value that get-state then returns" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-state", "{\"key\":\"gallerySort\",\"value\":\"date\"}", "null");
    try expectReply(&app, "get-state", "\"gallerySort\"", "\"date\"");
}

test "get-state replies null for a key nothing is remembered under" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "get-state", "\"lastFolder\"", "null");
    try expectReply(&app, "get-state", "\"something-the-page-made-up\"", "null");
}

test "set-state keeps the page's own working state under any key it chooses" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-state", "{\"key\":\"sidebar.collapsed\",\"value\":true}", "null");
    try expectReply(&app, "get-state", "\"sidebar.collapsed\"", "true");
    try expectReply(&app, "set-state", "{\"key\":\"recent\",\"value\":[\"a\",\"b\"]}", "null");
    try expectReply(&app, "get-state", "\"recent\"", "[\"a\",\"b\"]");
}

test "set-state with a null value, or none, removes the key" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-state", "{\"key\":\"gallerySort\",\"value\":\"date\"}", "null");
    try expectReply(&app, "set-state", "{\"key\":\"gallerySort\",\"value\":null}", "null");
    try expectReply(&app, "get-state", "\"gallerySort\"", "null");
    try expectReply(&app, "set-state", "{\"key\":\"lastFolder\",\"value\":\"/x\"}", "null");
    try expectReply(&app, "set-state", "{\"key\":\"lastFolder\"}", "null");
    try expectReply(&app, "get-state", "\"lastFolder\"", "null");
}

test "set-state with a value the key cannot hold is an error reply that says which key" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("set-state", "{\"key\":\"lastFolder\",\"value\":42}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"lastFolder\"") != null);
}

test "get-state and set-state without a key are error replies" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const get_reply = try app.requestError("get-state", "null");
    defer std.testing.allocator.free(get_reply);
    try std.testing.expectEqualStrings("The state request needs the name of a key.", get_reply);
    const set_reply = try app.requestError("set-state", "{\"value\":1}");
    defer std.testing.allocator.free(set_reply);
    try std.testing.expectEqualStrings("The state request needs the name of a key.", set_reply);
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
    try expectReply(&app, "get-config", "\"theme\"", "null");
}

test "set-config with a null value removes the setting" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"developerMode\",\"value\":true}", "null");
    try expectReply(&app, "set-config", "{\"key\":\"developerMode\",\"value\":null}", "null");
    try expectReply(&app, "get-config", "\"developerMode\"", "null");
}

test "set-config of the theme tells the page, so the menu bar can follow" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"theme\",\"value\":\"dark\"}", "null");
    try expectReply(&app, "get-config", "\"theme\"", "\"dark\"");
    try app.shell.expectMessageContaining("{\"channel\":\"theme-changed\",\"data\":\"dark\"}");
}

test "set-config of a theme that does not exist is an error reply and stores nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("set-config", "{\"key\":\"theme\",\"value\":\"neon\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"neon\" is not a theme") != null);
    try expectReply(&app, "get-config", "\"theme\"", "null");
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
    try std.testing.expectEqualStrings("The config request needs the name of a key.", get_reply);
    const set_reply = try app.requestError("set-config", "{\"value\":1}");
    defer std.testing.allocator.free(set_reply);
    try std.testing.expectEqualStrings("The config request needs the name of a key.", set_reply);
}

//
// A stand-in for the create-default-database task, which another part of the app provides: it ends at once.
//
fn createDefaultDatabaseTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    try context.sendMessage(.{ .createdDefaultDatabaseFor = data });
    return try context.arena.dupe(u8, "null");
}

//
// A stand-in for the import-assets task, which another part of the app provides: it reports what it was asked to do and then runs until
// it is cancelled.
//
fn importAssetsTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    try context.sendMessage(.{ .importing = data });
    while (true) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(2), .awake);
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
    const database_path = try std.fmt.allocPrint(allocator, "{s}/default-db", .{app.tmp_path});
    defer allocator.free(database_path);
    const database_path_json = try std.json.Stringify.valueAlloc(allocator, database_path, .{});
    defer allocator.free(database_path_json);
    const path_request = try std.fmt.allocPrint(allocator, "{{\"key\":\"defaultDatabasePath\",\"value\":{s}}}", .{database_path_json});
    defer allocator.free(path_request);
    try expectReply(&app, "set-config", path_request, "null");
    try expectReply(&app, "set-config", "{\"key\":\"autoImportSources\",\"value\":[{\"type\":\"folder\",\"path\":\"/watched\",\"recurse\":true}]}", "null");
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("createdDefaultDatabaseFor"));
    try expectReply(&app, "set-config", "{\"key\":\"autoImportEnabled\",\"value\":true}", "null");

    // The default database does not exist at that path, so it is created, and the page is told the databases changed.
    try app.shell.expectMessageContaining("\"createdDefaultDatabaseFor\":{\"databasePath\":");
    try app.shell.expectMessageContaining("{\"channel\":\"databases-changed\",\"data\":null}");

    // The import is started, with the job the page lists and can cancel.
    try app.shell.expectMessageContaining("\"importing\":{\"paths\":[],\"storageDescriptor\":{\"databasePath\":");
    try app.shell.expectMessageContaining("\"options\":{\"auto\":true,\"enabled\":true,\"sources\":[{\"type\":\"folder\",\"path\":\"/watched\",\"recurse\":true}]}");
    try app.shell.expectMessageContaining("\"cancelSource\":\"auto-import\"");
    const state = main_state.fromCore(app.core);
    {
        state.lock();
        defer state.unlock();
        try std.testing.expect(state.auto_import_running);
        try std.testing.expectEqualStrings(database_path, state.auto_import_database_path.?);
    }

    // Writing the same settings again changes nothing: no second import is started.
    try expectReply(&app, "set-config", "{\"key\":\"autoImportEnabled\",\"value\":true}", "null");
    try std.testing.expectEqual(@as(usize, 1), app.shell.countContaining("\"importing\""));

    try expectReply(&app, "set-config", "{\"key\":\"autoImportEnabled\",\"value\":false}", "null");
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Stopping automatic import.") != null);
    try app.shell.expectMessageContaining("\"status\":\"cancelled\"");
    state.lock();
    defer state.unlock();
    try std.testing.expect(!state.auto_import_running);
    try std.testing.expect(state.auto_import_database_path == null);
}

test "switching automatic import on reports a default database that could not be created" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"autoImportSources\",\"value\":[{\"type\":\"folder\",\"path\":\"/watched\",\"recurse\":true}]}", "null");
    const reply = try app.requestError("set-config", "{\"key\":\"autoImportEnabled\",\"value\":true}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Failed to create the default photo database at") != null);
    const state = main_state.fromCore(app.core);
    state.lock();
    defer state.unlock();
    try std.testing.expect(!state.auto_import_running);
    try std.testing.expect(!state.auto_import_starting);
}

test "set-config of the theme with no value removes it and tells the page, with no theme in the event" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectReply(&app, "set-config", "{\"key\":\"theme\",\"value\":\"dark\"}", "null");
    try expectReply(&app, "set-config", "{\"key\":\"theme\",\"value\":null}", "null");
    try expectReply(&app, "get-config", "\"theme\"", "null");
    // As in Electron, where the removed theme was sent as undefined, the event carries no data.
    try app.shell.expectMessageContaining("{\"channel\":\"theme-changed\"}");
}

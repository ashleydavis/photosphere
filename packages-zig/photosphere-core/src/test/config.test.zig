const std = @import("std");
const support = @import("test-support.zig");
const utils = @import("utils-zig");

const TestApp = support.TestApp;

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

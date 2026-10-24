const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// Queues a planning task with the add-task message the phone's loop sends.
//
fn addTask(app: *TestApp, task_id: []const u8, task_type: []const u8) !void {
    const message = try utils.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = task_id,
            .taskType = task_type,
            .source = "planning",
            .data = utils.json.Raw{ .text = "null" },
            .priority = "background",
        },
    });
    defer std.testing.allocator.free(message);
    app.native_app.sendMessage(std.testing.allocator, message);
}

test "plan-auto-import runs on Ziggy's runner and says not to run when nothing has been set" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var calls = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer calls.deinit();

    try addTask(&app, "plan-auto-1", "plan-auto-import");

    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"plan-auto-1\",\"status\":\"succeeded\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"shouldRun\":false");
}

test "plan-sync runs on Ziggy's runner and refuses when syncing is switched off, without asking the phone anything" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var calls = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer calls.deinit();

    try addTask(&app, "plan-sync-1", "plan-sync");

    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"plan-sync-1\",\"status\":\"succeeded\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "syncing is switched off");
    try std.testing.expect((try app.lastNativeCall(calls.allocator())) == null);
}

test "plan-sync asks the phone for the connection type when syncing is switched on, and a phone that cannot answer is an error that says so" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var calls = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer calls.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config_path = try node_api.config_file.getConfigPath(arena.allocator());
    var config = (try node_api.config_worker.readConfigFromStorage(arena.allocator(), std.testing.io, config_path)).config;
    config.sync.settings.enabled = true;
    const yaml = try node_api.config_worker.buildConfigYaml(arena.allocator(), config, null);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(config_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = config_path,
        .data = yaml,
    });
    app.setNativeCallResult(false, "The phone cannot tell.");

    try addTask(&app, "plan-sync-2", "plan-sync");

    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"plan-sync-2\",\"status\":\"failed\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "The phone cannot tell.");
    try std.testing.expectEqualStrings("networkConnectionType", (try app.lastNativeCall(calls.allocator())).?.method);
}

test "plan-prefetch runs on Ziggy's runner and does not ask the phone when no database is chosen to prefetch" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var calls = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer calls.deinit();

    try addTask(&app, "plan-prefetch-1", "plan-prefetch");

    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"plan-prefetch-1\",\"status\":\"succeeded\"");
}

test "write-config records the database to sync in the config file the core reads, and read-config gives it back whatever path the request names" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var calls = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer calls.deinit();

    const write = try utils.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = "write-config-1",
            .taskType = "write-config",
            .source = "settings",
            .data = .{
                .configPath = "config.yaml",
                .sync = .{
                    .settings = .{
                        .enabled = true,
                        .onlyOnWifi = false,
                    },
                    .databasePath = "/data/photos",
                    .pauseBetweenRunsMs = 4000,
                },
            },
            .priority = "interactive",
        },
    });
    defer std.testing.allocator.free(write);
    app.native_app.sendMessage(std.testing.allocator, write);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"write-config-1\",\"status\":\"succeeded\"");

    const read = try utils.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = "read-config-1",
            .taskType = "read-config",
            .source = "settings",
            .data = .{
                .configPath = "config.yaml",
            },
            .priority = "interactive",
        },
    });
    defer std.testing.allocator.free(read);
    app.native_app.sendMessage(std.testing.allocator, read);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"read-config-1\",\"status\":\"succeeded\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"databasePath\":\"/data/photos\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"syncSettingsWritten\":true");
}

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// A fake of the save-asset task, which another part of the app provides: it reports what it was asked to write.
//
fn saveAssetTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    try services.sendEvent(io, allocator, .{ .savedAsset = data });
    return try allocator.dupe(u8, "null");
}

//
// A fake of the save-assets-batch task: it reports what it was asked to write and says which files it wrote and which it did not.
//
fn saveAssetsBatchTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    try services.sendEvent(io, allocator, .{ .savedBatch = data });
    return try allocator.dupe(u8, "{\"succeededFiles\":[\"a.jpg\",\"b.jpg\"],\"failedFiles\":[\"c.jpg\"]}");
}

//
// A fake save task that fails, with a message the user can read.
//
fn failingSaveTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    _ = context;
    _ = data;
    return utils.errors.throwError("There is no room left on the disk.", .{});
}

const saving_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "save-asset", .handler = saveAssetTask },
    .{ .name = "save-assets-batch", .handler = saveAssetsBatchTask },
};

const failing_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "save-asset", .handler = failingSaveTask },
    .{ .name = "save-assets-batch", .handler = failingSaveTask },
};

fn expectReply(app: *TestApp, message_type: []const u8, data_json: []const u8, expected_json: []const u8) !void {
    const reply = try app.requestOk(message_type, data_json);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings(expected_json, reply);
}

test "save-assets with one asset shows a Save As dialog and writes the asset where the user chose" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/photo.jpg\"]");
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"saved\",\"savedCount\":1,\"failedCount\":0,\"savedFolder\":\"/downloads\"}");
    try std.testing.expectEqual(@as(i32, 1), try app.lastPickKind(picks.allocator()));
    try std.testing.expectEqualStrings("photo.jpg", (try app.lastPick(picks.allocator())).?.initialName.?);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"savedAsset\":{\"assetId\":\"a1\",\"assetType\":\"asset\",\"destPath\":\"/downloads/photo.jpg\",\"databasePath\":\"/db\"}");
}

test "save-assets with one asset says it was cancelled when the user cancelled the dialog, and writes nothing" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"cancelled\",\"savedCount\":0,\"failedCount\":0}");
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "savedAsset"));
}

test "save-assets with one asset says why when the write failed" {
    var app: TestApp = undefined;
    try app.startWithTasks(&failing_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/photo.jpg\"]");
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"failed\",\"savedCount\":0,\"failedCount\":1,\"errorMessage\":\"There is no room left on the disk.\"}");
}

test "save-assets with several assets shows a folder dialog and says how many were written and how many were not" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/many\"]");
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"},{\"assetId\":\"a3\",\"assetType\":\"asset\",\"filename\":\"c.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"saved\",\"savedCount\":2,\"failedCount\":1,\"savedFolder\":\"/downloads/many\"}");
    try std.testing.expectEqual(@as(i32, 2), try app.lastPickKind(picks.allocator()));
    try std.testing.expectEqualStrings("Choose folder to save assets", (try app.lastPick(picks.allocator())).?.title.?);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"savedBatch\":{\"assets\":[{\"assetId\":\"a1\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"folderPath\":\"/downloads/many\",\"databasePath\":\"/db\"}");
    const remembered = try app.requestOk("get-state", "\"lastDownloadFolder\"");
    defer std.testing.allocator.free(remembered);
    try std.testing.expectEqualStrings("\"/downloads/many\"", remembered);
}

test "save-assets with several assets says it was cancelled when the user cancelled the dialog" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"cancelled\",\"savedCount\":0,\"failedCount\":0}");
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "savedBatch"));
}

test "save-assets with several assets counts every asset as failed when the batch failed" {
    var app: TestApp = undefined;
    try app.startWithTasks(&failing_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/many\"]");
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"failed\",\"savedCount\":0,\"failedCount\":2,\"errorMessage\":\"There is no room left on the disk.\"}");
}

test "save-assets without the assets is an error reply" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestError("save-assets", "{\"databasePath\":\"/db\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(reply.len > 0);
}

test "save-asset with a destination writes the asset there without showing a dialog" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\",\"destPath\":\"/chosen/by/the/model.jpg\"}", "null");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"savedAsset\":{\"assetId\":\"a1\",\"assetType\":\"asset\",\"destPath\":\"/chosen/by/the/model.jpg\",\"databasePath\":\"/db\"}");
    try std.testing.expectEqual(@as(i32, -1), try app.lastPickKind(picks.allocator()));
}

test "save-asset without a destination asks the user where, and writes nothing when they cancel" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\"}", "null");
    try std.testing.expectEqual(@as(i32, 1), try app.lastPickKind(picks.allocator()));
    try std.testing.expectEqualStrings("photo.jpg", (try app.lastPick(picks.allocator())).?.initialName.?);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "savedAsset"));
}

test "save-asset without a destination writes where the user chose" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/chosen.jpg\"]");
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\"}", "null");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"destPath\":\"/downloads/chosen.jpg\"");
}

test "save-asset without the path of its database is an error reply" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestError("save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: the field \"databasePath\" is missing", reply);
}

test "open-path without a path is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestError("open-path", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "a failing save task logs the error with the message of its handler" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"save-asset-1\",\"taskType\":\"save-asset-request\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"save-asset-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error saving asset") != null);
    app.native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"save-assets-1\",\"taskType\":\"save-assets\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"save-assets-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error saving assets") != null);
    app.native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"open-path-1\",\"taskType\":\"open-path\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"open-path-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error opening path") != null);
}

test "save-asset with a destination does not need a file name" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"databasePath\":\"/db\",\"destPath\":\"/chosen/by/the/model.jpg\"}", "null");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"destPath\":\"/chosen/by/the/model.jpg\"");
}

test "save-asset without a destination or a file name is an error reply" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestError("save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"databasePath\":\"/db\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The asset to save needs a file name to suggest in the save dialog.", reply);
}

test "save-asset ignores the test mode answer for the save dialog" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_PICK_FILE_PATH", "/from/the/environment.jpg");
    try app.launchWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/chosen.jpg\"]");
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\"}", "null");
    try std.testing.expectEqual(@as(i32, 1), try app.lastPickKind(picks.allocator()));
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"destPath\":\"/downloads/chosen.jpg\"");
}

test "save-assets with one asset takes its path from PHOTOSPHERE_TEST_PICK_FILE_PATH in test mode" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_PICK_FILE_PATH", "/from/the/environment.jpg");
    try app.launchWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"saved\",\"savedCount\":1,\"failedCount\":0,\"savedFolder\":\"/from/the\"}");
    try std.testing.expectEqual(@as(i32, -1), try app.lastPickKind(picks.allocator()));
}

test "save-assets with several assets takes its folder from PHOTOSPHERE_TEST_DOWNLOAD_FOLDER in test mode" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER", "/from/the/download-folder");
    try app.launchWithTasks(&saving_tasks);
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"saved\",\"savedCount\":2,\"failedCount\":1,\"savedFolder\":\"/from/the/download-folder\"}");
    try std.testing.expectEqual(@as(i32, -1), try app.lastPickKind(picks.allocator()));
}

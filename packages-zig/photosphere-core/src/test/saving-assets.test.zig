const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// A stand-in for the save-asset task, which another part of the app provides: it reports what it was asked to write.
//
fn saveAssetTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    try context.sendMessage(.{ .savedAsset = data });
    return try context.arena.dupe(u8, "null");
}

//
// A stand-in for the save-assets-batch task: it reports what it was asked to write and says which files it wrote and which it did not.
//
fn saveAssetsBatchTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    try context.sendMessage(.{ .savedBatch = data });
    return try context.arena.dupe(u8, "{\"succeededFiles\":[\"a.jpg\",\"b.jpg\"],\"failedFiles\":[\"c.jpg\"]}");
}

//
// A stand-in for a save task that fails, with a message the user can read.
//
fn failingSaveTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
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

fn expectReply(app: *TestApp, channel: []const u8, data_json: []const u8, expected_json: []const u8) !void {
    const reply = try app.requestOk(channel, data_json);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings(expected_json, reply);
}

test "save-assets with one asset shows a Save As dialog and writes the asset where the user chose" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    app.pick_answer = "[\"/downloads/photo.jpg\"]";
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"saved\",\"savedCount\":1,\"failedCount\":0,\"savedFolder\":\"/downloads\"}");
    try std.testing.expectEqual(@as(i32, 1), app.last_pick_kind);
    try std.testing.expectEqualStrings("photo.jpg", app.last_pick_initial.?);
    try app.shell.expectMessageContaining("\"savedAsset\":{\"assetId\":\"a1\",\"assetType\":\"asset\",\"destPath\":\"/downloads/photo.jpg\",\"databasePath\":\"/db\"}");
}

test "save-assets with one asset says it was cancelled when the user cancelled the dialog, and writes nothing" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"cancelled\",\"savedCount\":0,\"failedCount\":0}");
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("savedAsset"));
}

test "save-assets with one asset says why when the write failed" {
    var app: TestApp = undefined;
    try app.startWithTasks(&failing_tasks);
    defer app.stop();
    app.pick_answer = "[\"/downloads/photo.jpg\"]";
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"failed\",\"savedCount\":0,\"failedCount\":1,\"errorMessage\":\"There is no room left on the disk.\"}");
}

test "save-assets with several assets shows a folder dialog and says how many were written and how many were not" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    app.pick_answer = "[\"/downloads/many\"]";
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"},{\"assetId\":\"a3\",\"assetType\":\"asset\",\"filename\":\"c.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"saved\",\"savedCount\":2,\"failedCount\":1,\"savedFolder\":\"/downloads/many\"}");
    try std.testing.expectEqual(@as(i32, 2), app.last_pick_kind);
    try std.testing.expectEqualStrings("Choose folder to save assets", app.last_pick_title.?);
    try app.shell.expectMessageContaining("\"savedBatch\":{\"assets\":[{\"assetId\":\"a1\"");
    try app.shell.expectMessageContaining("\"folderPath\":\"/downloads/many\",\"databasePath\":\"/db\"}");
    const remembered = try app.requestOk("get-state", "\"lastDownloadFolder\"");
    defer std.testing.allocator.free(remembered);
    try std.testing.expectEqualStrings("\"/downloads/many\"", remembered);
}

test "save-assets with several assets says it was cancelled when the user cancelled the dialog" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"cancelled\",\"savedCount\":0,\"failedCount\":0}");
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("savedBatch"));
}

test "save-assets with several assets counts every asset as failed when the batch failed" {
    var app: TestApp = undefined;
    try app.startWithTasks(&failing_tasks);
    defer app.stop();
    app.pick_answer = "[\"/downloads/many\"]";
    try expectReply(&app, "save-assets", "{\"items\":[{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"a.jpg\"},{\"assetId\":\"a2\",\"assetType\":\"asset\",\"filename\":\"b.jpg\"}],\"databasePath\":\"/db\"}", "{\"outcome\":\"failed\",\"savedCount\":0,\"failedCount\":2,\"errorMessage\":\"There is no room left on the disk.\"}");
}

test "save-assets without the assets is an error reply" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    const reply = try app.requestError("save-assets", "{\"databasePath\":\"/db\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(reply.len > 0);
}

test "save-asset with a destination writes the asset there without showing a dialog" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\",\"destPath\":\"/chosen/by/the/model.jpg\"}", "null");
    try app.shell.expectMessageContaining("\"savedAsset\":{\"assetId\":\"a1\",\"assetType\":\"asset\",\"destPath\":\"/chosen/by/the/model.jpg\",\"databasePath\":\"/db\"}");
    try std.testing.expectEqual(@as(i32, -1), app.last_pick_kind);
}

test "save-asset without a destination asks the user where, and writes nothing when they cancel" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\"}", "null");
    try std.testing.expectEqual(@as(i32, 1), app.last_pick_kind);
    try std.testing.expectEqualStrings("photo.jpg", app.last_pick_initial.?);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("savedAsset"));
}

test "save-asset without a destination writes where the user chose" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    app.pick_answer = "[\"/downloads/chosen.jpg\"]";
    try expectReply(&app, "save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\",\"databasePath\":\"/db\"}", "null");
    try app.shell.expectMessageContaining("\"destPath\":\"/downloads/chosen.jpg\"");
}

test "save-asset without the path of its database is an error reply" {
    var app: TestApp = undefined;
    try app.startWithTasks(&saving_tasks);
    defer app.stop();
    const reply = try app.requestError("save-asset", "{\"assetId\":\"a1\",\"assetType\":\"asset\",\"filename\":\"photo.jpg\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The asset to save needs the path of its database.", reply);
}

test "open-path without a path is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("open-path", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The folder to open needs a path.", reply);
}

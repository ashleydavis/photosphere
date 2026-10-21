const std = @import("std");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

fn expectState(app: *TestApp, key: []const u8, expected_json: []const u8) !void {
    const allocator = std.testing.allocator;
    const key_json = try std.json.Stringify.valueAlloc(allocator, key, .{});
    defer allocator.free(key_json);
    const reply = try app.requestOk("get-state", key_json);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings(expected_json, reply);
}

test "pick-folder shows a folder dialog, remembers the folder, and starts there next time" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    app.pick_answer = "[\"/chosen/dir\"]";
    const reply = try app.requestOk("pick-folder", "null");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("\"/chosen/dir\"", reply);
    try std.testing.expectEqual(@as(i32, 2), app.last_pick_kind);
    try std.testing.expectEqualStrings("Select Folder", app.last_pick_title.?);
    try std.testing.expect(app.last_pick_initial == null);
    try expectState(&app, "lastFolder", "\"/chosen/dir\"");
    app.pick_answer = "[\"/other/dir\"]";
    allocator.free(try app.requestOk("pick-folder", "{\"title\":\"Pick one\"}"));
    try std.testing.expectEqualStrings("Pick one", app.last_pick_title.?);
    try std.testing.expectEqualStrings("/chosen/dir", app.last_pick_initial.?);
}

test "pick-folder remembers the folder under the key it was given" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    app.pick_answer = "[\"/downloads\"]";
    allocator.free(try app.requestOk("pick-folder", "{\"title\":\"Save\",\"folderKey\":\"lastDownloadFolder\",\"createDirectory\":true}"));
    try expectState(&app, "lastDownloadFolder", "\"/downloads\"");
    try expectState(&app, "lastFolder", "null");
}

test "pick-folder replies null when the user cancelled and remembers nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("pick-folder", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try expectState(&app, "lastFolder", "null");
}

test "pick-folder with a key that remembers no folder is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("pick-folder", "{\"folderKey\":\"gallerySort\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Unknown folder state key \"gallerySort\"") != null);
}

test "pick-file shows a save dialog with the suggested name and remembers the folder of the path chosen" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    app.pick_answer = "[\"/downloads/photo.jpg\"]";
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("\"/downloads/photo.jpg\"", reply);
    try std.testing.expectEqual(@as(i32, 1), app.last_pick_kind);
    try std.testing.expectEqualStrings("photo.jpg", app.last_pick_initial.?);
    try expectState(&app, "lastDownloadFolder", "\"/downloads\"");
}

test "pick-file replies null when the user cancelled" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try expectState(&app, "lastDownloadFolder", "null");
}

test "pick-file without a suggested name is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("pick-file", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "pick-files replies every path chosen, in a dialog that starts in the last folder" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("set-state", "{\"key\":\"lastFolder\",\"value\":\"/photos\"}"));
    app.pick_answer = "[\"/photos/a.jpg\",\"/photos/b.jpg\"]";
    const reply = try app.requestOk("pick-files", "\"Choose photos\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("[\"/photos/a.jpg\",\"/photos/b.jpg\"]", reply);
    try std.testing.expectEqual(@as(i32, 0), app.last_pick_kind);
    try std.testing.expectEqualStrings("Choose photos", app.last_pick_title.?);
    try std.testing.expectEqualStrings("/photos", app.last_pick_initial.?);
}

test "pick-files replies null when the user cancelled" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("pick-files", "\"Choose photos\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
}

test "open-database tells the page to load the folder chosen and remembers the folder that holds it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    app.pick_answer = "[\"/databases/my-photos\"]";
    const reply = try app.requestOk("open-database", "null");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try std.testing.expectEqualStrings("Open Database", app.last_pick_title.?);
    try app.shell.expectMessageContaining("{\"kind\":\"app\",\"data\":{\"type\":\"database-opened\",\"data\":\"/databases/my-photos\"}}");
    try expectState(&app, "lastFolder", "\"/databases\"");
}

test "open-database sends no event when the user cancelled" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("open-database", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("database-opened"));
}

test "pick-folder treats an empty title and an empty key as none" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    app.pick_answer = "[\"/chosen/dir\"]";
    std.testing.allocator.free(try app.requestOk("pick-folder", "{\"title\":\"\",\"folderKey\":\"\"}"));
    try std.testing.expectEqualStrings("Select Folder", app.last_pick_title.?);
    try expectState(&app, "lastFolder", "\"/chosen/dir\"");
}

test "a failing dialog task logs the error with the message of its handler" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    app.core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"pick-file-1\",\"taskType\":\"pick-file\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.shell.expectMessageContaining("\"taskId\":\"pick-file-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, app.console_err.written(), "Error picking save location") != null);
    app.core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"pick-files-1\",\"taskType\":\"pick-files\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.shell.expectMessageContaining("\"taskId\":\"pick-files-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, app.console_err.written(), "Error picking files") != null);
    allocator.free(try app.requestError("pick-folder", "{\"folderKey\":\"gallerySort\"}"));
    try std.testing.expect(std.mem.indexOf(u8, app.console_err.written(), "Error picking folder") != null);
}

test "pick-file takes its answer from PHOTOSPHERE_TEST_PICK_FILE_PATH in test mode, with no dialog and nothing remembered" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_PICK_FILE_PATH", "/from/the/environment.jpg");
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/from/the/environment.jpg\"", reply);
    try std.testing.expectEqual(@as(i32, -1), app.last_pick_kind);
    try expectState(&app, "lastDownloadFolder", "null");
}

test "pick-file ignores PHOTOSPHERE_TEST_PICK_FILE_PATH outside test mode" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "0");
    try app.environ_map.put("PHOTOSPHERE_TEST_PICK_FILE_PATH", "/from/the/environment.jpg");
    app.pick_answer = "[\"/downloads/photo.jpg\"]";
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/downloads/photo.jpg\"", reply);
    try std.testing.expectEqual(@as(i32, 1), app.last_pick_kind);
}

test "pick-folder for the download folder takes its answer from PHOTOSPHERE_TEST_DOWNLOAD_FOLDER in test mode, with no dialog and nothing remembered" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER", "/from/the/download-folder");
    const reply = try app.requestOk("pick-folder", "{\"folderKey\":\"lastDownloadFolder\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/from/the/download-folder\"", reply);
    try std.testing.expectEqual(@as(i32, -1), app.last_pick_kind);
    try expectState(&app, "lastDownloadFolder", "null");
}

test "pick-folder for any other folder ignores PHOTOSPHERE_TEST_DOWNLOAD_FOLDER, and so does a run outside test mode" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER", "/from/the/download-folder");
    app.pick_answer = "[\"/chosen/dir\"]";
    const other = try app.requestOk("pick-folder", "null");
    defer allocator.free(other);
    try std.testing.expectEqualStrings("\"/chosen/dir\"", other);
    try std.testing.expectEqual(@as(i32, 2), app.last_pick_kind);
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "0");
    app.pick_answer = "[\"/chosen/downloads\"]";
    const download = try app.requestOk("pick-folder", "{\"folderKey\":\"lastDownloadFolder\"}");
    defer allocator.free(download);
    try std.testing.expectEqualStrings("\"/chosen/downloads\"", download);
}

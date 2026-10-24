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
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const allocator = std.testing.allocator;
    app.setPickResult("[\"/chosen/dir\"]");
    const reply = try app.requestOk("pick-folder", "null");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("\"/chosen/dir\"", reply);
    try std.testing.expectEqual(@as(i32, 2), try app.lastPickKind(picks.allocator()));
    try std.testing.expectEqualStrings("Select Folder", (try app.lastPick(picks.allocator())).?.title.?);
    try std.testing.expect((try app.lastPick(picks.allocator())).?.initialName == null);
    try expectState(&app, "lastFolder", "\"/chosen/dir\"");
    app.setPickResult("[\"/other/dir\"]");
    allocator.free(try app.requestOk("pick-folder", "{\"title\":\"Pick one\"}"));
    try std.testing.expectEqualStrings("Pick one", (try app.lastPick(picks.allocator())).?.title.?);
    try std.testing.expectEqualStrings("/chosen/dir", (try app.lastPick(picks.allocator())).?.initialName.?);
}

test "pick-folder remembers the folder under the key it was given" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const allocator = std.testing.allocator;
    app.setPickResult("[\"/downloads\"]");
    allocator.free(try app.requestOk("pick-folder", "{\"title\":\"Save\",\"folderKey\":\"lastDownloadFolder\",\"createDirectory\":true}"));
    try expectState(&app, "lastDownloadFolder", "\"/downloads\"");
    try expectState(&app, "lastFolder", "null");
}

test "pick-folder replies null when the user cancelled and remembers nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestOk("pick-folder", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try expectState(&app, "lastFolder", "null");
}

test "pick-folder with a key that remembers no folder is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestError("pick-folder", "{\"folderKey\":\"gallerySort\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Unknown folder state key \"gallerySort\"") != null);
}

test "pick-file shows a save dialog with the suggested name and remembers the folder of the path chosen" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const allocator = std.testing.allocator;
    app.setPickResult("[\"/downloads/photo.jpg\"]");
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("\"/downloads/photo.jpg\"", reply);
    try std.testing.expectEqual(@as(i32, 1), try app.lastPickKind(picks.allocator()));
    try std.testing.expectEqualStrings("photo.jpg", (try app.lastPick(picks.allocator())).?.initialName.?);
    try expectState(&app, "lastDownloadFolder", "\"/downloads\"");
}

test "pick-file replies null when the user cancelled" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try expectState(&app, "lastDownloadFolder", "null");
}

test "pick-file without a suggested name is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestError("pick-file", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "pick-files replies every path chosen, in a dialog that starts in the last folder" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("set-state", "{\"key\":\"lastFolder\",\"value\":\"/photos\"}"));
    app.setPickResult("[\"/photos/a.jpg\",\"/photos/b.jpg\"]");
    const reply = try app.requestOk("pick-files", "\"Choose photos\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("[\"/photos/a.jpg\",\"/photos/b.jpg\"]", reply);
    try std.testing.expectEqual(@as(i32, 0), try app.lastPickKind(picks.allocator()));
    try std.testing.expectEqualStrings("Choose photos", (try app.lastPick(picks.allocator())).?.title.?);
    try std.testing.expectEqualStrings("/photos", (try app.lastPick(picks.allocator())).?.initialName.?);
}

test "pick-files replies null when the user cancelled" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestOk("pick-files", "\"Choose photos\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
}

test "open-database tells the page to load the folder chosen and remembers the folder that holds it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const allocator = std.testing.allocator;
    app.setPickResult("[\"/databases/my-photos\"]");
    const reply = try app.requestOk("open-database", "null");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try std.testing.expectEqualStrings("Open Database", (try app.lastPick(picks.allocator())).?.title.?);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"app\",\"data\":{\"type\":\"database-opened\",\"data\":\"/databases/my-photos\"}}");
    try expectState(&app, "lastFolder", "\"/databases\"");
}

test "open-database sends no event when the user cancelled" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestOk("open-database", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "database-opened"));
}

test "pick-folder treats an empty title and an empty key as none" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/chosen/dir\"]");
    std.testing.allocator.free(try app.requestOk("pick-folder", "{\"title\":\"\",\"folderKey\":\"\"}"));
    try std.testing.expectEqualStrings("Select Folder", (try app.lastPick(picks.allocator())).?.title.?);
    try expectState(&app, "lastFolder", "\"/chosen/dir\"");
}

test "a failing dialog task logs the error with the message of its handler" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const allocator = std.testing.allocator;
    app.native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"pick-file-1\",\"taskType\":\"pick-file\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"pick-file-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error picking save location") != null);
    app.native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"pick-files-1\",\"taskType\":\"pick-files\",\"source\":\"test\",\"data\":null,\"priority\":\"interactive\"}}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"pick-files-1\",\"status\":\"failed\"");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error picking files") != null);
    allocator.free(try app.requestError("pick-folder", "{\"folderKey\":\"gallerySort\"}"));
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error picking folder") != null);
}

test "pick-file takes its answer from PHOTOSPHERE_TEST_PICK_FILE_PATH in test mode, with no dialog and nothing remembered" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_PICK_FILE_PATH", "/from/the/environment.jpg");
    try app.launch();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/from/the/environment.jpg\"", reply);
    try std.testing.expectEqual(@as(i32, -1), try app.lastPickKind(picks.allocator()));
    try expectState(&app, "lastDownloadFolder", "null");
}

test "pick-file ignores PHOTOSPHERE_TEST_PICK_FILE_PATH outside test mode" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "0");
    try app.environ_map.put("PHOTOSPHERE_TEST_PICK_FILE_PATH", "/from/the/environment.jpg");
    try app.launch();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/downloads/photo.jpg\"]");
    const reply = try app.requestOk("pick-file", "\"photo.jpg\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/downloads/photo.jpg\"", reply);
    try std.testing.expectEqual(@as(i32, 1), try app.lastPickKind(picks.allocator()));
}

test "pick-folder for the download folder takes its answer from PHOTOSPHERE_TEST_DOWNLOAD_FOLDER in test mode, with no dialog and nothing remembered" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
    try app.environ_map.put("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER", "/from/the/download-folder");
    try app.launch();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    const reply = try app.requestOk("pick-folder", "{\"folderKey\":\"lastDownloadFolder\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/from/the/download-folder\"", reply);
    try std.testing.expectEqual(@as(i32, -1), try app.lastPickKind(picks.allocator()));
    try expectState(&app, "lastDownloadFolder", "null");
}

test "pick-folder for any other folder ignores PHOTOSPHERE_TEST_DOWNLOAD_FOLDER, and so does a run outside test mode" {
    const allocator = std.testing.allocator;
    {
        var app: TestApp = undefined;
        try app.prepare();
        try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
        try app.environ_map.put("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER", "/from/the/download-folder");
        try app.launch();
        defer app.stop();
        var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer picks.deinit();
        app.setPickResult("[\"/chosen/dir\"]");
        const other = try app.requestOk("pick-folder", "null");
        defer allocator.free(other);
        try std.testing.expectEqualStrings("\"/chosen/dir\"", other);
        try std.testing.expectEqual(@as(i32, 2), try app.lastPickKind(picks.allocator()));
    }
    // An app run outside test mode.
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("PHOTOSPHERE_TEST_MODE", "0");
    try app.environ_map.put("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER", "/from/the/download-folder");
    try app.launch();
    defer app.stop();
    var picks = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picks.deinit();
    app.setPickResult("[\"/chosen/downloads\"]");
    const download = try app.requestOk("pick-folder", "{\"folderKey\":\"lastDownloadFolder\"}");
    defer allocator.free(download);
    try std.testing.expectEqualStrings("\"/chosen/downloads\"", download);
}

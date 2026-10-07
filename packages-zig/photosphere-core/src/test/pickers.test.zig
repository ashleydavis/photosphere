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
    try std.testing.expectEqualStrings("The save dialog needs a suggested file name.", reply);
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
    try app.shell.expectMessageContaining("{\"channel\":\"database-opened\",\"data\":\"/databases/my-photos\"}");
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

test "pick-folder treats an empty title and an empty key as none, as the TypeScript's || does" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    app.pick_answer = "[\"/chosen/dir\"]";
    std.testing.allocator.free(try app.requestOk("pick-folder", "{\"title\":\"\",\"folderKey\":\"\"}"));
    try std.testing.expectEqualStrings("Select Folder", app.last_pick_title.?);
    try expectState(&app, "lastFolder", "\"/chosen/dir\"");
}

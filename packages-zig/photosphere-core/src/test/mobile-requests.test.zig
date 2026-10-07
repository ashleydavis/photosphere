const std = @import("std");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

fn expectForwarded(app: *TestApp, channel: []const u8, request_json: []const u8, answer_json: []const u8, expected_method: []const u8, expected_request: []const u8) !void {
    app.host_answer = answer_json;
    const reply = try app.requestOk(channel, request_json);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings(answer_json, reply);
    try std.testing.expectEqualStrings(expected_method, app.last_host_method.?);
    try std.testing.expectEqualStrings(expected_request, app.last_host_request.?);
}

test "requestMediaPermission asks the phone and passes its answer on" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectForwarded(&app, "requestMediaPermission", "null", "{\"granted\":false,\"partial\":true}", "requestMediaPermission", "null");
}

test "exportFile passes the path to the phone and its answer on, and leaves out the test outcome" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectForwarded(&app, "exportFile", "{\"path\":\"tmp/photo.jpg\",\"testOutcome\":\"shared\"}", "{\"path\":\"tmp/photo.jpg\"}", "exportFile", "{\"path\":\"tmp/photo.jpg\"}");
}

test "exportFile passes on a cancelled sheet" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectForwarded(&app, "exportFile", "{\"path\":\"tmp/photo.jpg\"}", "{\"path\":null}", "exportFile", "{\"path\":\"tmp/photo.jpg\"}");
}

test "exportFiles passes the paths to the phone and its answer on" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectForwarded(&app, "exportFiles", "{\"paths\":[\"a.jpg\",\"b.jpg\"],\"testOutcome\":\"cancelled\"}", "{\"paths\":[\"a.jpg\",\"b.jpg\"]}", "exportFiles", "{\"paths\":[\"a.jpg\",\"b.jpg\"]}");
}

test "startBackgroundImport and stopBackgroundImport ask the phone and reply null" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectForwarded(&app, "startBackgroundImport", "null", "null", "startBackgroundImport", "null");
    try expectForwarded(&app, "stopBackgroundImport", "null", "null", "stopBackgroundImport", "null");
}

test "the secure store requests ask the phone's keychain and pass its answers on" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try expectForwarded(&app, "secureStoreGet", "{\"key\":\"secret:one\"}", "{\"value\":\"s3cret\"}", "secureStoreGet", "{\"key\":\"secret:one\"}");
    try expectForwarded(&app, "secureStoreSet", "{\"key\":\"secret:one\",\"value\":\"s3cret\"}", "null", "secureStoreSet", "{\"key\":\"secret:one\",\"value\":\"s3cret\"}");
    try expectForwarded(&app, "secureStoreDelete", "{\"key\":\"secret:one\"}", "null", "secureStoreDelete", "{\"key\":\"secret:one\"}");
    try expectForwarded(&app, "secureStoreKeys", "null", "{\"keys\":[\"secret:one\",\"secret:two\"]}", "secureStoreKeys", "null");
}

test "a request the phone could not do is an error reply with the reason it gave" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    app.host_answer = "The photo library cannot be reached.";
    app.host_fails = true;
    const reply = try app.requestError("requestMediaPermission", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The photo library cannot be reached.", reply);
}

test "an answer from the phone that is not JSON is an error reply that says so" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    app.host_answer = "not json at all";
    const reply = try app.requestError("exportFile", "{\"path\":\"a.jpg\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The phone's answer to exportFile could not be read.", reply);
}

test "on a platform with no host request callback every request says it is only available on a phone" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    support.removeHostRequest(&app);
    const reply = try app.requestError("secureStoreGet", "{\"key\":\"k\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("secureStoreGet is only available in the Photosphere app on a phone.", reply);
    const export_reply = try app.requestError("exportFile", "{\"path\":\"a.jpg\"}");
    defer std.testing.allocator.free(export_reply);
    try std.testing.expectEqualStrings("exportFile is only available in the Photosphere app on a phone.", export_reply);
}

test "requests with a field missing are error replies that name the field" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const export_reply = try app.requestError("exportFile", "{}");
    defer std.testing.allocator.free(export_reply);
    try std.testing.expectEqualStrings("exportFile needs \"path\".", export_reply);
    const paths_reply = try app.requestError("exportFiles", "{\"paths\":[1]}");
    defer std.testing.allocator.free(paths_reply);
    try std.testing.expectEqualStrings("exportFiles needs \"paths\" to be a list of paths.", paths_reply);
    const missing_paths = try app.requestError("exportFiles", "{}");
    defer std.testing.allocator.free(missing_paths);
    try std.testing.expectEqualStrings("exportFiles needs \"paths\".", missing_paths);
    const key_reply = try app.requestError("secureStoreGet", "{}");
    defer std.testing.allocator.free(key_reply);
    try std.testing.expectEqualStrings("secureStoreGet needs \"key\".", key_reply);
    const value_reply = try app.requestError("secureStoreSet", "{\"key\":\"k\"}");
    defer std.testing.allocator.free(value_reply);
    try std.testing.expectEqualStrings("secureStoreSet needs \"value\".", value_reply);
    const delete_reply = try app.requestError("secureStoreDelete", "{}");
    defer std.testing.allocator.free(delete_reply);
    try std.testing.expectEqualStrings("secureStoreDelete needs \"key\".", delete_reply);
    try std.testing.expect(app.last_host_method == null);
}

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const helpers = @import("helpers.zig");

fn lastMessage(shell: *helpers.FakeShell) ![]u8 {
    return try shell.messageAt(std.testing.allocator, shell.count() - 1);
}

test "a known channel is routed and replied to with the request's id" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":7,\"channel\":\"echo\",\"data\":{\"a\":1}}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":7,\"ok\":true,\"data\":{\"a\":1}}", reply);
}

test "a string id is echoed as a string" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":\"abc\",\"channel\":\"echo\",\"data\":null}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"ok\":true,\"data\":null}", reply);
}

test "an unknown channel gets an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"nope\",\"data\":null}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":false,\"error\":\"UnknownChannel\"}", reply);
}

test "malformed JSON is reported as a core-error event and the core keeps working" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{not json");
    core.postMessage("[1,2,3]");
    try std.testing.expectEqual(@as(usize, 2), shell.countContaining("\"channel\":\"core-error\""));
    try std.testing.expectEqual(@as(usize, 2), shell.countContaining("InvalidMessage"));
    core.postMessage("{\"id\":2,\"channel\":\"echo\",\"data\":1}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":2,\"ok\":true,\"data\":1}", reply);
}

test "a message without a channel gets an error reply when it has an id and a core-error event when not" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":3,\"data\":1}");
    try shell.expectMessageContaining("{\"id\":3,\"ok\":false,\"error\":\"MissingChannel\"}");
    core.postMessage("{\"data\":1}");
    try shell.expectMessageContaining("\"channel\":\"core-error\"");
}

test "a message without an id gets no reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"channel\":\"echo\",\"data\":1}");
    try std.testing.expectEqual(@as(usize, 0), shell.count());
}

test "a handler that fails becomes an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":4,\"channel\":\"fail\",\"data\":null}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":\"ChannelFailed\"}", reply);
}

test "get-platform reports the platform kind" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":5,\"channel\":\"get-platform\",\"data\":null}");
    // Android and iOS are the mobile platforms, and every other platform is desktop. The test runs on both, so it names the
    // kind each is expected to report.
    const expected = if (builtin.os.tag == .ios or builtin.abi.isAndroid())
        "\"platformKind\":\"mobile\""
    else
        "\"platformKind\":\"desktop\"";
    try shell.expectMessageContaining(expected);
}

test "text with quotes, newlines and non-ASCII characters round trips unchanged" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":6,\"channel\":\"echo\",\"data\":{\"text\":\"say \\\"hi\\\"\\nline two \\u00e9 \\u4e16\\u754c \\ud83d\\ude00\"}}");
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const text = parsed.value.object.get("data").?.object.get("text").?.string;
    try std.testing.expectEqualStrings("say \"hi\"\nline two é 世界 😀", text);
}

test "a multi-megabyte payload round trips unchanged" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    const payload = try std.testing.allocator.alloc(u8, 6 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| {
        byte.* = 'a' + @as(u8, @intCast(index % 26));
    }
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":8,\"channel\":\"echo\",\"data\":{{\"blob\":\"{s}\"}}}}", .{payload});
    defer std.testing.allocator.free(message);
    core.postMessage(message);
    const reply = try lastMessage(&shell);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const blob = parsed.value.object.get("data").?.object.get("blob").?.string;
    try std.testing.expectEqualSlices(u8, payload, blob);
}

test "create then destroy releases everything" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 2);
    core.destroy();
}

test "create without a deliver callback fails" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    config.deliver = null;
    try std.testing.expectError(error.DeliverCallbackMissing, ziggy.core.Core.create(std.testing.allocator, config, helpers.app));
}

test "check url uses the configured prefix" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectEqual(ziggy.types.UrlDecision.allow, core.checkUrl("file:///app/dist/index.html"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, core.checkUrl("file:///other/index.html"));
}

test "a menu-action message from a shell reaches the page as a menu-action event" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    try shell.expectMessageContaining("{\"channel\":\"menu-action\",\"data\":{\"action\":\"about\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":{}}");
}

test "a menu-action message with no action is an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"menu-action\",\"data\":{}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"MissingAction\"}");
}

test "the core holds the app's menu for shells to read" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectEqualStrings("[]", core.menu_json);
}

test "the core finds a file of the app's bundled page by the path of a request" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expectEqualStrings("<html></html>", core.uiFile("/index.html").?.content);
    try std.testing.expectEqualStrings("index.html", core.uiFile("/").?.path);
    try std.testing.expect(core.uiFile("/missing.js") == null);
}

test "a task channel answers the request with the task's result, without blocking the dispatcher" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"id\":11,\"channel\":\"quick-request\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":11,\"ok\":true,\"data\":\"done\"}");
    // The reply is the only thing sent: a request's task sends no task-completed event of its own.
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("task-completed"));
}

test "a task channel whose task fails gives an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"id\":12,\"channel\":\"fail-request\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":12,\"ok\":false,\"error\":\"TestFailure\"}");
}

test "a task channel request with no id is reported and runs nothing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"channel\":\"quick-request\",\"data\":null}");
    try shell.expectMessageContaining("RequestHasNoId");
}

test "a native dialog is shown through the shell's callback with the title and kind" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    core.postMessage("{\"id\":13,\"channel\":\"pick-open-request\",\"data\":\"Choose files\"}");
    try shell.expectMessageContaining("{\"id\":13,\"ok\":true,\"data\":[\"kind0\",\"Choose files\",\"-\"]}");
    core.postMessage("{\"id\":14,\"channel\":\"pick-save-request\",\"data\":\"photo.jpg\"}");
    try shell.expectMessageContaining("{\"id\":14,\"ok\":true,\"data\":[\"kind1\",\"-\",\"photo.jpg\"]}");
}

test "a dialog with no callback from the shell is an error reply naming what is missing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(2, 1);
    config.pick_paths = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, helpers.app);
    defer core.destroy();
    core.postMessage("{\"id\":15,\"channel\":\"pick-open-request\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":15,\"ok\":false,\"error\":\"HostCallbackMissing\"}");
}

test "get-dropped-paths replies with the paths of the last drop, and an empty array before any drop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped one.txt",
        .data = "abcd",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped one.txt" });
    defer std.testing.allocator.free(path);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"get-dropped-paths\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":[]}");
    const paths_json = try std.json.Stringify.valueAlloc(std.testing.allocator, &[_][]const u8{path}, .{});
    defer std.testing.allocator.free(paths_json);
    try core.filesDropped(paths_json);
    core.postMessage("{\"id\":2,\"channel\":\"get-dropped-paths\",\"data\":null}");
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":2,\"ok\":true,\"data\":{s}}}", .{paths_json});
    defer std.testing.allocator.free(expected);
    try shell.expectMessageContaining(expected);
}

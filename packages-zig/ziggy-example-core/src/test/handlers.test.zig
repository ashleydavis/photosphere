const std = @import("std");
const ziggy = @import("ziggy-core");
const example = @import("ziggy-example-core");

const FakeShell = ziggy.fake_shell.FakeShell;

fn createCore(shell: *FakeShell, data_dir: [*:0]const u8) !*ziggy.core.Core {
    var config = shell.config(3, 4);
    config.data_dir = data_dir;
    return try ziggy.core.Core.create(std.testing.allocator, config, example.app);
}

fn addTask(core: *ziggy.core.Core, id: []const u8, task_type: []const u8, data: []const u8) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"channel\":\"add-task\",\"data\":{{\"taskId\":\"{s}\",\"taskType\":\"{s}\",\"source\":\"src\",\"data\":{s},\"priority\":0}}}}", .{ id, task_type, data });
    defer std.testing.allocator.free(message);
    core.postMessage(message);
}

fn indexOfMessage(shell: *FakeShell, text: []const u8) !usize {
    try shell.expectMessageContaining(text);
    return shell.indexOfContaining(text).?;
}

test "ping replies with the Zig version, the platform and an echo of the payload" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"ping\",\"data\":{\"hello\":\"world\"}}");
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?;
    try std.testing.expectEqualStrings(@import("builtin").zig_version_string, data.object.get("zigVersion").?.string);
    try std.testing.expectEqualStrings(@tagName(@import("builtin").os.tag), data.object.get("os").?.string);
    try std.testing.expectEqualStrings(@tagName(@import("builtin").cpu.arch), data.object.get("arch").?.string);
    try std.testing.expectEqualStrings("world", data.object.get("echo").?.object.get("hello").?.string);
}

test "payload-stats reports the length and checksum of a multi-megabyte payload" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    const payload = try std.testing.allocator.alloc(u8, 5 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":1,\"channel\":\"payload-stats\",\"data\":{{\"text\":\"{s}\"}}}}", .{payload});
    defer std.testing.allocator.free(message);
    core.postMessage(message);
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\"length\":{d},\"crc32\":{d}", .{ payload.len, std.hash.Crc32.hash(payload) });
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, reply, expected) != null);
}

test "payload-stats counts the bytes of text with non-ASCII characters" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"payload-stats\",\"data\":{\"text\":\"é世界😀\"}}");
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"length\":12,") != null);
}

test "payload-stats without text is an error reply" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"payload-stats\",\"data\":{}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"MissingText\"}");
}

test "file-roundtrip writes a file in the data directory and reads it back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, data_dir.ptr);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"file-roundtrip\",\"data\":{\"text\":\"kept \\u00e9\"}}");
    const reply = try shell.messageAt(std.testing.allocator, 0);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"text\":\"kept é\"") != null);
    var buffer: [64]u8 = undefined;
    const written = try tmp.dir.readFile(core.io(), "ziggy-example-roundtrip.txt", &buffer);
    try std.testing.expectEqualStrings("kept é", written);
}

test "file-roundtrip reports a missing data directory as an error" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/this/directory/does/not/exist");
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"file-roundtrip\",\"data\":{\"text\":\"x\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"FileNotFound\"}");
}

test "the fail channel replies with an error" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"fail\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"ExampleFailure\"}");
}

test "hello-short sends an output message and a job-progress message then completes" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-short", "{\"job\":{\"id\":\"job-1\",\"name\":\"Short job\",\"cancelSource\":\"src\"}}");
    const output = try indexOfMessage(&shell, "\"message\":{\"type\":\"output\",\"text\":\"hello from a short task\"}");
    const progress = try indexOfMessage(&shell, "\"message\":{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\",\"name\":\"Short job\",\"cancelSource\":\"src\"},\"startedAt\":");
    const completed = try indexOfMessage(&shell, "\"status\":\"succeeded\",\"result\":\"short task done\"");
    try std.testing.expect(output < progress);
    try std.testing.expect(progress < completed);
    try shell.expectMessageContaining("\"progressMessage\":\"short task working\"}");
}

test "a job-progress message leaves out the cancel source when the job has none" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-short", "{\"job\":{\"id\":\"job-1\",\"name\":\"Short job\"}}");
    try shell.expectMessageContaining("\"job\":{\"id\":\"job-1\",\"name\":\"Short job\"},\"startedAt\"");
}

test "a task with no job sends no job-progress message" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-short", "{}");
    try shell.expectMessageContaining("\"status\":\"succeeded\"");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("job-progress"));
}

test "hello-long sends output and progress at every step, starts its children and waits for them" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "long", "hello-long", "{\"durationMs\":200,\"stepMs\":50,\"children\":3,\"job\":{\"id\":\"job-1\",\"name\":\"Long job\",\"cancelSource\":\"src\"}}");
    try shell.expectMessageContaining("\"taskId\":\"long\",\"source\":\"src\",\"status\":\"succeeded\",\"result\":{\"steps\":4,\"children\":3}");
    try std.testing.expectEqual(@as(usize, 4), shell.countContaining("\"taskId\":\"long\",\"source\":\"src\",\"message\":{\"type\":\"output\",\"text\":\"long task step"));
    try std.testing.expectEqual(@as(usize, 3), shell.countContaining("child long.c"));
    try std.testing.expectEqual(@as(usize, 3), shell.countContaining("\"status\":\"succeeded\",\"result\":{\"index\":"));
    // The children report under the parent's job id.
    try std.testing.expect(shell.countContaining("\"taskId\":\"long.c0\",\"source\":\"src\",\"message\":{\"type\":\"job-progress\",\"job\":{\"id\":\"job-1\"") == 1);
    // The parent's completion is the last thing that happens.
    try std.testing.expect(shell.indexOfContaining("\"taskId\":\"long\",\"source\":\"src\",\"status\"").? > shell.indexOfContaining("\"taskId\":\"long.c2\",\"source\":\"src\",\"status\"").?);
}

test "hello-long with no children and more children than steps both complete" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "a", "hello-long", "{\"durationMs\":50,\"stepMs\":50,\"children\":0}");
    try shell.expectMessageContaining("\"taskId\":\"a\",\"source\":\"src\",\"status\":\"succeeded\",\"result\":{\"steps\":1,\"children\":0}");
    try addTask(core, "b", "hello-long", "{\"durationMs\":50,\"stepMs\":50,\"children\":5}");
    try shell.expectMessageContaining("\"taskId\":\"b\",\"source\":\"src\",\"status\":\"succeeded\",\"result\":{\"steps\":1,\"children\":5}");
}

test "cancelling hello-long stops it early and its children are cancelled" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "long", "hello-long", "{\"durationMs\":60000,\"stepMs\":20,\"children\":2}");
    try shell.expectMessageContaining("long task step 3");
    core.postMessage("{\"channel\":\"cancel-tasks\",\"data\":{\"source\":\"src\"}}");
    try shell.expectMessageContaining("\"taskId\":\"long\",\"source\":\"src\",\"status\":\"cancelled\"");
    try std.testing.expect(shell.countContaining("\"taskId\":\"long\",\"source\":\"src\",\"message\":{\"type\":\"output\",\"text\":\"long task step") < 100);
}

test "hello-fail completes as failed" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "hello-fail", "null");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":\"HelloFailure\"");
}

test "os-version returns what the shell's native host callback answers" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell, "/tmp");
    defer core.destroy();
    try addTask(core, "t1", "os-version", "null");
    try shell.expectMessageContaining("\"status\":\"succeeded\",\"result\":\"Test OS 1.0\"");
}

test "os-version fails clearly when the shell provides no native host callback" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    config.os_version = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, example.app);
    defer core.destroy();
    try addTask(core, "t1", "os-version", "null");
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":\"HostCallbackMissing\"");
}

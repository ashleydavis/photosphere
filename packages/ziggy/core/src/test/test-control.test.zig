const std = @import("std");
const ziggy = @import("ziggy-core");
const helpers = @import("helpers.zig");

//
// One client conversation with the control connection, run on its own thread because the answer waits for the page.
//
const Client = struct {
    // Where the answer goes.
    allocator: std.mem.Allocator,
    // The port to connect to.
    port: u16,
    // The line to send, without the newline.
    line: []const u8,
    // The line the connection answered with.
    answer: ?[]u8,
    // Whether the connection was closed without an answer.
    closed_without_answer: bool,

    fn run(self: *Client) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch @panic("bad address");
        const stream = address.connect(io, .{ .mode = .stream }) catch @panic("could not connect to the control connection");
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(self.line) catch @panic("write failed");
        writer.interface.writeAll("\n") catch @panic("write failed");
        writer.interface.flush() catch @panic("write failed");
        const answer = reader.interface.takeDelimiter('\n') catch {
            self.closed_without_answer = true;
            return;
        } orelse {
            self.closed_without_answer = true;
            return;
        };
        self.answer = self.allocator.dupe(u8, answer) catch @panic("out of memory");
    }
};

fn startControlledCore(shell: *helpers.FakeShell, tmp: *std.testing.TmpDir) !*ziggy.core.Core {
    var config = shell.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    return try ziggy.core.Core.create(std.testing.allocator, config, helpers.app);
}

test "a command reaches the page and its answer comes back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"click\",\"dataId\":\"go\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    try shell.expectMessageContaining("\"channel\":\"test-command\",\"data\":{\"requestId\":1,\"command\":{\"command\":\"click\",\"dataId\":\"go\"}}");
    core.postMessage("{\"id\":9,\"channel\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"clicked\":true}}}");
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"clicked\":true}", client.answer.?);
}

test "the port is written to the port file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var buffer: [32]u8 = undefined;
    const text = try tmp.dir.readFile(core.control.?.io, "port.txt", &buffer);
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, text, "\n"), 10);
    try std.testing.expectEqual(core.control.?.port, port);
}

test "a line that is not JSON is answered with an error and never reaches the page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "this is not json",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.answer.?);
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("test-command"));
}

test "a JSON object with no command field is answered with an error and never reaches the page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"dataId\":\"x\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.answer.?);
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("test-command"));
}

test "the quit command calls the shell's quit callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"quit\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.answer.?);
    try std.testing.expect(shell.quit_called.load(.acquire));
}

test "a core not in test mode has no control connection" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try std.testing.expect(core.control == null);
}

test "a test-result nobody is waiting for is an error reply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"test-result\",\"data\":{\"requestId\":99,\"result\":1}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"UnexpectedTestResult\"}");
}

test "a second connection is served while the first stays open, and stopping ends both" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", core.control.?.port);
    // The first connection is opened and left open, and sends nothing.
    const first = try address.connect(io, .{ .mode = .stream });
    defer first.close(io);
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "this is not json",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.answer.?);
    // Destroying the core must not wait for the first connection to close.
    core.destroy();
}

test "a command waits until the page says it is listening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"ready\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    // The page has not said it is listening, so the command is not sent to it.
    shell.sleepMs(300);
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("test-command"));
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    try shell.expectMessageContaining("\"channel\":\"test-command\"");
    core.postMessage("{\"channel\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"ok\":true}}}");
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.answer.?);
}

test "a test's answer for the next dialog is used once and then the shell's dialog is shown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"pick-answer\",\"paths\":[\"/answer/one.txt\",\"/answer/two.txt\"]}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.answer.?);
    core.postMessage("{\"id\":21,\"channel\":\"pick-open-request\",\"data\":\"Title\"}");
    try shell.expectMessageContaining("{\"id\":21,\"ok\":true,\"data\":[\"/answer/one.txt\",\"/answer/two.txt\"]}");
    core.postMessage("{\"id\":22,\"channel\":\"pick-open-request\",\"data\":\"Title\"}");
    try shell.expectMessageContaining("{\"id\":22,\"ok\":true,\"data\":[\"kind0\",\"Title\",\"-\"]}");
}

test "an answer for a dialog that is not an array of strings is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"pick-answer\",\"paths\":[1,2]}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.answer.?);
}

test "the menu command chooses the menu item through the shell's callback once the page is listening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"menu\",\"action\":\"zoom-in\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    // The page is not listening yet, so nothing is chosen.
    shell.sleepMs(300);
    try std.testing.expectEqual(@as(usize, 0), shell.chosen_actions.items.len);
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.answer.?);
    try std.testing.expectEqualStrings("zoom-in\n", shell.chosen_actions.items);
}

test "choosing reload makes commands wait for the page to say it is listening again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    var reload = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"menu\",\"action\":\"reload\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const reload_thread = try std.Thread.spawn(.{}, Client.run, .{&reload});
    reload_thread.join();
    defer if (reload.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", reload.answer.?);
    var next = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"ready\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const next_thread = try std.Thread.spawn(.{}, Client.run, .{&next});
    // The page is reloading, so the next command is held back and not sent to it.
    shell.sleepMs(300);
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("test-command"));
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    try shell.expectMessageContaining("\"channel\":\"test-command\"");
    core.postMessage("{\"channel\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"ok\":true}}}");
    next_thread.join();
    defer if (next.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", next.answer.?);
}

test "the menu command on a shell with no menu callback says what is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    config.menu_action = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, helpers.app);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"menu\",\"action\":\"zoom-in\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"HostCallbackMissing\"}", client.answer.?);
}

test "the drop command records a drop the way the shell does, so the page can ask for the paths of a drop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped.txt",
        .data = "xyz",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped.txt" });
    defer std.testing.allocator.free(path);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    // The path is written as a JSON string, so a Windows path's backslashes are escaped.
    const line = try ziggy.json_util.stringify(std.testing.allocator, .{
        .command = "drop",
        .paths = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(line);
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = line,
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.answer.?);
    core.postMessage("{\"id\":31,\"channel\":\"get-dropped-paths\",\"data\":null}");
    const expected = try ziggy.json_util.stringify(std.testing.allocator, .{
        .id = 31,
        .ok = true,
        .data = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(expected);
    try shell.expectMessageContaining(expected);
}

test "a drop that names an element is also sent to the page, and the page's answer is the answer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dropped.txt",
        .data = "xyz",
    });
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "dropped.txt" });
    defer std.testing.allocator.free(path);
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    const line = try ziggy.json_util.stringify(std.testing.allocator, .{
        .command = "drop",
        .dataId = "zone",
        .paths = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(line);
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = line,
        .answer = null,
        .closed_without_answer = false,
    };
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    try shell.expectMessageContaining("\"channel\":\"test-command\",\"data\":{\"requestId\":1,\"command\":{\"command\":\"drop\",\"dataId\":\"zone\"");
    core.postMessage("{\"id\":9,\"channel\":\"test-result\",\"data\":{\"requestId\":1,\"result\":{\"dropped\":true}}}");
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"dropped\":true}", client.answer.?);
    core.postMessage("{\"id\":32,\"channel\":\"get-dropped-paths\",\"data\":null}");
    const expected = try ziggy.json_util.stringify(std.testing.allocator, .{
        .id = 32,
        .ok = true,
        .data = &[_][]const u8{path},
    });
    defer std.testing.allocator.free(expected);
    try shell.expectMessageContaining(expected);
}

test "the screenshot command asks the shell to write a picture of the window to the path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"screenshot\",\"outputPath\":\"/shots/home.png\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", client.answer.?);
    try std.testing.expectEqualStrings("/shots/home.png\n", shell.screenshot_paths.items);
}

test "the screenshot command answers with the reason when the shell cannot capture the window" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    core.postMessage("{\"channel\":\"test-page-ready\",\"data\":null}");
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"screenshot\",\"outputPath\":\"/shots/refused.png\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"The window cannot be captured.\"}", client.answer.?);
}

test "the screenshot command without an output path is an invalid command and captures nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"screenshot\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", client.answer.?);
    try std.testing.expectEqual(@as(usize, 0), shell.screenshot_paths.items.len);
}

test "the screenshot command on a shell with no screenshot callback says what is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    config.screenshot = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, helpers.app);
    defer core.destroy();
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = "{\"command\":\"screenshot\",\"outputPath\":\"/shots/home.png\"}",
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    defer if (client.answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"error\":\"HostCallbackMissing\"}", client.answer.?);
}

//
// Sends one line to the control connection of a core and returns its answer, allocated with the testing allocator.
//
fn answerFor(core: *ziggy.core.Core, line: []const u8) ![]u8 {
    var client = Client{
        .allocator = std.testing.allocator,
        .port = core.control.?.port,
        .line = line,
        .answer = null,
        .closed_without_answer = false,
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    thread.join();
    return client.answer orelse error.ClosedWithoutAnswer;
}

test "the quit command on a shell with no quit callback says what is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    var port_file_buffer: [256]u8 = undefined;
    const port_file = try std.fmt.bufPrintZ(&port_file_buffer, ".zig-cache/tmp/{s}/port.txt", .{tmp.sub_path});
    config.test_mode = true;
    config.test_port_file = port_file.ptr;
    config.quit = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, helpers.app);
    defer core.destroy();
    const answer = try answerFor(core, "{\"command\":\"quit\"}");
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqualStrings("{\"error\":\"HostCallbackMissing\"}", answer);
}

test "the menu command without an action is an invalid command and chooses nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    const answer = try answerFor(core, "{\"command\":\"menu\"}");
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", answer);
    try std.testing.expectEqual(@as(usize, 0), shell.chosen_actions.items.len);
}

test "the drop command without paths is an invalid command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    const answer = try answerFor(core, "{\"command\":\"drop\"}");
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", answer);
}

test "an answer for a dialog with no paths, or with paths that are not an array, is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    const missing = try answerFor(core, "{\"command\":\"pick-answer\"}");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", missing);
    const not_array = try answerFor(core, "{\"command\":\"pick-answer\",\"paths\":\"/one.txt\"}");
    defer std.testing.allocator.free(not_array);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidCommand\"}", not_array);
}

test "a second answer for the next dialog replaces the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    const first = try answerFor(core, "{\"command\":\"pick-answer\",\"paths\":[\"/first.txt\"]}");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"ok\":true}", first);
    const second = try answerFor(core, "{\"command\":\"pick-answer\",\"paths\":[\"/second.txt\"]}");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"ok\":true}", second);
    core.postMessage("{\"id\":31,\"channel\":\"pick-open-request\",\"data\":\"Title\"}");
    try shell.expectMessageContaining("{\"id\":31,\"ok\":true,\"data\":[\"/second.txt\"]}");
}

test "a test-result without a request id is an error reply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try startControlledCore(&shell, &tmp);
    defer core.destroy();
    core.postMessage("{\"id\":5,\"channel\":\"test-result\",\"data\":{\"result\":null}}");
    try shell.expectMessageContaining("{\"id\":5,\"ok\":false,\"error\":\"MissingRequestId\"}");
}

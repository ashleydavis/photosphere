//
// Tests for mcp-server.zig and mcp-bridge.zig: the MCP server task, the tools it offers, and the calls it forwards to the page.
//
// Each test runs the real core on a fake native app with the MCP server task running on a free loopback port (the test sets test mode
// in the environment the core reads, which is what makes the server not claim its fixed port), and plays the part of the page: it reads
// the `mcp-tool-request` events the fake native app records and answers them with `mcp-tool-response` messages.
//

const std = @import("std");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const mcp_server = @import("photosphere-core").mcp_server;
const expectServerStopped = @import("../../../utils-zig/src/test/expect-server-stopped.zig").expectServerStopped;

const TestApp = support.TestApp;
const io = std.testing.io;

//
// The Accept header of an MCP client.
//
const MCP_ACCEPT = "application/json, text/event-stream";

//
// A POST to the server that runs on its own thread, because the server does not answer until the page has, and the test is the page.
//
const Call = struct {
    // The port to post to.
    port: u16,

    // The JSON-RPC message to post.
    payload: []const u8,

    // The body of the answer, or null until there is one. Allocated with the testing allocator.
    answer: ?[]u8,

    // Whether the post failed.
    failed: bool,

    // The thread that makes the post.
    thread: std.Thread,

    //
    // Starts the post in place.
    //
    fn start(self: *Call, port: u16, payload: []const u8) !void {
        self.* = .{
            .port = port,
            .payload = payload,
            .answer = null,
            .failed = false,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    //
    // Waits for the post to end and returns the body of the answer. The caller frees it.
    //
    fn finish(self: *Call) ![]u8 {
        self.thread.join();
        if (self.failed) {
            return error.CallFailed;
        }
        return self.answer.?;
    }

    //
    // The thread: posts the message and keeps the body of the answer.
    //
    fn run(self: *Call) void {
        self.post() catch |err| {
            std.debug.print("The call to the MCP server failed: {s}\n", .{@errorName(err)});
            self.failed = true;
        };
    }

    //
    // Posts the message the way an MCP client does.
    //
    fn post(self: *Call) !void {
        const allocator = std.testing.allocator;
        var client: std.http.Client = .{
            .allocator = allocator,
            .io = io,
        };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{self.port});
        defer allocator.free(url);
        const result = try client.fetch(.{
            .location = .{
                .url = url,
            },
            .method = .POST,
            .payload = self.payload,
            .headers = .{
                .content_type = .{
                    .override = "application/json",
                },
            },
            .extra_headers = &.{
                .{
                    .name = "Accept",
                    .value = MCP_ACCEPT,
                },
            },
            .response_writer = &body.writer,
            .keep_alive = false,
        });
        if (result.status != .ok) {
            std.debug.print("The MCP server answered {d}\n", .{@intFromEnum(result.status)});
            return error.UnexpectedStatus;
        }
        self.answer = try allocator.dupe(u8, body.written());
    }
};

//
// Starts the MCP server on a free port and returns the port it bound.
//
fn startServer(app: *TestApp) !u16 {
    try main_state.fromCore(app.core).startMcpServer();
    const port = main_state.fromCore(app.core).mcp_bridge.port.load(.acquire);
    if (port == 0) {
        return error.ServerDidNotStart;
    }
    return port;
}

//
// Waits for the page to be sent a tool call and returns its request id. The caller frees it.
//
fn waitForRequest(app: *TestApp, tool: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const marker = try std.fmt.allocPrint(allocator, "\"type\":\"mcp-tool-request\",\"data\":{{\"requestId\":\"", .{});
    defer allocator.free(marker);
    try app.shell.expectMessageContaining(marker);
    const text = try app.shell.messageAt(allocator, app.shell.indexOfContaining(marker).?);
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(struct {
        data: struct {
            data: struct {
                requestId: []const u8,
                tool: []const u8,
            },
        },
    }, allocator, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(tool, parsed.value.data.data.tool);
    return try allocator.dupe(u8, parsed.value.data.data.requestId);
}

//
// Answers a tool call the way the page does: a `mcp-tool-response` message holding the request id and the payload.
//
fn answerRequest(app: *TestApp, request_id: []const u8, payload_json: []const u8) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"kind\":\"app\",\"name\":\"mcp-tool-response\",\"data\":{{\"requestId\":\"{s}\",{s}}}}}", .{ request_id, payload_json });
    defer std.testing.allocator.free(message);
    app.core.postMessage(message);
}

test "a tool call is forwarded to the page and the page's answer is the result" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    var call: Call = undefined;
    try call.start(port, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"list_databases\",\"arguments\":{}}}");
    const request_id = try waitForRequest(&app, "list_databases");
    defer std.testing.allocator.free(request_id);
    try answerRequest(&app, request_id, "\"result\":\"the-databases\"");
    const answer = try call.finish();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"the-databases\"}]},\"jsonrpc\":\"2.0\",\"id\":7}\n\n", answer);
}

test "the arguments the tool was called with, with the defaults filled in, are sent to the page" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    var call: Call = undefined;
    try call.start(port, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_media_files\",\"arguments\":{\"pageId\":\"page-2\"}}}");
    const request_id = try waitForRequest(&app, "list_media_files");
    defer std.testing.allocator.free(request_id);
    const text = try app.shell.messageAt(std.testing.allocator, app.shell.indexOfContaining("\"type\":\"mcp-tool-request\"").?);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"tool\":\"list_media_files\",\"args\":{\"limit\":20,\"pageId\":\"page-2\"}") != null);
    try answerRequest(&app, request_id, "\"result\":\"ok\"");
    const answer = try call.finish();
    std.testing.allocator.free(answer);
}

test "a failure of the page is the failure of the tool, with the page's reason as its text" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    var call: Call = undefined;
    try call.start(port, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"open_database\",\"arguments\":{\"path\":\"/missing\"}}}");
    const request_id = try waitForRequest(&app, "open_database");
    defer std.testing.allocator.free(request_id);
    try answerRequest(&app, request_id, "\"error\":\"No database at that path\"");
    const answer = try call.finish();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"No database at that path\"}],\"isError\":true},\"jsonrpc\":\"2.0\",\"id\":3}\n\n", answer);
}

test "a tool call with arguments that do not match the tool's input is refused without asking the page" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    var call: Call = undefined;
    try call.start(port, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get_media_file_info\",\"arguments\":{}}}");
    const answer = try call.finish();
    defer std.testing.allocator.free(answer);

    try std.testing.expect(std.mem.indexOf(u8, answer, "Input validation error") != null);
    try std.testing.expect(app.shell.indexOfContaining("\"type\":\"mcp-tool-request\"") == null);
}

test "every tool of the desktop app is listed, in order" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    var call: Call = undefined;
    try call.start(port, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const answer = try call.finish();
    defer std.testing.allocator.free(answer);

    const names = [_][]const u8{
        "get_database_summary",
        "list_media_files",
        "get_media_file_info",
        "search_media_files",
        "save_media_file",
        "open_media_file",
        "import_media_files",
        "open_database",
        "close_database",
        "list_databases",
        "delete_media_file",
        "update_media_file",
        "verify_database",
    };
    var position: usize = 0;
    for (names) |name| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "\"name\":\"{s}\"", .{name});
        defer std.testing.allocator.free(needle);
        const found = std.mem.indexOfPos(u8, answer, position, needle) orelse {
            std.debug.print("The tool {s} is not listed after the one before it.\n", .{name});
            return error.ToolNotListed;
        };
        position = found;
    }
}

test "initialize tells the client what Photosphere is" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    var call: Call = undefined;
    try call.start(port, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}");
    const answer = try call.finish();
    defer std.testing.allocator.free(answer);

    try std.testing.expect(std.mem.indexOf(u8, answer, "\"serverInfo\":{\"name\":\"photosphere\",\"version\":\"dev\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "Photosphere is a local-first photo and video management app") != null);
}

test "an answer from the page with no request id is refused" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const message = try app.requestError("mcp-tool-response", "{\"result\":\"x\"}");
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("InvalidMessageData: the field \"requestId\" is missing", message);
}

test "an answer from the page to a request nobody is waiting for is ignored" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const reply = try app.requestOk("mcp-tool-response", "{\"requestId\":\"nobody-asked\",\"result\":\"x\"}");
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("null", reply);
}

test "stopping the server closes its port" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const port = try startServer(&app);

    main_state.fromCore(app.core).stopMcpServer();

    try std.testing.expectEqual(@as(u16, 0), main_state.fromCore(app.core).mcp_bridge.port.load(.acquire));
    try expectServerStopped(io, port);
}

test "the MCP server holds no worker of the task runner, so an app with one worker still runs its tasks" {
    var app: TestApp = undefined;
    try app.startWithWorkers(1);
    defer app.stop();
    _ = try startServer(&app);

    app.core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"after-mcp-1\",\"taskType\":\"get-databases\",\"source\":\"test\",\"data\":null,\"priority\":\"background\"}}");
    try app.shell.expectMessageContaining("\"taskId\":\"after-mcp-1\",\"result\":{\"taskId\":\"after-mcp-1\",\"status\":\"succeeded\"");
}

test "the fixed port is the one clients are told to use" {
    try std.testing.expectEqual(@as(u16, 3475), mcp_server.MCP_PORT);
}

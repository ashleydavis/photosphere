//
// Tests for streamable-http.zig.
//
// Each test starts the real HTTP server on a free loopback port with the routes of the transport and sends it requests with the
// HTTP client of the standard library, so the transport is seen as an MCP client sees it.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const mcp = @import("mcp-zig");
const protocol = mcp.protocol;
const streamable_http = mcp.streamable_http;
const HttpServer = node_utils.http_server.HttpServer;
const McpServer = protocol.McpServer;
const BsonDocument = serialization_zig.bson.BsonDocument;
const ziggy = @import("ziggy");
const MessageQueue = ziggy.message_queue.MessageQueue;
const io = std.testing.io;

//
// The Accept header of an MCP client.
//
const MCP_ACCEPT = "application/json, text/event-stream";

//
// What the server answered.
//
const Reply = struct {
    // The status code.
    status: u16,

    // The Content-Type header, or null.
    contentType: ?[]const u8,

    // The Allow header, or null.
    allow: ?[]const u8,

    // The body.
    body: []u8,
};

//
// The headers and the body of a request.
//
const RequestOptions = struct {
    // The Accept header, or null for none.
    accept: ?[]const u8,

    // The Content-Type header, or null for none.
    contentType: ?[]const u8,

    // The MCP-Protocol-Version header, or null for none.
    protocolVersion: ?[]const u8,

    // The body, or null for none.
    payload: ?[]const u8,
};

//
// The handler of the echo tool: answers with the text it was given.
//
fn echo(context: ?*anyopaque, allocator: std.mem.Allocator, toolIo: std.Io, arguments: BsonDocument) !protocol.ICallToolResult {
    _ = context;
    _ = toolIo;
    const content = try allocator.alloc(protocol.ITextContent, 1);
    content[0] = .{
        .text = arguments.get("text").?.string,
    };
    return .{
        .content = content,
    };
}

//
// Makes a connection thread's MCP server with the echo tool, on the connection thread, with the thread's own allocator, so the server
// is used only on the thread that made it.
//
fn createConnectionServer(config: []const u8, native_callbacks: ?*const ziggy.core.NativeCallbacks, allocator: std.mem.Allocator, threadIo: std.Io) anyerror!*anyopaque {
    _ = config;
    _ = native_callbacks;
    _ = threadIo;
    const server = try allocator.create(McpServer);
    errdefer allocator.destroy(server);
    server.* = McpServer.init(.{
        .name = "test-server",
        .version = "1.2.3",
    }, .{
        .instructions = "Use the tools.",
    });
    errdefer server.deinit(allocator);
    try server.registerTool(allocator, "echo", .{
        .description = "Echoes its text.",
        .inputSchema = &.{
            .{
                .name = "text",
                .fieldType = .string,
                .presence = .required,
            },
        },
    }, null, echo);
    return server;
}

//
// Frees a connection thread's MCP server, on the thread that made it.
//
fn destroyConnectionServer(state: *anyopaque, allocator: std.mem.Allocator) void {
    const server: *McpServer = @ptrCast(@alignCast(state));
    server.deinit(allocator);
    allocator.destroy(server);
}

//
// A running transport: the HTTP server, whose connection thread makes its own MCP server, and what stops it.
//
const Running = struct {
    // Whether the HTTP server has been stopped, by the test of the GET stream.
    stopped: bool,

    // The HTTP server.
    httpServer: *HttpServer,

    //
    // Starts the server in place.
    //
    fn start(self: *Running) !void {
        self.stopped = false;
        const listener = try node_utils.http_server.open(io, "127.0.0.1", 0);
        self.httpServer = try HttpServer.start(io, std.testing.allocator, listener, .{
            .router = streamable_http.StreamableHttpRoutes.router,
            .maxConnectionThreads = 1,
            .connectionState = .{
                .create = createConnectionServer,
                .destroy = destroyConnectionServer,
            },
        });
    }

    //
    // Stops the HTTP server, which ends the streams.
    //
    fn stop(self: *Running) void {
        if (!self.stopped) {
            self.httpServer.stop(io, std.testing.allocator);
        }
    }

    //
    // Sends one request and returns what the server answers, allocated with the test's allocator.
    //
    fn send(self: *Running, allocator: std.mem.Allocator, method: std.http.Method, target: []const u8, options: RequestOptions) !Reply {
        return sendTo(allocator, io, self.httpServer.port, method, target, options);
    }

    //
    // Sends one request to the server on the port, with the allocator and Io of the calling thread, and returns what the server
    // answers, allocated with the allocator.
    //
    fn sendTo(allocator: std.mem.Allocator, clientIo: std.Io, port: u16, method: std.http.Method, target: []const u8, options: RequestOptions) !Reply {
        var client: std.http.Client = .{
            .allocator = allocator,
            .io = clientIo,
        };
        defer client.deinit();
        const uri = try std.Uri.parse(try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, target }));
        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        if (options.accept) |accept| {
            try extra_headers.append(allocator, .{
                .name = "Accept",
                .value = accept,
            });
        }
        if (options.protocolVersion) |version| {
            try extra_headers.append(allocator, .{
                .name = "MCP-Protocol-Version",
                .value = version,
            });
        }
        var request = try client.request(method, uri, .{
            .headers = .{
                .content_type = if (options.contentType) |value| .{ .override = value } else .omit,
            },
            .extra_headers = extra_headers.items,
            .keep_alive = false,
        });
        defer request.deinit();
        if (options.payload) |payload| {
            request.transfer_encoding = .{
                .content_length = payload.len,
            };
            var body = try request.sendBodyUnflushed(&.{});
            try body.writer.writeAll(payload);
            try body.end();
            try request.connection.?.flush();
        }
        else {
            try request.sendBodiless();
        }
        var redirect_buffer: [1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);

        var reply: Reply = .{
            .status = @intFromEnum(response.head.status),
            .contentType = if (response.head.content_type) |value| try allocator.dupe(u8, value) else null,
            .allow = null,
            .body = &.{},
        };
        var headers = std.http.HeaderIterator.init(response.head.bytes);
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "allow")) {
                reply.allow = try allocator.dupe(u8, header.value);
            }
        }
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        reply.body = try reader.allocRemaining(allocator, .unlimited);
        return reply;
    }

    //
    // Sends a POST to /mcp the way an MCP client does.
    //
    fn post(self: *Running, allocator: std.mem.Allocator, payload: []const u8) !Reply {
        return self.send(allocator, .POST, "/mcp", .{
            .accept = MCP_ACCEPT,
            .contentType = "application/json",
            .protocolVersion = null,
            .payload = payload,
        });
    }
};

//
// An initialize request.
//
const INITIALIZE =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
;

test "a POST of a request is answered with an event stream holding the response" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, INITIALIZE);

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("text/event-stream", reply.contentType.?);
    try std.testing.expectEqualStrings(
        "event: message\ndata: {\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"test-server\",\"version\":\"1.2.3\"},\"instructions\":\"Use the tools.\"},\"jsonrpc\":\"2.0\",\"id\":1}\n\n",
        reply.body,
    );
}

test "a tool is called through a POST and its result comes back in the stream" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, 
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}
    );

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings(
        "event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]},\"jsonrpc\":\"2.0\",\"id\":5}\n\n",
        reply.body,
    );
}

test "a batch of requests is answered with one event for each, in order" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, 
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"b","method":"ping"}]
    );

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings(
        "event: message\ndata: {\"result\":{},\"jsonrpc\":\"2.0\",\"id\":1}\n\nevent: message\ndata: {\"result\":{},\"jsonrpc\":\"2.0\",\"id\":\"b\"}\n\n",
        reply.body,
    );
}

test "a POST of a notification is accepted and answered with nothing" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, 
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    try std.testing.expectEqual(@as(u16, 202), reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
}

test "a POST that does not accept both media types is refused with 406" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/mcp", .{
        .accept = "application/json",
        .contentType = "application/json",
        .protocolVersion = null,
        .payload = INITIALIZE,
    });

    try std.testing.expectEqual(@as(u16, 406), reply.status);
    try std.testing.expectEqualStrings("application/json", reply.contentType.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Not Acceptable: Client must accept both application/json and text/event-stream\"},\"id\":null}",
        reply.body,
    );
}

test "a POST that is not JSON is refused with 415" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/mcp", .{
        .accept = MCP_ACCEPT,
        .contentType = "text/plain",
        .protocolVersion = null,
        .payload = "hello",
    });

    try std.testing.expectEqual(@as(u16, 415), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Unsupported Media Type: Content-Type must be application/json\"},\"id\":null}",
        reply.body,
    );
}

test "a POST that is not a JSON-RPC message is refused with a parse error" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, "{\"hello\":1}");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error: Invalid JSON-RPC message\"},\"id\":null}",
        reply.body,
    );
}

test "a POST with an empty body is refused with a parse error" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, "");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "Parse error: Invalid JSON-RPC message") != null);
}

test "a POST of text that is not JSON is refused with an error page" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, "{\"jsonrpc\":");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", reply.contentType.?);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "<pre>Unexpected token in JSON</pre>") != null);
}

test "a POST of a body over the limit is refused with 413" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = try allocator.alloc(u8, streamable_http.JSON_BODY_LIMIT + 1);
    @memset(text, 'a');
    const payload = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{{\"x\":\"{s}\"}}}}", .{text});

    const reply = try running.post(allocator, payload);

    try std.testing.expectEqual(@as(u16, 413), reply.status);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "request entity too large") != null);
}

test "a request that names a protocol version the server does not support is refused" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/mcp", .{
        .accept = MCP_ACCEPT,
        .contentType = "application/json",
        .protocolVersion = "1999-01-01",
        .payload =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        ,
    });

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Bad Request: Unsupported protocol version: 1999-01-01 (supported versions: 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)\"},\"id\":null}",
        reply.body,
    );
}

test "an initialize request is answered whatever protocol version the header names" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/mcp", .{
        .accept = MCP_ACCEPT,
        .contentType = "application/json",
        .protocolVersion = "1999-01-01",
        .payload = INITIALIZE,
    });

    try std.testing.expectEqual(@as(u16, 200), reply.status);
}

test "a batch holding an initialize request and another message is refused" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.post(allocator, 
        \\[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    );

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request: Only one initialization request is allowed\"},\"id\":null}",
        reply.body,
    );
}

test "a GET that does not accept an event stream is refused with 406" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .GET, "/mcp", .{
        .accept = "application/json",
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    });

    try std.testing.expectEqual(@as(u16, 406), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Not Acceptable: Client must accept text/event-stream\"},\"id\":null}",
        reply.body,
    );
}

//
// What the client thread of the test of the GET stream reports of the reply, as the JSON text it posts back.
//
const IStreamReply = struct {
    // The status code.
    status: u16,

    // The Content-Type header, or null.
    contentType: ?[]const u8,

    // How many bytes the body had.
    bodyLength: usize,
};

//
// The client of the test of the GET stream: makes its own allocator and Io, sends the GET to the server on the port and posts what it
// got back to the test thread's queue as JSON text.
//
fn getStreamOnThread(port: u16, replies: *MessageQueue) void {
    var thread_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    const clientIo = threaded.io();
    var arena = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    const reply = Running.sendTo(allocator, clientIo, port, .GET, "/mcp", .{
        .accept = "text/event-stream",
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    }) catch |err| {
        std.debug.panic("The GET of the stream failed: {s}", .{@errorName(err)});
    };
    const reported: IStreamReply = .{
        .status = reply.status,
        .contentType = reply.contentType,
        .bodyLength = reply.body.len,
    };
    const text = std.json.Stringify.valueAlloc(allocator, reported, .{}) catch @panic("out of memory reporting the reply");
    replies.post(clientIo, 0, text) catch @panic("out of memory reporting the reply");
}

// The stream stays open until the server stops, so the client sends the GET from a thread of its own, the test thread stops the server
// after a short wait, and the reply is read once the client thread has posted it.
test "a GET that accepts an event stream gets a stream that ends when the server stops" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var replies = MessageQueue.init();
    defer replies.deinit();
    const client = try std.Thread.spawn(.{}, getStreamOnThread, .{ running.httpServer.port, &replies });

    try io.sleep(.fromMilliseconds(500), .awake);
    running.httpServer.stop(io, std.testing.allocator);
    running.stopped = true;
    client.join();

    const message = replies.tryTake(io, allocator).?;
    const reply = try std.json.parseFromSliceLeaky(IStreamReply, allocator, message.text, .{});
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("text/event-stream", reply.contentType.?);
    try std.testing.expectEqual(@as(usize, 0), reply.bodyLength);
}

test "a method with no route is answered with the 404 page of Express" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .DELETE, "/mcp", .{
        .accept = null,
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    });

    try std.testing.expectEqual(@as(u16, 404), reply.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", reply.contentType.?);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "<pre>Cannot DELETE /mcp</pre>") != null);
}

test "a path with no route is answered with the 404 page of Express, with the path escaped" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .GET, "/other<b>", .{
        .accept = MCP_ACCEPT,
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    });

    try std.testing.expectEqual(@as(u16, 404), reply.status);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "<pre>Cannot GET /other&lt;b&gt;</pre>") != null);
}

test "OPTIONS on the route lists the methods it answers" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .OPTIONS, "/mcp", .{
        .accept = null,
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    });

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("GET,HEAD,POST", reply.allow.?);
    try std.testing.expectEqualStrings("GET,HEAD,POST", reply.body);
}

test "the route is found with a trailing slash and in any case" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/MCP/", .{
        .accept = MCP_ACCEPT,
        .contentType = "application/json",
        .protocolVersion = null,
        .payload =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        ,
    });

    try std.testing.expectEqual(@as(u16, 200), reply.status);
}

//
// Sends the text on a new connection to the server and returns everything it sends back until it closes the connection, for a
// request the HTTP client of the standard library will not send.
//
fn exchange(running: *Running, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", running.httpServer.port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

// Express hands a HEAD to the GET route, and the SDK's transport refuses a method that is not POST, GET or DELETE with a 405.
test "a HEAD of the route is refused with 405 and the methods the transport answers" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .HEAD, "/mcp", .{
        .accept = MCP_ACCEPT,
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    });

    try std.testing.expectEqual(@as(u16, 405), reply.status);
    try std.testing.expectEqualStrings("application/json", reply.contentType.?);
    try std.testing.expectEqualStrings("GET, POST, DELETE", reply.allow.?);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
}

// `express.json()` reads a Content-Type in any case, but the SDK's transport looks for "application/json" exactly as it is written.
test "a POST whose Content-Type names JSON in capitals is refused with 415" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/mcp", .{
        .accept = MCP_ACCEPT,
        .contentType = "Application/JSON",
        .protocolVersion = null,
        .payload =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        ,
    });

    try std.testing.expectEqual(@as(u16, 415), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Unsupported Media Type: Content-Type must be application/json\"},\"id\":null}",
        reply.body,
    );
}

// With no body `express.json()` leaves the body unset, so the SDK's transport reads the request itself, and an empty request is
// not JSON.
test "a POST with no body at all is refused as invalid JSON" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try exchange(&running, allocator, "POST /mcp HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: " ++ MCP_ACCEPT ++ "\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n");

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 400 "));
    try std.testing.expect(std.mem.endsWith(u8, reply, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error: Invalid JSON\"},\"id\":null}"));
}

// A Content-Type that holds "application/json" but is not the type `express.json()` reads leaves the body to the SDK's transport,
// which parses it as it is.
test "a POST whose body express does not read is parsed by the transport" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .POST, "/mcp", .{
        .accept = MCP_ACCEPT,
        .contentType = "application/json-seq; x=application/json",
        .protocolVersion = null,
        .payload =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        ,
    });

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("event: message\ndata: {\"result\":{},\"jsonrpc\":\"2.0\",\"id\":1}\n\n", reply.body);
}

test "a GET that names a protocol version the server does not support is refused" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reply = try running.send(allocator, .GET, "/mcp", .{
        .accept = "text/event-stream",
        .contentType = null,
        .protocolVersion = "1999-01-01",
        .payload = null,
    });

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Bad Request: Unsupported protocol version: 1999-01-01 (supported versions: 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)\"},\"id\":null}",
        reply.body,
    );
}

// The SDK's JSONRPCMessageSchema takes a response of the client's (a result that is an object, or an error with a numeric code and
// a message) and refuses anything else that has no method.
test "a POST of responses is accepted and a message that is neither a request nor a response is a parse error" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const accepted = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        ,
    };
    for (accepted) |payload| {
        const reply = try running.post(allocator, payload);
        try std.testing.expectEqual(@as(u16, 202), reply.status);
    }

    const refused = [_][]const u8{
        \\{"jsonrpc":"2.0"}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":5}
        ,
        \\{"jsonrpc":"2.0","id":1,"error":"failed"}
        ,
        \\{"jsonrpc":"2.0","id":1,"error":{"message":"no code"}}
        ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":1}}
        ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":"1","message":"text code"}}
        ,
        \\{"jsonrpc":"2.0","id":1}
        ,
    };
    for (refused) |payload| {
        const reply = try running.post(allocator, payload);
        try std.testing.expectEqual(@as(u16, 400), reply.status);
        try std.testing.expectEqualStrings(
            "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error: Invalid JSON-RPC message\"},\"id\":null}",
            reply.body,
        );
    }
}

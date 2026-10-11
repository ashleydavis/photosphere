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
const io = std.testing.io;

//
// Allocates the server and the threads of its connections, which use it from many threads at once.
//
const server_allocator = std.heap.smp_allocator;

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
// A running transport: the MCP server, the HTTP server and what stops them.
//
const Running = struct {
    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The MCP server with the echo tool.
    mcpServer: McpServer,

    // Whether the streams of GET requests should end.
    stopping: std.atomic.Value(bool),

    // The routes the HTTP server calls.
    routes: streamable_http.StreamableHttpRoutes,

    // The HTTP server.
    httpServer: *HttpServer,

    //
    // Starts the servers in place.
    //
    fn start(self: *Running) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.mcpServer = McpServer.init(self.arena.allocator(), .{
            .name = "test-server",
            .version = "1.2.3",
        }, .{
            .instructions = "Use the tools.",
        });
        try self.mcpServer.registerTool("echo", .{
            .description = "Echoes its text.",
            .inputSchema = &.{
                .{
                    .name = "text",
                    .fieldType = .string,
                    .presence = .required,
                },
            },
        }, null, echo);
        self.stopping = .init(false);
        self.routes = .{
            .server = &self.mcpServer,
            .stopping = &self.stopping,
        };
        self.httpServer = try HttpServer.listen(server_allocator, io, "127.0.0.1", 0, self.routes.requestHandler());
    }

    //
    // Ends the streams, closes the HTTP server and frees what the test made.
    //
    fn stop(self: *Running) void {
        self.stopping.store(true, .release);
        self.httpServer.close();
        self.arena.deinit();
    }

    //
    // Sends one request and returns what the server answers.
    //
    fn send(self: *Running, method: std.http.Method, target: []const u8, options: RequestOptions) !Reply {
        const allocator = self.arena.allocator();
        var client: std.http.Client = .{
            .allocator = allocator,
            .io = io,
        };
        defer client.deinit();
        const uri = try std.Uri.parse(try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.httpServer.port, target }));
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
    fn post(self: *Running, payload: []const u8) !Reply {
        return self.send(.POST, "/mcp", .{
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

    const reply = try running.post(INITIALIZE);

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

    const reply = try running.post(
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

    const reply = try running.post(
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

    const reply = try running.post(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    try std.testing.expectEqual(@as(u16, 202), reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
}

test "a POST that does not accept both media types is refused with 406" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();

    const reply = try running.send(.POST, "/mcp", .{
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

    const reply = try running.send(.POST, "/mcp", .{
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

    const reply = try running.post("{\"hello\":1}");

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

    const reply = try running.post("");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "Parse error: Invalid JSON-RPC message") != null);
}

test "a POST of text that is not JSON is refused with an error page" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();

    const reply = try running.post("{\"jsonrpc\":");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", reply.contentType.?);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "<pre>Unexpected token in JSON</pre>") != null);
}

test "a POST of a body over the limit is refused with 413" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    const allocator = running.arena.allocator();
    const text = try allocator.alloc(u8, streamable_http.JSON_BODY_LIMIT + 1);
    @memset(text, 'a');
    const payload = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{{\"x\":\"{s}\"}}}}", .{text});

    const reply = try running.post(payload);

    try std.testing.expectEqual(@as(u16, 413), reply.status);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "request entity too large") != null);
}

test "a request that names a protocol version the server does not support is refused" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();

    const reply = try running.send(.POST, "/mcp", .{
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

    const reply = try running.send(.POST, "/mcp", .{
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

    const reply = try running.post(
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

    const reply = try running.send(.GET, "/mcp", .{
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

// The stream stays open until the server stops, so the reply is only read after the stop is asked for.
test "a GET that accepts an event stream gets a stream that ends when the server stops" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();
    const stopper = try std.Thread.spawn(.{}, stopAfterDelay, .{&running});

    const reply = try running.send(.GET, "/mcp", .{
        .accept = "text/event-stream",
        .contentType = null,
        .protocolVersion = null,
        .payload = null,
    });
    stopper.join();

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("text/event-stream", reply.contentType.?);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
}

//
// Asks the streams to end after a short wait, for the test of the GET stream.
//
fn stopAfterDelay(running: *Running) void {
    io.sleep(.fromMilliseconds(500), .awake) catch {
        @panic("The test could not wait before stopping the streams.");
    };
    running.stopping.store(true, .release);
}

test "a method with no route is answered with the 404 page of Express" {
    var running: Running = undefined;
    try running.start();
    defer running.stop();

    const reply = try running.send(.DELETE, "/mcp", .{
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

    const reply = try running.send(.GET, "/other<b>", .{
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

    const reply = try running.send(.OPTIONS, "/mcp", .{
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

    const reply = try running.send(.POST, "/MCP/", .{
        .accept = MCP_ACCEPT,
        .contentType = "application/json",
        .protocolVersion = null,
        .payload =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        ,
    });

    try std.testing.expectEqual(@as(u16, 200), reply.status);
}

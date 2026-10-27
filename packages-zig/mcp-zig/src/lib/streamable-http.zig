const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const node_utils = @import("node-utils-zig");
const protocol = @import("protocol.zig");
const McpServer = protocol.McpServer;
const http_server = node_utils.http_server;

//
// The Streamable HTTP transport of an MCP server: `POST /mcp` carries JSON-RPC messages to the server and answers with a
// server-sent events stream holding the responses, and `GET /mcp` opens the stream for messages the server starts. It is the
// transport the MCP SDK's StreamableHTTPServerTransport gives an Express application, with the application's routes: only
// `POST /mcp` and `GET /mcp` exist, and any other request is answered with the 404 page Express sends.
//
// The transport is stateless: no session is made and no request depends on an earlier one, so every request is answered by the
// MCP server its connection thread made for itself, with the same tools as every other. A request is answered on the thread of its
// connection, so a tool may wait as long as it needs to without holding up the others.
//
// The media types and headers follow the SDK: a POST must accept both application/json and text/event-stream and must send
// application/json, a GET must accept text/event-stream, and a protocol version that the server does not support is refused.
//

//
// The largest JSON body a POST reads, in bytes: the default limit of `express.json()`, which is "100kb".
//
pub const JSON_BODY_LIMIT = 100 * 1024;

//
// How long a GET stream waits for a message to its connection thread at a time, in milliseconds. Each wait that ends with none
// writes a comment, to find out whether the client has gone.
//
const STREAM_KEEP_ALIVE_MS = 10_000;

//
// The routes of the transport, for the HTTP framework (node_utils.http_server). They hold nothing: each connection thread makes an MCP
// server of its own (its connection state, see http_server.ConnectionState, is an McpServer), and a request is given to the server of
// the thread it arrives on.
//
pub const StreamableHttpRoutes = struct {
    //
    // The routes, for the HTTP framework.
    //
    pub const router: http_server.Router = .{
        .context = null,
        .routes = &route_table,
        .notFound = notFound,
    };

    //
    // `POST /mcp` and `GET /mcp`, and the answers Express gives to `HEAD /mcp` and `OPTIONS /mcp`.
    //
    const route_table = [_]http_server.Route{
        .{
            .method = .POST,
            .path = "/mcp",
            .handle = postRoute,
        },
        .{
            .method = .GET,
            .path = "/mcp",
            .handle = getRoute,
        },
        .{
            .method = .HEAD,
            .path = "/mcp",
            .handle = headRoute,
        },
        .{
            .method = .OPTIONS,
            .path = "/mcp",
            .handle = optionsRoute,
        },
    };

    //
    // The MCP server of the connection thread a request arrived on. A server whose connection threads keep no state is a mistake of its
    // owner's.
    //
    fn serverFor(request: *http_server.Request) *McpServer {
        const state = request.state orelse {
            @panic("the Streamable HTTP routes were served by a connection thread with no MCP server of its own");
        };
        return @ptrCast(@alignCast(state));
    }

    //
    // POST /mcp.
    //
    fn postRoute(context: ?*anyopaque, request: *http_server.Request, io: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        _ = context;
        const headers = try readHeaders(allocator, request.http);
        return postMcp(serverFor(request), allocator, io, request.http, headers);
    }

    //
    // GET /mcp.
    //
    fn getRoute(context: ?*anyopaque, request: *http_server.Request, io: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        _ = context;
        const headers = try readHeaders(allocator, request.http);
        return getMcp(request, io, allocator, headers);
    }

    //
    // HEAD /mcp, which the SDK refuses.
    //
    fn headRoute(context: ?*anyopaque, request: *http_server.Request, _: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        _ = context;
        return sendJsonErrorWithHeaders(allocator, request.http, .method_not_allowed, -32000, "Method not allowed.", &.{
            .{
                .name = "Allow",
                .value = "GET, POST, DELETE",
            },
        });
    }

    //
    // OPTIONS /mcp, which Express answers with the methods the routes have.
    //
    fn optionsRoute(context: ?*anyopaque, request: *http_server.Request, _: std.Io, _: ILog, _: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        _ = context;
        return sendAllowed(request.http, "GET,HEAD,POST");
    }

    //
    // The 404 Express sends for anything else.
    //
    fn notFound(context: ?*anyopaque, request: *http_server.Request, _: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        _ = context;
        const message = try std.fmt.allocPrint(allocator, "Cannot {s} {s}", .{ @tagName(request.method), try escapeHtml(allocator, request.path) });
        return sendErrorPage(allocator, request.http, .not_found, message);
    }

    //
    // POST /mcp: reads the body the way `express.json()` does, and gives the messages to the server.
    //
    fn postMcp(server: *McpServer, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, headers: IHeaders) !void {
        // Reads a JSON body of at most 100kb, and leaves the body unset for a request that does not say it holds JSON or that has
        // no body, as `express.json()` does.
        const has_body = request.head.method.requestHasBody() and (request.head.content_length != null or request.head.transfer_encoding != .none);
        var parsed_body: ?std.json.Value = null;
        if (has_body and isJsonType(headers.content_type)) {
            const body_buffer = try allocator.alloc(u8, 16 * 1024);
            const reader = try request.readerExpectContinue(body_buffer);
            const text = reader.allocRemaining(allocator, .limited(JSON_BODY_LIMIT)) catch |err| switch (err) {
                error.StreamTooLong => return sendErrorPage(allocator, request, .payload_too_large, "request entity too large"),
                else => return err,
            };
            parsed_body = parseJsonBody(allocator, text) catch {
                return sendErrorPage(allocator, request, .bad_request, "Unexpected token in JSON");
            };
        }

        // The client MUST include an Accept header, listing both application/json and text/event-stream as supported content types.
        const accept = headers.accept orelse "";
        if (std.mem.indexOf(u8, accept, "application/json") == null or std.mem.indexOf(u8, accept, "text/event-stream") == null) {
            return sendJsonError(allocator, request, .not_acceptable, -32000, "Not Acceptable: Client must accept both application/json and text/event-stream");
        }
        if (std.mem.indexOf(u8, headers.content_type orelse "", "application/json") == null) {
            return sendJsonError(allocator, request, .unsupported_media_type, -32000, "Unsupported Media Type: Content-Type must be application/json");
        }

        // A body `express.json()` left unset is read by the transport itself, as JSON of any kind and with no limit.
        const body = parsed_body orelse body: {
            var text: []const u8 = "";
            if (has_body) {
                const body_buffer = try allocator.alloc(u8, 16 * 1024);
                const reader = try request.readerExpectContinue(body_buffer);
                text = try reader.allocRemaining(allocator, .unlimited);
            }
            break :body std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch {
                return sendJsonError(allocator, request, .bad_request, -32700, "Parse error: Invalid JSON");
            };
        };

        // A single message or a batch of them.
        var messages: std.ArrayList(std.json.Value) = .empty;
        if (body == .array) {
            try messages.appendSlice(allocator, body.array.items);
        }
        else {
            try messages.append(allocator, body);
        }
        var request_count: usize = 0;
        var initialize_count: usize = 0;
        for (messages.items) |message| {
            switch (messageKind(message)) {
                .invalid => return sendJsonError(allocator, request, .bad_request, -32700, "Parse error: Invalid JSON-RPC message"),
                .request => {
                    request_count += 1;
                    if (isInitializeRequest(message)) {
                        initialize_count += 1;
                    }
                },
                .notification, .response => {},
            }
        }
        if (initialize_count > 0 and messages.items.len > 1) {
            return sendJsonError(allocator, request, .bad_request, -32600, "Invalid Request: Only one initialization request is allowed");
        }
        if (initialize_count == 0) {
            if (try unsupportedProtocolVersion(allocator, headers)) |text| {
                return sendJsonError(allocator, request, .bad_request, -32000, text);
            }
        }

        // A batch of notifications and responses is accepted and answered with nothing.
        if (request_count == 0) {
            return request.respond("", .{
                .status = .accepted,
                .keep_alive = false,
                .transfer_encoding = .none,
            });
        }

        const buffer = try allocator.alloc(u8, 16 * 1024);
        var stream = try request.respondStreaming(buffer, .{
            .respond_options = .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{
                        .name = "Content-Type",
                        .value = "text/event-stream",
                    },
                    .{
                        .name = "Cache-Control",
                        .value = "no-cache",
                    },
                },
            },
        });
        for (messages.items) |message| {
            if (messageKind(message) != .request) {
                continue;
            }
            const line = try std.json.Stringify.valueAlloc(allocator, message, .{});
            const answer = try server.handleMessage(allocator, io, line) orelse {
                continue;
            };
            try stream.writer.print("event: message\ndata: {s}\n\n", .{answer});
        }
        // The stream ends when every response has been sent.
        try stream.end();
    }

    //
    // GET /mcp: opens the stream the server starts messages on. This server starts none, so the stream stays open until the server
    // stops or the client goes away.
    //
    fn getMcp(connection: *http_server.Request, io: std.Io, given_allocator: std.mem.Allocator, headers: IHeaders) !void {
        const request = connection.http;
        var arena_state = std.heap.ArenaAllocator.init(given_allocator);
        defer arena_state.deinit();
        const allocator = arena_state.allocator();

        const accept = headers.accept orelse "";
        if (std.mem.indexOf(u8, accept, "text/event-stream") == null) {
            return sendJsonError(allocator, request, .not_acceptable, -32000, "Not Acceptable: Client must accept text/event-stream");
        }
        if (try unsupportedProtocolVersion(allocator, headers)) |text| {
            return sendJsonError(allocator, request, .bad_request, -32000, text);
        }

        const buffer = try allocator.alloc(u8, 1024);
        var stream = try request.respondStreaming(buffer, .{
            .respond_options = .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{
                        .name = "Content-Type",
                        .value = "text/event-stream",
                    },
                    .{
                        .name = "Cache-Control",
                        .value = "no-cache, no-transform",
                    },
                },
            },
        });
        // The headers go out now, so that the client knows the stream is open.
        try stream.writer.flush();
        try stream.flush();

        // The stream stays open until the connection thread is told to stop. Its messages are read as it waits, and none is for the
        // stream, since the server starts no messages.
        while (!connection.stopped) {
            if (connection.waitForMessage(io, given_allocator, STREAM_KEEP_ALIVE_MS)) |message| {
                given_allocator.free(message.text);
                continue;
            }
            if (connection.stopped) {
                break;
            }
            // (Zig: nothing wakes a thread that waits on a client that has gone, so a comment is written now and then, and writing to a
            // client that has gone fails and ends the stream.)
            try stream.writer.writeAll(": keep-alive\n\n");
            try stream.writer.flush();
            try stream.flush();
        }
        try stream.end();
    }
};

//
// The request headers the routes read.
//
const IHeaders = struct {
    // The Accept header, or null when there is none.
    accept: ?[]const u8,

    // The Content-Type header, or null when there is none.
    content_type: ?[]const u8,

    // The MCP-Protocol-Version header, or null when there is none.
    protocol_version: ?[]const u8,
};

//
// Copies the headers the routes read out of the request's head.
//
fn readHeaders(allocator: std.mem.Allocator, request: *std.http.Server.Request) !IHeaders {
    var headers: IHeaders = .{
        .accept = null,
        .content_type = null,
        .protocol_version = null,
    };
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
            headers.accept = try allocator.dupe(u8, header.value);
        }
        else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            headers.content_type = try allocator.dupe(u8, header.value);
        }
        else if (std.ascii.eqlIgnoreCase(header.name, "mcp-protocol-version")) {
            headers.protocol_version = try allocator.dupe(u8, header.value);
        }
    }
    return headers;
}

//
// What a JSON-RPC message is.
//
const MessageKind = enum {
    // A request: it has a method and an id, and is answered.
    request,

    // A notification: it has a method and no id, and is not answered.
    notification,

    // A response of the client to a request of the server's.
    response,

    // Not a JSON-RPC 2.0 message.
    invalid,
};

//
// Tells what a message is (the SDK's JSONRPCMessageSchema).
//
fn messageKind(message: std.json.Value) MessageKind {
    if (message != .object) {
        return .invalid;
    }
    const version = message.object.get("jsonrpc") orelse {
        return .invalid;
    };
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) {
        return .invalid;
    }
    const id = message.object.get("id");
    if (id) |id_value| {
        if (id_value != .string and id_value != .integer and id_value != .float and id_value != .number_string) {
            return .invalid;
        }
    }
    if (message.object.get("method")) |method| {
        if (method != .string) {
            return .invalid;
        }
        if (message.object.get("params")) |params| {
            if (params != .object) {
                return .invalid;
            }
        }
        return if (id != null) .request else .notification;
    }
    if (id == null) {
        return .invalid;
    }
    if (message.object.get("result")) |result| {
        return if (result == .object) .response else .invalid;
    }
    if (message.object.get("error")) |failure| {
        if (failure != .object) {
            return .invalid;
        }
        const code = failure.object.get("code") orelse {
            return .invalid;
        };
        const text = failure.object.get("message") orelse {
            return .invalid;
        };
        if ((code != .integer and code != .float) or text != .string) {
            return .invalid;
        }
        return .response;
    }
    return .invalid;
}

//
// Whether a request message is the one that starts a session (the SDK's isInitializeRequest).
//
fn isInitializeRequest(message: std.json.Value) bool {
    const method = message.object.get("method") orelse {
        return false;
    };
    return std.mem.eql(u8, method.string, "initialize");
}

//
// The text that refuses the protocol version of a request, or null when the request names none or names one the server supports.
//
fn unsupportedProtocolVersion(allocator: std.mem.Allocator, headers: IHeaders) !?[]const u8 {
    const version = headers.protocol_version orelse {
        return null;
    };
    for (protocol.SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.eql(u8, version, supported)) {
            return null;
        }
    }
    const supported_list = try std.mem.join(allocator, ", ", &protocol.SUPPORTED_PROTOCOL_VERSIONS);
    return try std.fmt.allocPrint(allocator, "Bad Request: Unsupported protocol version: {s} (supported versions: {s})", .{ version, supported_list });
}

//
// Whether a Content-Type names the media type `express.json()` reads: application/json, with or without parameters.
//
fn isJsonType(content_type: ?[]const u8) bool {
    const value = content_type orelse {
        return false;
    };
    const media_type = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

//
// Reads a JSON body the way `express.json()` does in its strict mode: only an object or an array is accepted.
//
fn parseJsonBody(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .object = .empty,
        };
    }
    if (trimmed[0] != '{' and trimmed[0] != '[') {
        return error.InvalidJsonBody;
    }
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{});
}

//
// Whether a request path is the route's path: case-insensitive, and with or without a trailing slash.
//
fn pathIsMcp(path: []const u8) bool {
    var trimmed = path;
    if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return std.ascii.eqlIgnoreCase(trimmed, "/mcp");
}

//
// Escapes text for a page.
//
fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (text) |character| {
        switch (character) {
            '&' => try escaped.appendSlice(allocator, "&amp;"),
            '<' => try escaped.appendSlice(allocator, "&lt;"),
            '>' => try escaped.appendSlice(allocator, "&gt;"),
            '"' => try escaped.appendSlice(allocator, "&quot;"),
            '\'' => try escaped.appendSlice(allocator, "&#39;"),
            else => try escaped.append(allocator, character),
        }
    }
    return escaped.items;
}

//
// The JSON-RPC error body the SDK sends for a request it refuses.
//
const IJsonRpcErrorBody = struct {
    // Always "2.0".
    jsonrpc: []const u8,

    // The error.
    @"error": IJsonRpcError,

    // Always null: the request has no id to answer.
    id: ?u8,
};

//
// The error of a JSON-RPC error body.
//
const IJsonRpcError = struct {
    // The JSON-RPC error code.
    code: i32,

    // What went wrong.
    message: []const u8,
};

//
// Sends a refusal as a JSON-RPC error with the status.
//
fn sendJsonError(allocator: std.mem.Allocator, request: *std.http.Server.Request, status: std.http.Status, code: i32, message: []const u8) !void {
    return sendJsonErrorWithHeaders(allocator, request, status, code, message, &.{});
}

//
// Sends a refusal as a JSON-RPC error with the status and the headers besides the Content-Type.
//
fn sendJsonErrorWithHeaders(allocator: std.mem.Allocator, request: *std.http.Server.Request, status: std.http.Status, code: i32, message: []const u8, headers: []const std.http.Header) !void {
    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    try extra_headers.appendSlice(allocator, headers);
    try extra_headers.append(allocator, .{
        .name = "Content-Type",
        .value = "application/json",
    });
    const body: IJsonRpcErrorBody = .{
        .jsonrpc = "2.0",
        .@"error" = .{
            .code = code,
            .message = message,
        },
        .id = null,
    };
    try request.respond(try std.json.Stringify.valueAlloc(allocator, body, .{}), .{
        .status = status,
        .keep_alive = false,
        .extra_headers = extra_headers.items,
    });
}

//
// The page Express sends for an error raised while handling a request.
// (Zig: the page holds the error's name and message only, with no stack.)
//
fn sendErrorPage(allocator: std.mem.Allocator, request: *std.http.Server.Request, status: std.http.Status, text: []const u8) !void {
    const page = try std.fmt.allocPrint(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>{s}</pre>\n</body>\n</html>\n", .{text});
    try request.respond(page, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "Content-Type",
                .value = "text/html; charset=utf-8",
            },
            .{
                .name = "Content-Security-Policy",
                .value = "default-src 'none'",
            },
            .{
                .name = "X-Content-Type-Options",
                .value = "nosniff",
            },
        },
    });
}

//
// Answers OPTIONS for a path that has routes: 200, and the methods the routes answer, in the `Allow` header and as the body.
//
fn sendAllowed(request: *std.http.Server.Request, allowed: []const u8) !void {
    try request.respond(allowed, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "Allow",
                .value = allowed,
            },
            .{
                .name = "Content-Type",
                .value = "text/plain",
            },
            .{
                .name = "X-Content-Type-Options",
                .value = "nosniff",
            },
        },
    });
}

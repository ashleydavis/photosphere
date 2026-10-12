const std = @import("std");
const node_utils = @import("node-utils-zig");
const protocol = @import("protocol.zig");
const McpServer = protocol.McpServer;
const RequestHandler = node_utils.http_server.RequestHandler;

//
// The Streamable HTTP transport of an MCP server: `POST /mcp` carries JSON-RPC messages to the server and answers with a
// server-sent events stream holding the responses, and `GET /mcp` opens the stream for messages the server starts. It is the
// transport the MCP SDK's StreamableHTTPServerTransport gives an Express application, with the application's routes: only
// `POST /mcp` and `GET /mcp` exist, and any other request is answered with the 404 page Express sends.
//
// The transport is stateless: no session is made and no request depends on an earlier one, so every request is answered by the
// one server whose tools are registered. A request is answered on the thread of its connection, so a tool may wait as long as it needs
// to without holding up the others.
//
// The media types and headers follow the SDK: a POST must accept both application/json and text/event-stream and must send
// application/json, a GET must accept text/event-stream, and a protocol version that the server does not support is refused.
//

//
// The largest JSON body a POST reads, in bytes: the default limit of `express.json()`, which is "100kb".
//
pub const JSON_BODY_LIMIT = 100 * 1024;

//
// How long a GET stream waits between looking at whether the server is stopping, in milliseconds.
//
const STREAM_POLL_INTERVAL_MS = 250;

//
// How many polls of a GET stream pass between the comments that are written to find out whether the client has gone, which is 10
// seconds.
//
const STREAM_KEEP_ALIVE_POLLS = 40;

//
// The routes of the transport. They must stay where they are while the HTTP server runs.
//
pub const StreamableHttpRoutes = struct {
    // The server the messages are given to.
    server: *McpServer,

    // Set by the owner before it closes the HTTP server, so that the streams of GET requests end.
    // (Zig: a thread blocked on a connection cannot be woken, so a stream that is held open looks at this to know when to end.)
    stopping: *std.atomic.Value(bool),

    //
    // Gets the handler an HTTP server (node_utils.http_server) calls with each request.
    //
    pub fn requestHandler(self: *StreamableHttpRoutes) RequestHandler {
        return .{
            .context = self,
            .handle = handleErased,
        };
    }

    //
    // The function the HTTP server calls, which gives the request to the routes it was made from.
    //
    fn handleErased(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) anyerror!void {
        const self: *StreamableHttpRoutes = @ptrCast(@alignCast(context.?));
        return self.handleRequest(allocator, io, request);
    }

    //
    // Answers one request: the route that matches, and the 404 Express sends when none does.
    //
    pub fn handleRequest(self: *StreamableHttpRoutes, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) !void {
        const method = request.head.method;
        // The target and the headers point into the request's head, which reading the body invalidates.
        const target = try allocator.dupe(u8, request.head.target);
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. query_start orelse target.len];
        const headers = try readHeaders(allocator, request);

        if (pathIsMcp(path)) {
            if (method == .POST) {
                return self.postMcp(allocator, io, request, headers);
            }
            if (method == .GET) {
                return self.getMcp(io, request, headers);
            }
            if (method == .HEAD) {
                // Express gives a HEAD to the GET route, and the SDK's transport answers a method it does not handle with a 405.
                return sendJsonErrorWithHeaders(allocator, request, .method_not_allowed, -32000, "Method not allowed.", &.{
                    .{
                        .name = "Allow",
                        .value = "GET, POST, DELETE",
                    },
                });
            }
            if (method == .OPTIONS) {
                return sendAllowed(request, "GET,HEAD,POST");
            }
        }

        const message = try std.fmt.allocPrint(allocator, "Cannot {s} {s}", .{ @tagName(method), try escapeHtml(allocator, path) });
        return sendErrorPage(allocator, request, .not_found, message);
    }

    //
    // POST /mcp: reads the body the way `express.json()` does, and gives the messages to the server.
    //
    fn postMcp(self: *StreamableHttpRoutes, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, headers: IHeaders) !void {
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
            const answer = try self.server.handleMessage(allocator, io, line) orelse {
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
    fn getMcp(self: *StreamableHttpRoutes, io: std.Io, request: *std.http.Server.Request, headers: IHeaders) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

        var polls: usize = 0;
        while (!self.stopping.load(.acquire)) {
            try io.sleep(.fromMilliseconds(STREAM_POLL_INTERVAL_MS), .awake);
            polls += 1;
            if (polls % STREAM_KEEP_ALIVE_POLLS == 0) {
                // (Zig: nothing wakes a thread that waits on a client that has gone, so a comment is written now and then, and
                // writing to a client that has gone fails and ends the stream.)
                try stream.writer.writeAll(": keep-alive\n\n");
                try stream.writer.flush();
                try stream.flush();
            }
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

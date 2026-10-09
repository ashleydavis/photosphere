const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const asset_server_core = @import("asset-server-core.zig");
const IAssetServerCore = asset_server_core.IAssetServerCore;
const IDatabaseOp = api.database_op.IDatabaseOp;
const errors = utils.errors;
const log = &utils.log.log;

//
// The largest JSON body POST /apply-database-ops reads, in bytes: the default limit of `express.json()`, which is "100kb".
//
const JSON_BODY_LIMIT = 100 * 1024;

//
// The CORS headers the original sends on every response when it owns the application (any origin may call, since the page's origin
// is `ziggy-app://app` or `https://ziggy-app.invalid` and never `file://`).
//
const cors_headers = [_]std.http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Origin, X-Requested-With, Content-Type, Accept" },
};

//
// The routes of the asset server, delegating all work to the transport-agnostic core. The routes are byte-for-byte the same as the
// original asset server: GET /asset, POST /asset, and POST /apply-database-ops. CORS headers are added only when enableCors is true
// (i.e. when the asset server owns the application rather than attaching to an existing one).
// (Zig: there is no express application to attach routes to, so the routes are a value that answers the requests an HTTP server hands
// it, in the order express would try them.)
//
pub const AssetServerRoutes = struct {
    // The core that does the work.
    core: IAssetServerCore,

    // Whether to add the CORS headers.
    enableCors: bool,

    //
    // Gets the handler an HTTP server (node_utils.http_server) calls with each request. The routes must stay where they are while
    // the server runs.
    //
    pub fn requestHandler(self: *AssetServerRoutes) node_utils.http_server.RequestHandler {
        return .{
            .context = self,
            .handle = handleErased,
        };
    }

    fn handleErased(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) anyerror!void {
        const self: *AssetServerRoutes = @ptrCast(@alignCast(context.?));
        return self.handleRequest(allocator, io, request);
    }

    //
    // Answers one request: the CORS middleware first, then the route that matches, and the 404 express sends when none does.
    //
    pub fn handleRequest(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) !void {
        const method = request.head.method;
        // The target and the content type point into the request's head, which reading the body invalidates.
        const target = try allocator.dupe(u8, request.head.target);
        const content_type: ?[]const u8 = if (request.head.content_type) |value| try allocator.dupe(u8, value) else null;
        const content_length = request.head.content_length;
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. query_start orelse target.len];
        const query: []const u8 = if (query_start) |start| target[start + 1 ..] else "";

        // Enable CORS for all routes (only when this server owns the app).
        if (self.enableCors and method == .OPTIONS) {
            return self.send(request, .ok, "text/plain; charset=utf-8", "OK");
        }

        if (pathIs(path, "/asset")) {
            if (method == .GET or method == .HEAD) {
                return self.getAsset(allocator, io, request, query);
            }
            if (method == .POST) {
                return self.postAsset(allocator, io, request, query, content_type, content_length);
            }
        }
        else if (pathIs(path, "/apply-database-ops") and method == .POST) {
            return self.postApplyDatabaseOps(allocator, io, request, content_type);
        }

        const message = try std.fmt.allocPrint(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>Cannot {s} {s}</pre>\n</body>\n</html>\n", .{ @tagName(method), try escapeHtml(allocator, path) });
        return self.send(request, .not_found, "text/html; charset=utf-8", message);
    }

    //
    // Handle HTTP GET requests for assets.
    //
    fn getAsset(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, query: []const u8) !void {
        const assetId = try queryParameter(allocator, query, "id");
        const databasePath = try queryParameter(allocator, query, "db");
        const assetType = try queryParameter(allocator, query, "type");

        if (assetId == null or assetId.?.len == 0) {
            return self.sendHtmlText(request, .bad_request, "Missing 'id' parameter");
        }

        if (databasePath == null or databasePath.?.len == 0) {
            return self.sendHtmlText(request, .bad_request, "Missing 'db' parameter");
        }

        if (assetType == null or assetType.?.len == 0) {
            return self.sendHtmlText(request, .bad_request, "Missing 'type' parameter");
        }

        // The stream is opened and its first bytes read before anything is sent, so that an asset that cannot be read is answered
        // with the 500 (in Node the headers are not sent until the first write).
        const assetStream = self.core.serveAsset(allocator, io, assetId.?, assetType.?, databasePath.?) catch |err| {
            return self.failedToLoadAsset(request, assetId.?, err);
        };
        defer assetStream.destroy(io);
        const reader = assetStream.reader();
        _ = reader.peek(1) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return self.failedToLoadAsset(request, assetId.?, err),
        };

        var headers: [1 + cors_headers.len]std.http.Header = undefined;
        const extra_headers = self.responseHeaders(&headers, "application/octet-stream");
        const buffer = try allocator.alloc(u8, 16 * 1024);
        var body = try request.respondStreaming(buffer, .{
            .respond_options = .{
                .keep_alive = false,
                .extra_headers = extra_headers,
            },
        });
        // An error after the headers are sent cannot be answered with a status: the connection is closed instead, as the pipeline
        // does to the response.
        _ = reader.streamRemaining(&body.writer) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Error loading asset {s}", .{assetId.?}), err);
            return err;
        };
        try body.end();
    }

    //
    // The catch block of GET /asset, for an error before any byte is sent.
    //
    fn failedToLoadAsset(self: *AssetServerRoutes, request: *std.http.Server.Request, assetId: []const u8, err: anyerror) !void {
        var message_buffer: [512]u8 = undefined;
        log.exception(std.fmt.bufPrint(&message_buffer, "Error loading asset {s}", .{assetId}) catch "Error loading asset", err);
        return self.sendHtmlText(request, .internal_server_error, "Error loading asset");
    }

    //
    // POST /asset — writes raw bytes for one asset variant (thumb | display | asset) into a database directory.
    // Same query params as GET: id, type, db. Body: raw bytes. Content-Type: MIME of the blob.
    // Used when moving/copying assets between databases (gallery) so file data matches metadata applied via apply-database-ops.
    //
    fn postAsset(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, query: []const u8, contentType: ?[]const u8, contentLength: ?u64) !void {
        const assetId = try queryParameter(allocator, query, "id");
        const databasePath = try queryParameter(allocator, query, "db");
        const assetType = try queryParameter(allocator, query, "type");

        if (assetId == null or databasePath == null or assetType == null or assetId.?.len == 0 or databasePath.?.len == 0 or assetType.?.len == 0) {
            return self.sendHtmlText(request, .bad_request, "Missing id, db, or type query parameter.");
        }

        // `req.headers["content-type"] && parseInt(req.headers["content-length"]) || undefined`: a length of 0 is no length.
        const announcedLength: ?u64 = if (contentType != null and contentLength != null and contentLength.? != 0) contentLength else null;

        const body_buffer = try allocator.alloc(u8, 16 * 1024);
        const body = request.readerExpectContinue(body_buffer) catch |err| {
            return err;
        };
        self.core.writeAsset(allocator, io, assetId.?, assetType.?, databasePath.?, contentType, body, announcedLength) catch |err| {
            log.exception(try std.fmt.allocPrint(allocator, "Error storing asset {s} ({s})", .{ assetId.?, assetType.? }), err);
            var message = errors.errorMessage(err);
            if (message.len == 0) {
                message = "Error storing asset";
            }
            return self.sendHtmlText(request, .internal_server_error, message);
        };
        return self.sendNoContent(request);
    }

    //
    // POST /apply-database-ops — applies metadata changes to one or more on-disk databases (BSON collections).
    // Used by the gallery UI to persist set / push / pull operations via the same local server as /asset.
    //
    // Request body: JSON { ops: IDatabaseOp[] } where each op targets a database path (databaseId), collection, record id, and operation.
    // Responses: 400 if ops is missing or not an array; 204 on success; 500 if applying ops fails.
    //
    fn postApplyDatabaseOps(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, contentType: ?[]const u8) !void {
        // What `express.json()` does before the handler: it reads a JSON body of at most 100kb, and leaves the body undefined for
        // a request that does not say it holds JSON.
        const has_body = request.head.method.requestHasBody() and (request.head.content_length != null or request.head.transfer_encoding != .none);
        var parsed: ?std.json.Value = null;
        if (has_body and isJsonType(contentType)) {
            const body_buffer = try allocator.alloc(u8, 16 * 1024);
            const body = request.readerExpectContinue(body_buffer) catch |err| {
                return err;
            };
            const text = body.allocRemaining(allocator, .limited(JSON_BODY_LIMIT)) catch |err| switch (err) {
                error.StreamTooLong => return self.sendErrorPage(request, .payload_too_large, "request entity too large"),
                else => return err,
            };
            parsed = parseJsonBody(allocator, text) catch {
                return self.sendErrorPage(request, .bad_request, "Unexpected token in JSON");
            };
        }

        // `body.ops` of an undefined body is a TypeError, which Express answers with a 500.
        const body_value = parsed orelse {
            return self.sendErrorPage(request, .internal_server_error, "TypeError: Cannot read properties of undefined (reading 'ops')");
        };
        const ops_value: ?std.json.Value = switch (body_value) {
            .object => |object| object.get("ops"),
            else => null,
        };
        if (ops_value == null or ops_value.? != .array) {
            return self.sendHtmlText(request, .bad_request, "Request body must be a JSON object with an \"ops\" array.");
        }

        self.applyOps(allocator, io, ops_value.?.array.items) catch |err| {
            log.exception("Error applying database ops", err);
            var message = errors.errorMessage(err);
            if (message.len == 0) {
                message = "Error applying database ops";
            }
            return self.sendHtmlText(request, .internal_server_error, message);
        };
        return self.sendNoContent(request);
    }

    //
    // Reads the operations the page sent and has the core apply them.
    // (No TypeScript counterpart: the operations are already typed in TypeScript.)
    //
    fn applyOps(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, items: []const std.json.Value) !void {
        const ops = try allocator.alloc(IDatabaseOp, items.len);
        for (items, ops) |item, *op| {
            op.* = try api.database_op.databaseOpFromJson(item);
        }
        try self.core.applyDatabaseOps(allocator, io, ops);
    }

    //
    // The headers of a response: its content type and, when the routes add them, the CORS headers.
    //
    fn responseHeaders(self: *AssetServerRoutes, buffer: *[1 + cors_headers.len]std.http.Header, contentType: []const u8) []const std.http.Header {
        buffer[0] = .{ .name = "Content-Type", .value = contentType };
        if (!self.enableCors) {
            return buffer[0..1];
        }
        @memcpy(buffer[1..], &cors_headers);
        return buffer[0..];
    }

    //
    // Sends a response with a body, and closes the connection.
    //
    fn send(self: *AssetServerRoutes, request: *std.http.Server.Request, status: std.http.Status, contentType: []const u8, body: []const u8) !void {
        var buffer: [1 + cors_headers.len]std.http.Header = undefined;
        try request.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = self.responseHeaders(&buffer, contentType),
        });
    }

    //
    // `res.status(code).send(text)`.
    //
    fn sendHtmlText(self: *AssetServerRoutes, request: *std.http.Server.Request, status: std.http.Status, text: []const u8) !void {
        return self.send(request, status, "text/html; charset=utf-8", text);
    }

    //
    // The page Express's final handler sends for an error a middleware raised.
    //
    fn sendErrorPage(self: *AssetServerRoutes, request: *std.http.Server.Request, status: std.http.Status, text: []const u8) !void {
        var buffer: [512]u8 = undefined;
        const page = std.fmt.bufPrint(&buffer, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>{s}</pre>\n</body>\n</html>\n", .{text}) catch text;
        return self.send(request, status, "text/html; charset=utf-8", page);
    }

    //
    // `res.status(204).end()`.
    //
    fn sendNoContent(self: *AssetServerRoutes, request: *std.http.Server.Request) !void {
        var buffer: [1 + cors_headers.len]std.http.Header = undefined;
        const all = self.responseHeaders(&buffer, "text/html; charset=utf-8");
        try request.respond("", .{
            .status = .no_content,
            .keep_alive = false,
            .transfer_encoding = .none,
            // A 204 has no body and so no content type.
            .extra_headers = if (self.enableCors) all[1..] else &.{},
        });
    }
};

//
// Attaches the asset server HTTP routes, delegating all work to the transport-agnostic core. The routes are byte-for-byte the same as
// the original asset server: GET /asset, POST /asset, and POST /apply-database-ops. CORS headers are added only when enableCors is
// true (i.e. when the asset server owns the app rather than attaching to an existing one).
// (Zig: returns the routes, for an HTTP server to call; there is no application to attach them to.)
//
pub fn attachAssetServerRoutes(core: IAssetServerCore, enableCors: bool) AssetServerRoutes {
    return .{
        .core = core,
        .enableCors = enableCors,
    };
}

//
// Whether a request path is the route's path, as Express matches it: case-insensitive, and with or without a trailing slash.
// (No TypeScript counterpart: Express does this.)
//
fn pathIs(path: []const u8, route: []const u8) bool {
    var trimmed = path;
    if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return std.ascii.eqlIgnoreCase(trimmed, route);
}

//
// Reads one parameter of a query string, as `req.query` does: the first value of the name, with percent-encoding and `+` decoded.
// Returns null when the name is not there. (No TypeScript counterpart: Express does this.)
//
pub fn queryParameter(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=');
        const key = try decodeQueryComponent(allocator, pair[0 .. equals orelse pair.len]);
        if (!std.mem.eql(u8, key, name)) {
            continue;
        }
        const value = if (equals) |position| pair[position + 1 ..] else "";
        return try decodeQueryComponent(allocator, value);
    }
    return null;
}

//
// Decodes a component of a query string: `+` is a space and `%XX` is a byte. A `%` that does not start two hexadecimal digits is left
// as it is, as Node's querystring does.
//
fn decodeQueryComponent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const character = text[index];
        if (character == '+') {
            try decoded.append(allocator, ' ');
            index += 1;
        }
        else if (character == '%' and index + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[index + 1 .. index + 3], 16)) |byte| {
                try decoded.append(allocator, byte);
                index += 3;
            }
            else |_| {
                try decoded.append(allocator, character);
                index += 1;
            }
        }
        else {
            try decoded.append(allocator, character);
            index += 1;
        }
    }
    return decoded.items;
}

//
// Escapes the characters that matter in the text of an HTML page, as Express's final handler does.
// (No TypeScript counterpart: Express does this.)
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
// Whether a Content-Type says the body is JSON, as `express.json()` decides (`application/json`, `text/json` and the `+json` types).
//
pub fn isJsonType(contentType: ?[]const u8) bool {
    const value = contentType orelse {
        return false;
    };
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const mime = std.mem.trim(u8, value[0..end], " \t");
    return std.ascii.eqlIgnoreCase(mime, "application/json") or std.ascii.eqlIgnoreCase(mime, "text/json") or (mime.len > 5 and std.ascii.eqlIgnoreCase(mime[mime.len - 5 ..], "+json"));
}

//
// Parses a JSON body as `express.json()` does: an empty body is `{}`, and anything that does not start with `{` or `[` is refused
// (its strict mode), as is JSON that does not parse.
//
pub fn parseJsonBody(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    if (text.len == 0) {
        return .{
            .object = .empty,
        };
    }
    const first = for (text) |character| {
        if (character != ' ' and character != '\t' and character != '\n' and character != '\r') {
            break character;
        }
    } else 0;
    if (first != '{' and first != '[') {
        return error.InvalidJson;
    }
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch {
        return error.InvalidJson;
    };
}

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const asset_server_core = @import("asset-server-core.zig");
const http_server = node_utils.http_server;
const IAssetServerCore = asset_server_core.IAssetServerCore;
const IDatabaseOp = api.database_op.IDatabaseOp;
const errors = utils.errors;

//
// The largest JSON body POST /apply-database-ops reads, in bytes: the default limit of `express.json()`, which is "100kb".
//
const JSON_BODY_LIMIT = 100 * 1024;

//
// The CORS headers sent on every response when it owns the application (any origin may call, since the page's origin
// is `ziggy-app://app` or `https://ziggy-app.invalid` and never `file://`).
//
const cors_headers = [_]std.http.Header{
    .{
        .name = "Access-Control-Allow-Origin",
        .value = "*",
    },
    .{
        .name = "Access-Control-Allow-Methods",
        .value = "GET, POST, PUT, DELETE, OPTIONS",
    },
    .{
        .name = "Access-Control-Allow-Headers",
        .value = "Origin, X-Requested-With, Content-Type, Accept",
    },
};

//
// The routes of the asset server, delegating all work to the transport-agnostic core. The routes are:
// GET /asset, POST /asset, and POST /apply-database-ops. CORS headers are added only when enableCors is true
// (i.e. when the asset server owns the application rather than attaching to an existing one).
// (Zig: there is no express application to attach routes to, so the routes are a value that answers the requests an HTTP server hands
// it, in the order express would try them.)
//
pub const AssetServerRoutes = struct {
    // The core that does the work, or null for a server whose connection threads each keep one of their own (their state is an
    // AssetServerCore).
    core: ?IAssetServerCore,

    // Whether to add the CORS headers.
    enableCors: bool,

    //
    // The routes, for the HTTP framework (node_utils.http_server). The routes must stay where they are while the server runs.
    //
    pub fn router(self: *AssetServerRoutes) http_server.Router {
        return routerOf(self);
    }

    //
    // The routes of a constant, for a server whose connection threads all read the same routes, which nothing changes.
    //
    pub fn routerOf(self: *const AssetServerRoutes) http_server.Router {
        return .{
            .context = @constCast(self),
            .routes = &route_table,
            .before = beforeRoutes,
            .notFound = notFound,
        };
    }

    //
    // GET /asset, POST /asset and POST /apply-database-ops. HEAD is answered as GET.
    //
    const route_table = [_]http_server.Route{
        .{
            .method = .GET,
            .path = "/asset",
            .handle = getAssetRoute,
        },
        .{
            .method = .HEAD,
            .path = "/asset",
            .handle = getAssetRoute,
        },
        .{
            .method = .POST,
            .path = "/asset",
            .handle = postAssetRoute,
        },
        .{
            .method = .POST,
            .path = "/apply-database-ops",
            .handle = postApplyDatabaseOpsRoute,
        },
    };

    //
    // The routes a handler's context points at.
    //
    fn of(context: ?*anyopaque) *AssetServerRoutes {
        return @ptrCast(@alignCast(context.?));
    }

    //
    // The core for a request: the routes' one, or the connection thread's own when the routes have none.
    //
    fn coreFor(self: *AssetServerRoutes, request: *http_server.Request) IAssetServerCore {
        if (self.core) |core| {
            return core;
        }
        const own: *asset_server_core.AssetServerCore = @ptrCast(@alignCast(request.state.?));
        return own.assetServerCore();
    }

    //
    // The CORS middleware, before the routes: an OPTIONS request is answered with 200 when this server owns the application.
    //
    fn beforeRoutes(context: ?*anyopaque, request: *http_server.Request, _: std.Io, _: ILog, _: std.mem.Allocator, _: std.mem.Allocator) anyerror!bool {
        const self = of(context);
        if (self.enableCors and request.method == .OPTIONS) {
            try self.send(request.http, .ok, "text/plain; charset=utf-8", "OK");
            return true;
        }
        return false;
    }

    //
    // What express answers when no route matches: OPTIONS for a path that has routes lists the methods they answer, and anything
    // else is a 404.
    //
    fn notFound(context: ?*anyopaque, request: *http_server.Request, _: std.Io, _: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        const self = of(context);
        if (request.method == .OPTIONS) {
            if (http_server.pathIs(request.path, "/asset")) {
                return sendAllowed(request.http, "GET, HEAD, POST");
            }
            if (http_server.pathIs(request.path, "/apply-database-ops")) {
                return sendAllowed(request.http, "POST");
            }
        }
        const message = try std.fmt.allocPrint(allocator, "Cannot {s} {s}", .{ @tagName(request.method), try escapeHtml(allocator, request.path) });
        return self.sendErrorPage(allocator, request.http, .not_found, message);
    }

    //
    // GET /asset and HEAD /asset.
    //
    fn getAssetRoute(context: ?*anyopaque, request: *http_server.Request, io: std.Io, log: ILog, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator) anyerror!void {
        const self = of(context);
        return self.getAsset(allocator, thread_arena, io, log, self.coreFor(request), request.http, request.query);
    }

    //
    // POST /asset.
    //
    fn postAssetRoute(context: ?*anyopaque, request: *http_server.Request, io: std.Io, log: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        const self = of(context);
        return self.postAsset(allocator, io, log, self.coreFor(request), request.http, request.query, request.contentType, request.contentLength);
    }

    //
    // POST /apply-database-ops.
    //
    fn postApplyDatabaseOpsRoute(context: ?*anyopaque, request: *http_server.Request, io: std.Io, log: ILog, allocator: std.mem.Allocator, _: std.mem.Allocator) anyerror!void {
        const self = of(context);
        return self.postApplyDatabaseOps(allocator, io, log, self.coreFor(request), request.http, request.contentType);
    }

    //
    // Handle HTTP GET requests for assets.
    // (Zig: the route has `express.json()` before it, which reads a JSON body sent with a GET. The standard library's HTTP server
    // does not give the body of a GET to read, so a body sent with a GET is ignored.)
    //
    fn getAsset(self: *AssetServerRoutes, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator, io: std.Io, log: ILog, core: IAssetServerCore, request: *std.http.Server.Request, query: []const u8) !void {
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
        // with the 500 (the headers are not sent until the first byte is written).
        const assetStream = core.serveAsset(allocator, thread_arena, io, log, assetId.?, assetType.?, databasePath.?) catch |err| {
            return self.failedToLoadAsset(log, allocator, request, assetId.?, err);
        };
        defer assetStream.destroy(io);
        const reader = assetStream.reader();
        _ = reader.peek(1) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return self.failedToLoadAsset(log, allocator, request, assetId.?, err),
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
    fn failedToLoadAsset(self: *AssetServerRoutes, log: ILog, allocator: std.mem.Allocator, request: *std.http.Server.Request, assetId: []const u8, err: anyerror) !void {
        log.exception(try std.fmt.allocPrint(allocator, "Error loading asset {s}", .{assetId}), err);
        return self.sendHtmlText(request, .internal_server_error, "Error loading asset");
    }

    //
    // POST /asset — writes raw bytes for one asset variant (thumb | display | asset) into a database directory.
    // Same query params as GET: id, type, db. Body: raw bytes. Content-Type: MIME of the blob.
    // Used when moving/copying assets between databases (gallery) so file data matches metadata applied via apply-database-ops.
    //
    fn postAsset(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, log: ILog, core: IAssetServerCore, request: *std.http.Server.Request, query: []const u8, contentType: ?[]const u8, contentLength: ?u64) !void {
        const assetId = try queryParameter(allocator, query, "id");
        const databasePath = try queryParameter(allocator, query, "db");
        const assetType = try queryParameter(allocator, query, "type");

        if (assetId == null or databasePath == null or assetType == null or assetId.?.len == 0 or databasePath.?.len == 0 or assetType.?.len == 0) {
            return self.sendHtmlText(request, .bad_request, "Missing id, db, or type query parameter.");
        }

        // A length of 0 is no length.
        const announcedLength: ?u64 = if (contentType != null and contentLength != null and contentLength.? != 0) contentLength else null;

        const body_buffer = try allocator.alloc(u8, 16 * 1024);
        const body = try request.readerExpectContinue(body_buffer);
        core.writeAsset(allocator, io, log, assetId.?, assetType.?, databasePath.?, contentType, body, announcedLength) catch |err| {
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
    fn postApplyDatabaseOps(self: *AssetServerRoutes, allocator: std.mem.Allocator, io: std.Io, log: ILog, core: IAssetServerCore, request: *std.http.Server.Request, contentType: ?[]const u8) !void {
        // Reads a JSON body of at most 100kb, and leaves the body undefined for
        // a request that does not say it holds JSON.
        const has_body = request.head.method.requestHasBody() and (request.head.content_length != null or request.head.transfer_encoding != .none);
        var parsed: ?std.json.Value = null;
        if (has_body and isJsonType(contentType)) {
            const body_buffer = try allocator.alloc(u8, 16 * 1024);
            const body = try request.readerExpectContinue(body_buffer);
            const text = body.allocRemaining(allocator, .limited(JSON_BODY_LIMIT)) catch |err| switch (err) {
                error.StreamTooLong => return self.sendErrorPage(allocator, request, .payload_too_large, "request entity too large"),
                else => return err,
            };
            parsed = parseJsonBody(allocator, text) catch {
                return self.sendErrorPage(allocator, request, .bad_request, "Unexpected token in JSON");
            };
        }

        // A request without a JSON body is answered with a 500.
        const body_value = parsed orelse {
            return self.sendErrorPage(allocator, request, .internal_server_error, "TypeError: Cannot read properties of undefined (reading 'ops')");
        };
        const ops_value: ?std.json.Value = switch (body_value) {
            .object => |object| object.get("ops"),
            else => null,
        };
        if (ops_value == null or ops_value.? != .array) {
            return self.sendHtmlText(request, .bad_request, "Request body must be a JSON object with an \"ops\" array.");
        }

        applyOps(allocator, io, log, core, ops_value.?.array.items) catch |err| {
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
    //
    fn applyOps(allocator: std.mem.Allocator, io: std.Io, log: ILog, core: IAssetServerCore, items: []const std.json.Value) !void {
        const ops = try allocator.alloc(IDatabaseOp, items.len);
        for (items, ops) |item, *op| {
            op.* = try api.database_op.databaseOpFromJson(item);
        }
        try core.applyDatabaseOps(allocator, io, log, ops);
    }

    //
    // The headers of a response: its content type and, when the routes add them, the CORS headers.
    //
    fn responseHeaders(self: *AssetServerRoutes, buffer: *[1 + cors_headers.len]std.http.Header, contentType: []const u8) []const std.http.Header {
        buffer[0] = .{
            .name = "Content-Type",
            .value = contentType,
        };
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
    // The page sent for an error raised while handling a request.
    // (Zig: the page holds the error's name and message only, with no stack.)
    //
    fn sendErrorPage(self: *AssetServerRoutes, allocator: std.mem.Allocator, request: *std.http.Server.Request, status: std.http.Status, text: []const u8) !void {
        const page = try std.fmt.allocPrint(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>{s}</pre>\n</body>\n</html>\n", .{text});
        var buffer: [3 + cors_headers.len]std.http.Header = undefined;
        buffer[0] = .{
            .name = "Content-Type",
            .value = "text/html; charset=utf-8",
        };
        buffer[1] = .{
            .name = "Content-Security-Policy",
            .value = "default-src 'none'",
        };
        buffer[2] = .{
            .name = "X-Content-Type-Options",
            .value = "nosniff",
        };
        var count: usize = 3;
        if (self.enableCors) {
            @memcpy(buffer[count..], &cors_headers);
            count += cors_headers.len;
        }
        try request.respond(page, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = buffer[0..count],
        });
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
// Answers OPTIONS for a path that has routes: 200, and the methods the routes answer, in the `Allow`
// header and as the body.
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

//
// Attaches the asset server HTTP routes, delegating all work to the transport-agnostic core. The routes are:
// GET /asset, POST /asset, and POST /apply-database-ops. CORS headers are added only when enableCors is
// true (i.e. when the asset server owns the app rather than attaching to an existing one).
// (Zig: returns the routes, for an HTTP server to call; there is no application to attach them to.)
//
pub fn attachAssetServerRoutes(core: ?IAssetServerCore, enableCors: bool) AssetServerRoutes {
    return .{
        .core = core,
        .enableCors = enableCors,
    };
}

//
// Reads one parameter of a query string: the first value of the name, with percent-encoding and `+` decoded.
// Returns null when the name is not there.
//
pub const queryParameter = http_server.queryParameterOf;

//
// Escapes the characters that matter in the text of an HTML page.
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

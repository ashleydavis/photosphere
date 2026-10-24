const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const HttpServer = node_utils.http_server.HttpServer;
const AssetServerRoutes = node_api.asset_server_routes.AssetServerRoutes;
const json = ziggy.json;
const log = &utils.log.log;

//
// Options for creating the asset server.
// There is no option to attach the routes to an existing application: node-api-zig's AssetServerRoutes holds the routes, and
// this server serves them with the CORS headers, because it owns them.
//
pub const IAssetServerOptions = struct {
    // Port to listen on. 0 lets the operating system assign a free port.
    port: u16,

    // Write-lock owner for apply-database-ops (see acquireWriteLock).
    sessionId: []const u8,
};

//
// The routes the connection thread answers with: a constant, with the CORS headers and no core of its own, so each request is served
// by the connection thread's core.
//
const routes: AssetServerRoutes = node_api.asset_server_routes.attachAssetServerRoutes(null, true);

//
// What the connection thread is told, as JSON text, of which it is given a copy.
//
const IConnectionConfig = struct {
    // Write-lock owner for apply-database-ops.
    sessionId: []const u8,
};

//
// A running asset server, which is what createAssetServer returns.
//
pub const AssetServer = struct {

    // The HTTP server.
    server: *HttpServer,

    // The host the server is bound to.
    host: []const u8,

    // The port the server is bound to (the one the operating system chose, when 0 was asked for).
    port: u16,

    //
    // Stops the server, waiting for its threads, and frees it, with the Io and allocator of the thread that created it.
    //
    pub fn close(self: *AssetServer, io: std.Io, allocator: std.mem.Allocator) void {
        self.server.stop(io, allocator);
        allocator.destroy(self);
    }
};

//
// Creates and starts an asset server on the loopback interface, allocated with the calling thread's allocator.
// The port is not optional, so a server cannot be asked for without one. The connection thread is given copies of the session id
// and of the calling thread's environment, and makes a core of its own with generators of its own (the test ones when NODE_ENV is
// "testing").
//
pub fn createAssetServer(allocator: std.mem.Allocator, io: std.Io, options: IAssetServerOptions) !*AssetServer {
    const asset_server = try allocator.create(AssetServer);
    errdefer allocator.destroy(asset_server);

    // CORS is added because this server owns the routes. It only ever listens on the loopback interface.
    asset_server.* = .{
        .server = undefined,
        .host = "127.0.0.1",
        .port = 0,
    };
    const config = try json.stringify(allocator, IConnectionConfig{
        .sessionId = options.sessionId,
    });
    defer allocator.free(config);

    // Start server. Port 0 is allowed and means "let the OS assign a free port" (read the actual port back from the socket). The
    // server has one connection thread.
    const listener = try node_utils.http_server.open(io, asset_server.host, options.port);
    asset_server.server = try HttpServer.start(io, allocator, listener, .{
        .router = AssetServerRoutes.routerOf(&routes),
        .maxConnectionThreads = 1,
        .connectionState = .{
            .config = config,
            .create = createConnectionCore,
            .destroy = destroyConnectionCore,
        },
        .environment = node_utils.process_env.getEnvironMap(),
    });
    asset_server.port = asset_server.server.port;
    const message = try std.fmt.allocPrint(allocator, "Asset server running on http://localhost:{d}", .{asset_server.port});
    defer allocator.free(message);
    log.info(message);
    return asset_server;
}

//
// Makes the core of the connection thread, on the thread, from its copy of the configuration.
//
fn createConnectionCore(config: []const u8, native_callbacks: ?*const ziggy.core.NativeCallbacks, allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    _ = native_callbacks;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(IConnectionConfig, arena_state.allocator(), config, .{});
    return try node_api.asset_server_core.createOwnAssetServerCore(allocator, parsed.sessionId, null);
}

//
// Frees the core of the connection thread.
//
fn destroyConnectionCore(state: *anyopaque, allocator: std.mem.Allocator) void {
    const core: *node_api.asset_server_core.AssetServerCore = @ptrCast(@alignCast(state));
    core.deinit(allocator);
}

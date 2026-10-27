//
// The asset server the Photosphere App runs: the routes of asset-server-routes.zig served on the loopback address by the HTTP
// framework (node_utils.http_server). It is a server of Photosphere's own, not a task. The main thread opens its socket, so it knows
// the port at once, starts it, and stops it with a message when the app stops. Each connection thread is given its own copy of the
// session id and keeps a core of its own (asset-server-core.zig), with its own cache of database storages, so the threads share
// nothing. A connection thread that needs the phone's keychain asks the main thread for it by message.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const asset_server_core = @import("asset-server-core.zig");
const asset_server_routes = @import("asset-server-routes.zig");
const http_server = node_utils.http_server;
const json = ziggy.json;

//
// The asset server serves local content and must only be reachable from this machine, so it always listens on the loopback address.
//
pub const HOST = "127.0.0.1";

//
// The most connection threads the asset server starts. The page loads thumbnails many at a time, and a browser opens a handful of
// connections to one host at once.
//
pub const MAX_CONNECTION_THREADS = 8;

//
// The routes every connection thread answers with: a constant, with the CORS headers and no core of its own, so each request is served
// by the connection thread's core.
//
const routes: asset_server_routes.AssetServerRoutes = asset_server_routes.attachAssetServerRoutes(null, true);

//
// What the asset server is started with.
//
pub const IAssetServerOptions = struct {
    // Write-lock owner for write/apply operations (see acquireWriteLock).
    sessionId: []const u8,
    // The native app's callbacks, through which a connection thread reads a database's credentials from the native app's keychain (a
    // phone's) itself when the native app has a host request callback, or null for none.
    nativeCallbacks: ?ziggy.core.NativeCallbacks,
};

//
// What each connection thread is told, as JSON text, of which it is given a copy.
//
const IConnectionConfig = struct {
    // Write-lock owner for write/apply operations.
    sessionId: []const u8,
};

//
// A running asset server.
//
pub const AssetServer = struct {
    // The HTTP server.
    server: *http_server.HttpServer,
    // The port the server is listening on.
    port: u16,

    //
    // Starts the asset server on a socket the caller opened with `http_server.open` on HOST, which the server owns from then on. The
    // connection threads are given copies of the session id and of the calling thread's environment, which they read to find the
    // vault that holds a database's credentials.
    //
    pub fn start(allocator: std.mem.Allocator, io: std.Io, log: ILog, listener: http_server.Listener, options: IAssetServerOptions) !*AssetServer {
        const self = try allocator.create(AssetServer);
        errdefer allocator.destroy(self);
        const config = try json.stringify(allocator, IConnectionConfig{
            .sessionId = options.sessionId,
        });
        defer allocator.free(config);
        self.* = .{
            .server = undefined,
            .port = listener.port,
        };
        self.server = try http_server.HttpServer.start(io, allocator, listener, .{
            .router = constantRoutes(),
            .maxConnectionThreads = MAX_CONNECTION_THREADS,
            .connectionState = .{
                .config = config,
                .create = createConnectionCore,
                .destroy = destroyConnectionCore,
            },
            .nativeCallbacks = options.nativeCallbacks,
            .environment = node_utils.process_env.getEnvironMap(),
        });
        var message_buffer: [64]u8 = undefined;
        log.info(std.fmt.bufPrint(&message_buffer, "Asset server listening on http://{s}:{d}", .{ HOST, self.port }) catch unreachable);
        return self;
    }

    //
    // Stops the server, which waits for its threads, and frees it, with the Io and allocator of the thread that started it.
    //
    pub fn stop(self: *AssetServer, io: std.Io, allocator: std.mem.Allocator) void {
        self.server.stop(io, allocator);
        allocator.destroy(self);
    }
};

//
// The router of the constant routes. The routes are never changed, so every connection thread reads the same constant.
//
fn constantRoutes() http_server.Router {
    return asset_server_routes.AssetServerRoutes.routerOf(&routes);
}

//
// Makes the core of one connection thread, on the thread, from its copy of the configuration.
//
fn createConnectionCore(config: []const u8, native_callbacks: ?*const ziggy.core.NativeCallbacks, allocator: std.mem.Allocator, _: std.Io) anyerror!*anyopaque {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(IConnectionConfig, arena_state.allocator(), config, .{});
    return try asset_server_core.createOwnAssetServerCore(allocator, parsed.sessionId, native_callbacks);
}

//
// Frees the core of one connection thread.
//
fn destroyConnectionCore(state: *anyopaque, allocator: std.mem.Allocator) void {
    const core: *asset_server_core.AssetServerCore = @ptrCast(@alignCast(state));
    core.deinit(allocator);
}

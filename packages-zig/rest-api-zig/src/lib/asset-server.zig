const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const HttpServer = node_utils.http_server.HttpServer;
const AssetServerCore = node_api.asset_server_core.AssetServerCore;
const AssetServerRoutes = node_api.asset_server_routes.AssetServerRoutes;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const log = &utils.log.log;

//
// Options for creating the asset server.
// (Zig: there is no `app` option, which attached the routes to an existing Express application. There is no Express application to
// attach to; node-api-zig's AssetServerRoutes is what such an application would be given, and without CORS.)
//
pub const IAssetServerOptions = struct {
    // Port to listen on. 0 lets the operating system assign a free port.
    port: u16,

    // UUID generator to use.
    uuidGenerator: IUuidGenerator,

    // Timestamp provider to use.
    timestampProvider: ITimestampProvider,

    // Write-lock owner for apply-database-ops (see acquireWriteLock).
    sessionId: []const u8,
};

//
// A running asset server, which is what createAssetServer returns (TypeScript: IAssetServerResult, whose `server` is the HTTP server
// and whose `app` is the Express application).
//
pub const AssetServer = struct {
    // Allocates the server and the core. It must be safe to use from many threads.
    allocator: std.mem.Allocator,

    // The transport-agnostic core the routes call.
    core: *AssetServerCore,

    // The routes the HTTP server answers requests with.
    routes: AssetServerRoutes,

    // The HTTP server.
    server: *HttpServer,

    // The host the server is bound to.
    host: []const u8,

    // The port the server is bound to (the one the operating system chose, when 0 was asked for).
    port: u16,

    //
    // Stops the server, waiting for the requests being answered, and frees it.
    //
    pub fn close(self: *AssetServer) void {
        self.server.close();
        const allocator = self.allocator;
        self.core.deinit();
        allocator.destroy(self);
    }
};

//
// Creates and starts an asset server on the loopback interface. The allocator must be safe to use from many threads.
//
pub fn createAssetServer(allocator: std.mem.Allocator, io: std.Io, options: IAssetServerOptions) !*AssetServer {
    // Build the transport-agnostic core that owns the storage cache and serve/write/apply logic.
    const core = try node_api.asset_server_core.createAssetServerCore(allocator, io, .{
        .uuidGenerator = options.uuidGenerator,
        .timestampProvider = options.timestampProvider,
        .sessionId = options.sessionId,
    });
    errdefer core.deinit();

    const asset_server = try allocator.create(AssetServer);
    errdefer allocator.destroy(asset_server);

    // CORS is added because this server owns the routes. It only ever listens on the loopback interface.
    asset_server.* = .{
        .allocator = allocator,
        .core = core,
        .routes = node_api.asset_server_routes.attachAssetServerRoutes(core.assetServerCore(), true),
        .server = undefined,
        .host = "127.0.0.1",
        .port = 0,
    };

    // Start server. Port 0 is allowed and means "let the OS assign a free port" (read the actual port back from the server).
    asset_server.server = try HttpServer.listen(allocator, io, asset_server.host, options.port, asset_server.routes.requestHandler());
    asset_server.port = asset_server.server.port;
    log.info(try std.fmt.allocPrint(allocator, "Asset server running on http://localhost:{d}", .{asset_server.port}));
    return asset_server;
}

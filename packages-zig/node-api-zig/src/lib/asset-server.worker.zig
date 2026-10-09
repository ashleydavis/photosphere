const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const asset_server_core = @import("asset-server-core.zig");
const asset_server_routes = @import("asset-server-routes.zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const HttpServer = node_utils.http_server.HttpServer;
const log = &utils.log.log;

//
// Input data for the long-running asset-server task.
//
pub const IAssetServerTaskData = struct {
    // Port to bind. 0 or omitted lets the OS assign a free loopback port.
    // (Zig: the `= null` default lets std.json parse data that leaves the key out.)
    port: ?u16 = null,
};

//
// Message streamed back (via context.sendMessage) once the server has bound a port and is ready
// to serve. The caller reads `port` to build the restApiUrl (http://<host>:<port>).
//
pub const IAssetServerReadyMessage = struct {
    // Discriminator matched by onTaskMessage("asset-server-ready").
    type: []const u8,

    // The actual bound port (resolved even when port 0 was requested).
    port: u16,

    // The host the server is bound to.
    host: []const u8,
};

//
// Result returned when the asset-server task ends (after it is cancelled).
//
pub const IAssetServerTaskResult = struct {
    // The port the server was bound to.
    port: u16,

    // The host the server was bound to.
    host: []const u8,
};

//
// How often the stay-alive loop re-checks for cancellation while the server runs.
//
const CANCEL_POLL_INTERVAL_MS = 250;

//
// Allocates the core and the server's threads, which use it from many threads at once.
// (No TypeScript counterpart: Node's allocator is thread safe.)
//
const server_allocator = std.heap.smp_allocator;

//
// Long-running asset-server task handler.
//
// It builds the transport-agnostic core, stands up an HTTP server bound to a loopback port,
// reports the chosen port back via `asset-server-ready`, then stays alive until the task is
// cancelled, at which point it closes the server and returns. This is the same serving model used by
// the desktop asset server, run as a background task.
// (Zig: the task data and output are JSON values holding IAssetServerTaskData and IAssetServerTaskResult.)
//
pub fn assetServerHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    // The asset server serves local content and must only be reachable from this machine, so it
    // always binds the loopback interface.
    const host = "127.0.0.1";
    const data = try std.json.parseFromValueLeaky(IAssetServerTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    const requestedPort = data.port orelse 0;

    const core = try asset_server_core.createAssetServerCore(server_allocator, io, .{
        .uuidGenerator = context.uuidGenerator,
        .timestampProvider = context.timestampProvider,
        .sessionId = context.sessionId,
    });
    defer core.deinit();

    var routes = asset_server_routes.attachAssetServerRoutes(core.assetServerCore(), true);

    const server = try HttpServer.listen(server_allocator, io, host, requestedPort, routes.requestHandler());
    const boundPort = server.port;
    // The server waits for the requests being answered before it is closed, so nothing it uses is gone while one runs.
    defer server.close();

    log.info(try std.fmt.allocPrint(allocator, "Asset server task listening on http://{s}:{d}", .{ host, boundPort }));

    const readyMessage: IAssetServerReadyMessage = .{
        .type = "asset-server-ready",
        .port = boundPort,
        .host = host,
    };
    context.sendMessage(try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, readyMessage, .{}), .{}));

    // Stay alive until the task is cancelled, then shut the server down.
    while (!context.isCancelled()) {
        try io.sleep(.fromMilliseconds(CANCEL_POLL_INTERVAL_MS), .awake);
    }

    log.info(try std.fmt.allocPrint(allocator, "Asset server task on http://{s}:{d} stopped", .{ host, boundPort }));

    const result: IAssetServerTaskResult = .{
        .port = boundPort,
        .host = host,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, result, .{}), .{});
}

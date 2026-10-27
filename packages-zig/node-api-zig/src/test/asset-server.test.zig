//
// Tests for asset-server.zig.
//
// These serve a real asset from a real database in a directory of its own.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const MemoryLog = @import("utils-zig").memory_log.MemoryLog;
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const http_requests = @import("http-requests.zig");
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const console_capture = @import("console-capture.zig");
const asset_server = node_api.asset_server;
const media_file_database = node_api.media_file_database;
const http_server = node_utils.http_server;
const AssetServer = asset_server.AssetServer;

const io = std.testing.io;

//
// The bytes the database serves for every asset request.
//
const ASSET_BYTES = "hello-asset-bytes";

//
// A database with one asset in it.
//
fn makeDatabase(fixture: *DatabaseFixture, log: ILog, allocator: std.mem.Allocator, name: []const u8) !void {
    try fixture.init(allocator, io, log, name);
    var stream = std.Io.Reader.fixed(ASSET_BYTES);
    try media_file_database.writeAssetStream(allocator, io, log, fixture.database.assetStorage, fixture.rawStorage, "putter", "asset-1", "thumb", "image/jpeg", &stream, ASSET_BYTES.len);
}

//
// The target of a GET /asset request for the asset, in the database at the path.
//
fn assetTarget(allocator: std.mem.Allocator, databasePath: []const u8, assetId: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/asset?id={s}&type=thumb&db={s}", .{ assetId, try encodeComponent(allocator, databasePath) });
}

//
// Percent-encodes a path for a query string.
//
fn encodeComponent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    for (text) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.') {
            try encoded.append(allocator, character);
        }
        else {
            try encoded.print(allocator, "%{X:0>2}", .{character});
        }
    }
    return encoded.items;
}

//
// Starts an asset server on a free port of the loopback address.
//
fn startServer(log: ILog) !*AssetServer {
    const listener = try http_server.open(io, asset_server.HOST, 0);
    return AssetServer.start(std.testing.allocator, io, log, listener, .{
        .sessionId = "test-session",
        .nativeCallbacks = null,
    });
}

test "the asset server serves GET /asset from a database on its port, and no longer once it is stopped" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database: DatabaseFixture = undefined;
    try makeDatabase(&database, log, allocator, "asset-server-serve");
    defer database.deinit(io, log);
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console_capture.endConsoleCapture();

    const server = try startServer(log);
    const port = server.port;
    try std.testing.expect(port > 0);

    const reply = try http_requests.send(allocator, io, .GET, port, try assetTarget(allocator, database.dir, "asset-1"), .{
        .contentType = null,
        .payload = null,
    });
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings(ASSET_BYTES, reply.body);

    server.stop(io, std.testing.allocator);

    // The server is closed, so a request to the (now released) port fails to connect.
    try std.testing.expect(std.meta.isError(http_requests.send(allocator, io, .GET, port, try assetTarget(allocator, database.dir, "asset-1"), .{
        .contentType = null,
        .payload = null,
    })));
}

test "the asset server answers 400 when the id parameter is missing" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console_capture.endConsoleCapture();

    const server = try startServer(log);
    defer server.stop(io, std.testing.allocator);

    const reply = try http_requests.send(allocator, io, .GET, server.port, "/asset?type=thumb&db=%2Fdb%2Fpath", .{
        .contentType = null,
        .payload = null,
    });
    try std.testing.expectEqual(@as(u16, 400), reply.status);
}

test "the asset server logs the address it is listening on" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const server = try startServer(memory.log);
    const port = server.port;
    server.stop(io, std.testing.allocator);

    const listening = try std.fmt.allocPrint(allocator, "Asset server listening on http://127.0.0.1:{d}", .{port});
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), listening) != null);
}

test "the asset server listens on the port its socket was opened on" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console_capture.endConsoleCapture();
    // A free port: bind one, note it, release it.
    const probe = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var probe_listener = try probe.listen(io, .{});
    const freePort = probe_listener.socket.address.getPort();
    probe_listener.deinit(io);

    const listener = try http_server.open(io, asset_server.HOST, freePort);
    const server = try AssetServer.start(std.testing.allocator, io, log, listener, .{
        .sessionId = "test-session",
        .nativeCallbacks = null,
    });
    defer server.stop(io, std.testing.allocator);

    try std.testing.expectEqual(freePort, server.port);
    const reply = try http_requests.send(allocator, io, .GET, freePort, "/asset?type=thumb&db=%2Fdb%2Fpath", .{
        .contentType = null,
        .payload = null,
    });
    try std.testing.expectEqual(@as(u16, 400), reply.status);
}

//
// Tests for asset-server-routes.zig. These run the routes against a fake core, over a real
// HTTP server on the loopback interface, and look at what the core was asked and what the client was answered.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const http_requests = @import("http-requests.zig");
const asset_server_core = node_api.asset_server_core;
const asset_server_routes = node_api.asset_server_routes;
const IAssetServerCore = asset_server_core.IAssetServerCore;
const IReadStream = storage_zig.storage.IReadStream;
const IDatabaseOp = api.database_op.IDatabaseOp;
const HttpServer = node_utils.http_server.HttpServer;

const io = std.testing.io;

//
// A stream over bytes held in memory.
//
const BytesStream = struct {
    // The reader over the bytes.
    reader: std.Io.Reader,

    //
    // The reader over the bytes.
    //
    fn readerFunction(ptr: *anyopaque) *std.Io.Reader {
        const self: *BytesStream = @ptrCast(@alignCast(ptr));
        return &self.reader;
    }

    //
    // Frees the stream.
    //
    fn destroyFunction(ptr: *anyopaque, streamIo: std.Io) void {
        _ = streamIo;
        const self: *BytesStream = @ptrCast(@alignCast(ptr));
        std.heap.smp_allocator.destroy(self);
    }

    //
    // The functions of the stream.
    //
    const vtable: IReadStream.VTable = .{
        .reader = readerFunction,
        .destroy = destroyFunction,
    };
};

//
// A stand-in for the core: it answers from what the test set, and remembers what it was asked. It is used by one request at a time.
//
const FakeCore = struct {
    // The bytes serveAsset streams.
    assetBytes: []const u8 = "hello-asset-bytes",

    // What serveAsset fails with, when set.
    serveError: ?anyerror = null,

    // What writeAsset fails with, when set.
    writeError: ?anyerror = null,

    // What applyDatabaseOps fails with, when set.
    applyError: ?anyerror = null,

    // The last serveAsset arguments, as "id|type|db", and how often it was called.
    served: [256]u8 = undefined,
    servedLength: usize = 0,
    serveCalls: u32 = 0,

    // The last writeAsset arguments, as "id|type|db|contentType|length", the body it was given, and how often it was called.
    written: [256]u8 = undefined,
    writtenLength: usize = 0,
    writtenBody: [128 * 1024]u8 = undefined,
    writtenBodyLength: usize = 0,
    writeCalls: u32 = 0,

    // The number of ops the last applyDatabaseOps was given, the record id of the first, and how often it was called.
    appliedCount: usize = 0,
    appliedFirst: [128]u8 = undefined,
    appliedFirstLength: usize = 0,
    applyCalls: u32 = 0,

    //
    // Gets the interface the routes are given.
    //
    fn core(self: *FakeCore) IAssetServerCore {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The functions of the fake core.
    //
    const vtable: IAssetServerCore.VTable = .{
        .serveAsset = serveAsset,
        .writeAsset = writeAsset,
        .applyDatabaseOps = applyDatabaseOps,
    };

    //
    // Remembers what it was asked and streams the bytes the test set, or fails with the error it set.
    //
    fn serveAsset(ptr: *anyopaque, allocator: std.mem.Allocator, streamIo: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream {
        _ = allocator;
        _ = streamIo;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.serveCalls += 1;
        self.servedLength = (try std.fmt.bufPrint(&self.served, "{s}|{s}|{s}", .{ assetId, assetType, databasePath })).len;
        if (self.serveError) |err| {
            return err;
        }
        const stream = try std.heap.smp_allocator.create(BytesStream);
        stream.* = .{
            .reader = std.Io.Reader.fixed(self.assetBytes),
        };
        return .{
            .ptr = stream,
            .vtable = &BytesStream.vtable,
        };
    }

    //
    // Remembers what it was asked and the body it was given, and fails with the error the test set, if any.
    //
    fn writeAsset(ptr: *anyopaque, allocator: std.mem.Allocator, writeIo: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
        _ = allocator;
        _ = writeIo;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.writeCalls += 1;
        var length_text: [32]u8 = undefined;
        const length = if (contentLength) |value| try std.fmt.bufPrint(&length_text, "{d}", .{value}) else "none";
        self.writtenLength = (try std.fmt.bufPrint(&self.written, "{s}|{s}|{s}|{s}|{s}", .{ assetId, assetType, databasePath, contentType orelse "none", length })).len;
        var body_writer = std.Io.Writer.fixed(&self.writtenBody);
        _ = try inputStream.streamRemaining(&body_writer);
        self.writtenBodyLength = body_writer.end;
        if (self.writeError) |err| {
            return err;
        }
    }

    //
    // Remembers how many ops it was given and the record id of the first, and fails with the error the test set, if any.
    //
    fn applyDatabaseOps(ptr: *anyopaque, allocator: std.mem.Allocator, applyIo: std.Io, ops: []const IDatabaseOp) anyerror!void {
        _ = allocator;
        _ = applyIo;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.applyCalls += 1;
        self.appliedCount = ops.len;
        if (ops.len > 0) {
            self.appliedFirstLength = (try std.fmt.bufPrint(&self.appliedFirst, "{s}", .{ops[0].recordId})).len;
        }
        if (self.applyError) |err| {
            return err;
        }
    }
};

//
// A server running the routes over a fake core.
//
const Fixture = struct {
    // The fake core.
    fake: FakeCore,

    // The routes.
    routes: asset_server_routes.AssetServerRoutes,

    // The HTTP server.
    server: *HttpServer,

    //
    // Starts the server.
    //
    fn start(fixture: *Fixture, enableCors: bool) !void {
        fixture.fake = .{};
        fixture.routes = asset_server_routes.attachAssetServerRoutes(fixture.fake.core(), enableCors);
        fixture.server = try HttpServer.listen(std.heap.smp_allocator, io, "127.0.0.1", 0, fixture.routes.requestHandler());
    }

    //
    // Stops the server.
    //
    fn stop(fixture: *Fixture) void {
        fixture.server.close();
    }

    //
    // Sends a request without a body.
    //
    fn get(fixture: *Fixture, allocator: std.mem.Allocator, method: std.http.Method, target: []const u8) !http_requests.Reply {
        return http_requests.send(allocator, io, method, fixture.server.port, target, .{
            .contentType = null,
            .payload = null,
        });
    }

    //
    // Sends a POST with a body.
    //
    fn post(fixture: *Fixture, allocator: std.mem.Allocator, target: []const u8, contentType: ?[]const u8, payload: []const u8) !http_requests.Reply {
        return http_requests.send(allocator, io, .POST, fixture.server.port, target, .{
            .contentType = contentType,
            .payload = payload,
        });
    }
};

//
// Runs a test body against a started fixture, with an arena and the log's stderr captured, so that a passing test writes nothing.
//
const Run = struct {
    // The arena for the test.
    arena: std.heap.ArenaAllocator,

    // The fixture.
    fixture: Fixture,

    // What the code under test wrote to standard error.
    stderr: std.Io.Writer.Allocating,

    //
    // Captures the log, and starts the server.
    //
    fn start(run: *Run, enableCors: bool) !void {
        run.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        run.stderr = std.Io.Writer.Allocating.init(std.heap.smp_allocator);
        utils.console.setCapture(null, &run.stderr.writer);
        try run.fixture.start(enableCors);
    }

    //
    // Stops the server and frees what the run held.
    //
    fn stop(run: *Run) void {
        run.fixture.stop();
        utils.console.setCapture(null, null);
        run.stderr.deinit();
        run.arena.deinit();
    }
};

test "GET /asset serves the bytes the core streams as application/octet-stream and gives the core the id, type and database" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=asset-1&type=thumb&db=%2Fdb%2Fpath");

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("application/octet-stream", reply.contentType.?);
    try std.testing.expectEqualStrings("hello-asset-bytes", reply.body);
    try std.testing.expectEqualStrings("asset-1|thumb|/db/path", run.fixture.fake.served[0..run.fixture.fake.servedLength]);
}

test "GET /asset serves an empty asset as an empty body" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();
    run.fixture.fake.assetBytes = "";

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=a&type=thumb&db=%2Fdb");

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
}

test "GET /asset returns 400 when the id parameter is missing" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/asset?type=thumb&db=%2Fdb%2Fpath");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings("Missing 'id' parameter", reply.body);
    try std.testing.expectEqual(@as(u32, 0), run.fixture.fake.serveCalls);
}

test "GET /asset returns 400 when the db parameter is missing" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=a&type=thumb");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings("Missing 'db' parameter", reply.body);
}

test "GET /asset returns 400 when the type parameter is missing" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=a&db=%2Fdb");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings("Missing 'type' parameter", reply.body);
}

test "GET /asset returns 400 for a parameter that is there but empty" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=&type=thumb&db=%2Fdb");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
}

test "GET /asset returns 500 and logs the error when the core cannot load the asset" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();
    run.fixture.fake.serveError = error.FileNotFound;

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=missing&type=thumb&db=%2Fdb");

    try std.testing.expectEqual(@as(u16, 500), reply.status);
    try std.testing.expectEqualStrings("Error loading asset", reply.body);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr.written(), "Error loading asset missing") != null);
}

test "HEAD /asset is answered like GET, without the body" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .HEAD, "/asset?id=a&type=thumb&db=%2Fdb");

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("application/octet-stream", reply.contentType.?);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
}

test "a path is matched ignoring case and a trailing slash" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const upper = try run.fixture.get(allocator, .GET, "/ASSET?id=a&type=thumb&db=%2Fdb");
    const slash = try run.fixture.get(allocator, .GET, "/asset/?id=a&type=thumb&db=%2Fdb");

    try std.testing.expectEqual(@as(u16, 200), upper.status);
    try std.testing.expectEqual(@as(u16, 200), slash.status);
}

test "the query is decoded: percent-encoding and plus" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/asset?id=a%20b&type=thumb&db=C%3A%5Cphotos+one");

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("a b|thumb|C:\\photos one", run.fixture.fake.served[0..run.fixture.fake.servedLength]);
}

test "POST /asset writes the body through the core with the content type and the length, and answers 204" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/asset?id=asset-1&type=display&db=%2Fdb%2Fpath", "image/jpeg", "0123456789");

    try std.testing.expectEqual(@as(u16, 204), reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);
    try std.testing.expectEqualStrings("asset-1|display|/db/path|image/jpeg|10", run.fixture.fake.written[0..run.fixture.fake.writtenLength]);
    try std.testing.expectEqualStrings("0123456789", run.fixture.fake.writtenBody[0..run.fixture.fake.writtenBodyLength]);
}

test "POST /asset passes no length and no content type when the request has no content type" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/asset?id=a&type=thumb&db=%2Fdb", null, "bytes");

    try std.testing.expectEqual(@as(u16, 204), reply.status);
    try std.testing.expectEqualStrings("a|thumb|/db|none|none", run.fixture.fake.written[0..run.fixture.fake.writtenLength]);
    try std.testing.expectEqualStrings("bytes", run.fixture.fake.writtenBody[0..run.fixture.fake.writtenBodyLength]);
}

test "POST /asset passes no length for an empty body" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/asset?id=a&type=thumb&db=%2Fdb", "image/png", "");

    try std.testing.expectEqual(@as(u16, 204), reply.status);
    try std.testing.expectEqualStrings("a|thumb|/db|image/png|none", run.fixture.fake.written[0..run.fixture.fake.writtenLength]);
}

test "POST /asset returns 400 when the id, db or type query parameter is missing" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const noId = try run.fixture.post(allocator, "/asset?type=thumb&db=%2Fdb", "image/png", "x");
    const noDb = try run.fixture.post(allocator, "/asset?id=a&type=thumb", "image/png", "x");
    const noType = try run.fixture.post(allocator, "/asset?id=a&db=%2Fdb", "image/png", "x");

    for ([_]http_requests.Reply{ noId, noDb, noType }) |reply| {
        try std.testing.expectEqual(@as(u16, 400), reply.status);
        try std.testing.expectEqualStrings("Missing id, db, or type query parameter.", reply.body);
    }
    try std.testing.expectEqual(@as(u32, 0), run.fixture.fake.writeCalls);
}

test "POST /asset returns 500 with the error's message and logs it when the core cannot store the asset" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();
    run.fixture.fake.writeError = error.DiskFull;

    const reply = try run.fixture.post(allocator, "/asset?id=a&type=thumb&db=%2Fdb", "image/png", "x");

    try std.testing.expectEqual(@as(u16, 500), reply.status);
    try std.testing.expectEqualStrings("DiskFull", reply.body);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr.written(), "Error storing asset a (thumb)") != null);
}

const SET_OP = "{\"databaseId\":\"/db/a\",\"collectionName\":\"metadata\",\"recordId\":\"asset-1\",\"op\":{\"type\":\"set\",\"fields\":{\"description\":\"x\"}}}";

test "POST /apply-database-ops hands the ops to the core and answers 204" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":[" ++ SET_OP ++ "," ++ SET_OP ++ "]}");

    try std.testing.expectEqual(@as(u16, 204), reply.status);
    try std.testing.expectEqual(@as(u32, 1), run.fixture.fake.applyCalls);
    try std.testing.expectEqual(@as(usize, 2), run.fixture.fake.appliedCount);
    try std.testing.expectEqualStrings("asset-1", run.fixture.fake.appliedFirst[0..run.fixture.fake.appliedFirstLength]);
}

test "POST /apply-database-ops reads a JSON body with a charset and a +json type" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const charset = try run.fixture.post(allocator, "/apply-database-ops", "application/json; charset=utf-8", "{\"ops\":[]}");
    const suffix = try run.fixture.post(allocator, "/apply-database-ops", "application/vnd.photosphere+json", "{\"ops\":[]}");

    try std.testing.expectEqual(@as(u16, 204), charset.status);
    try std.testing.expectEqual(@as(u16, 204), suffix.status);
}

test "POST /apply-database-ops returns 400 when ops is missing" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{}");

    try std.testing.expectEqual(@as(u16, 400), reply.status);
    try std.testing.expectEqualStrings("Request body must be a JSON object with an \"ops\" array.", reply.body);
    try std.testing.expectEqual(@as(u32, 0), run.fixture.fake.applyCalls);
}

test "POST /apply-database-ops returns 400 when ops is not an array, or the body is empty" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const notArray = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":\"nope\"}");
    const empty = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "");
    const array = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "[]");

    try std.testing.expectEqual(@as(u16, 400), notArray.status);
    try std.testing.expectEqual(@as(u16, 400), empty.status);
    try std.testing.expectEqual(@as(u16, 400), array.status);
}

test "POST /apply-database-ops returns 400 for JSON that does not parse or is not an object or an array" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const broken = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":[");
    const primitive = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "\"ops\"");

    try std.testing.expectEqual(@as(u16, 400), broken.status);
    try std.testing.expectEqual(@as(u16, 400), primitive.status);
}

test "POST /apply-database-ops returns 413 for a body of more than 100kb" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();
    const big = try allocator.alloc(u8, 100 * 1024 + 100);
    @memset(big, ' ');
    @memcpy(big[0..10], "{\"ops\":[]}");

    const reply = try run.fixture.post(allocator, "/apply-database-ops", "application/json", big);

    try std.testing.expectEqual(@as(u16, 413), reply.status);
    try std.testing.expectEqual(@as(u32, 0), run.fixture.fake.applyCalls);
}

test "POST /apply-database-ops returns 500 when the body is not declared as JSON, as Express does for an undefined body" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/apply-database-ops", "text/plain", "{\"ops\":[]}");

    try std.testing.expectEqual(@as(u16, 500), reply.status);
    try std.testing.expectEqual(@as(u32, 0), run.fixture.fake.applyCalls);
}

test "POST /apply-database-ops returns 500 with the message when an op is not an op" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":[{\"nonsense\":true}]}");

    try std.testing.expectEqual(@as(u16, 500), reply.status);
    try std.testing.expectEqualStrings("InvalidOp", reply.body);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr.written(), "Error applying database ops") != null);
}

test "POST /apply-database-ops returns 500 with the error's message when the core fails" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();
    run.fixture.fake.applyError = error.WriteLockHeld;

    const reply = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":[" ++ SET_OP ++ "]}");

    try std.testing.expectEqual(@as(u16, 500), reply.status);
    try std.testing.expectEqualStrings("WriteLockHeld", reply.body);
}

// CORS and the other paths

test "every response carries the CORS headers when the routes own the server" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const success = try run.fixture.get(allocator, .GET, "/asset?id=a&type=thumb&db=%2Fdb");
    const failure = try run.fixture.get(allocator, .GET, "/asset");
    const missing = try run.fixture.get(allocator, .GET, "/nothing");
    const noContent = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":[]}");

    for ([_]http_requests.Reply{ success, failure, missing, noContent }) |reply| {
        try std.testing.expectEqualStrings("*", reply.allowOrigin.?);
        try std.testing.expectEqualStrings("GET, POST, PUT, DELETE, OPTIONS", reply.allowMethods.?);
        try std.testing.expectEqualStrings("Origin, X-Requested-With, Content-Type, Accept", reply.allowHeaders.?);
    }
}

test "OPTIONS is answered 200 OK with the CORS headers for any path" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const asset = try run.fixture.get(allocator, .OPTIONS, "/asset");
    const anywhere = try run.fixture.get(allocator, .OPTIONS, "/anywhere/at/all");

    for ([_]http_requests.Reply{ asset, anywhere }) |reply| {
        try std.testing.expectEqual(@as(u16, 200), reply.status);
        try std.testing.expectEqualStrings("OK", reply.body);
        try std.testing.expectEqualStrings("*", reply.allowOrigin.?);
    }
}

test "no CORS headers are added when the routes are attached to a server they do not own, and OPTIONS is answered by the router" {
    var run: Run = undefined;
    try run.start(false);
    defer run.stop();
    const allocator = run.arena.allocator();

    const success = try run.fixture.get(allocator, .GET, "/asset?id=a&type=thumb&db=%2Fdb");
    const options = try run.fixture.get(allocator, .OPTIONS, "/asset");

    try std.testing.expectEqual(@as(u16, 200), success.status);
    try std.testing.expect(success.allowOrigin == null);
    try std.testing.expect(success.allowMethods == null);
    // Express answers OPTIONS itself for a path that has routes.
    try std.testing.expectEqual(@as(u16, 200), options.status);
    try std.testing.expectEqualStrings("GET, HEAD, POST", options.allow.?);
    try std.testing.expectEqualStrings("GET, HEAD, POST", options.body);
    try std.testing.expect(options.allowOrigin == null);
}

test "OPTIONS for apply-database-ops lists POST, and OPTIONS for a path that is not a route is a 404, when the routes do not own the server" {
    var run: Run = undefined;
    try run.start(false);
    defer run.stop();
    const allocator = run.arena.allocator();

    const apply = try run.fixture.get(allocator, .OPTIONS, "/apply-database-ops");
    const nothing = try run.fixture.get(allocator, .OPTIONS, "/nothing");

    try std.testing.expectEqual(@as(u16, 200), apply.status);
    try std.testing.expectEqualStrings("POST", apply.allow.?);
    try std.testing.expectEqualStrings("POST", apply.body);
    try std.testing.expectEqualStrings("text/plain", apply.contentType.?);
    try std.testing.expectEqualStrings("nosniff", apply.contentTypeOptions.?);
    try std.testing.expectEqual(@as(u16, 404), nothing.status);
    try std.testing.expect(std.mem.indexOf(u8, nothing.body, "<pre>Cannot OPTIONS /nothing</pre>") != null);
}

test "the pages Express sends for a 404 and for an error carry the content security headers" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const missing = try run.fixture.get(allocator, .GET, "/nothing");
    const unparsable = try run.fixture.post(allocator, "/apply-database-ops", "application/json", "{\"ops\":[");

    for ([_]http_requests.Reply{ missing, unparsable }) |reply| {
        try std.testing.expectEqualStrings("default-src 'none'", reply.contentSecurityPolicy.?);
        try std.testing.expectEqualStrings("nosniff", reply.contentTypeOptions.?);
        try std.testing.expectEqualStrings("text/html; charset=utf-8", reply.contentType.?);
        try std.testing.expectEqualStrings("*", reply.allowOrigin.?);
    }
}

test "a path that is not a route is answered 404 Cannot GET, and so is a route asked with another method" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const missing = try run.fixture.get(allocator, .GET, "/nothing");
    const wrongMethod = try run.fixture.get(allocator, .GET, "/apply-database-ops");
    const putAsset = try run.fixture.post(allocator, "/nothing", "application/json", "{}");

    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "<pre>Cannot GET /nothing</pre>") != null);
    try std.testing.expectEqual(@as(u16, 404), wrongMethod.status);
    try std.testing.expect(std.mem.indexOf(u8, wrongMethod.body, "<pre>Cannot GET /apply-database-ops</pre>") != null);
    try std.testing.expectEqual(@as(u16, 404), putAsset.status);
    try std.testing.expect(std.mem.indexOf(u8, putAsset.body, "<pre>Cannot POST /nothing</pre>") != null);
}

test "a path that is shown in the 404 page is escaped" {
    var run: Run = undefined;
    try run.start(true);
    defer run.stop();
    const allocator = run.arena.allocator();

    const reply = try run.fixture.get(allocator, .GET, "/%3Cscript%3E");

    try std.testing.expectEqual(@as(u16, 404), reply.status);
    try std.testing.expect(std.mem.indexOf(u8, reply.body, "<script>") == null);
}

// The functions the routes are built from

test "queryParameter reads the first value of a name, decoded, and nothing for a name that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("one", (try asset_server_routes.queryParameter(allocator, "a=one&a=two", "a")).?);
    try std.testing.expectEqualStrings("x y", (try asset_server_routes.queryParameter(allocator, "a=x+y", "a")).?);
    try std.testing.expectEqualStrings("/a b", (try asset_server_routes.queryParameter(allocator, "a=%2Fa%20b", "a")).?);
    try std.testing.expectEqualStrings("", (try asset_server_routes.queryParameter(allocator, "a=&b=1", "a")).?);
    try std.testing.expectEqualStrings("", (try asset_server_routes.queryParameter(allocator, "a&b=1", "a")).?);
    try std.testing.expectEqualStrings("100%", (try asset_server_routes.queryParameter(allocator, "a=100%", "a")).?);
    try std.testing.expectEqualStrings("%zz", (try asset_server_routes.queryParameter(allocator, "a=%zz", "a")).?);
    try std.testing.expectEqualStrings("1", (try asset_server_routes.queryParameter(allocator, "a=&b=1", "b")).?);
    try std.testing.expect(try asset_server_routes.queryParameter(allocator, "a=1", "b") == null);
    try std.testing.expect(try asset_server_routes.queryParameter(allocator, "", "a") == null);
}

test "isJsonType accepts the types express.json() accepts and no others" {
    try std.testing.expect(asset_server_routes.isJsonType("application/json"));
    try std.testing.expect(asset_server_routes.isJsonType("Application/JSON; charset=utf-8"));
    try std.testing.expect(asset_server_routes.isJsonType("text/json"));
    try std.testing.expect(asset_server_routes.isJsonType("application/vnd.x+json"));
    try std.testing.expect(!asset_server_routes.isJsonType("text/plain"));
    try std.testing.expect(!asset_server_routes.isJsonType("application/jsonx"));
    try std.testing.expect(!asset_server_routes.isJsonType(null));
}

test "parseJsonBody reads objects and arrays, makes an empty body an empty object, and refuses the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect((try asset_server_routes.parseJsonBody(allocator, "")) == .object);
    try std.testing.expect((try asset_server_routes.parseJsonBody(allocator, "  {\"a\":1}")) == .object);
    try std.testing.expect((try asset_server_routes.parseJsonBody(allocator, "\n[1]")) == .array);
    try std.testing.expectError(error.InvalidJson, asset_server_routes.parseJsonBody(allocator, "\"text\""));
    try std.testing.expectError(error.InvalidJson, asset_server_routes.parseJsonBody(allocator, "42"));
    try std.testing.expectError(error.InvalidJson, asset_server_routes.parseJsonBody(allocator, "{\"a\":"));
}

//
// Tests for asset-server.zig.
//
// These run the real core and routes, which
// is also what the second test needs: that the server answers.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const rest_api = @import("rest-api-zig");

const io = std.testing.io;

//
// Creates a server on the given port with the generators the tests use, capturing what it writes to the console (the test program
// talks to the build over standard output).
//
const Fixture = struct {
    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // Deterministic time.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // What the server wrote to standard output and standard error.
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    //
    // Fills in the fixture.
    //
    fn init(fixture: *Fixture, allocator: std.mem.Allocator) !void {
        fixture.uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
        fixture.timestampProvider = .{};
        fixture.stdout = std.Io.Writer.Allocating.init(allocator);
        fixture.stderr = std.Io.Writer.Allocating.init(allocator);
        utils.console.setCapture(&fixture.stdout.writer, &fixture.stderr.writer);
    }

    //
    // Stops capturing the console.
    //
    fn deinit(fixture: *Fixture) void {
        _ = fixture;
        utils.console.setCapture(null, null);
    }
};

test "createAssetServer binds only to the loopback interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();

    const server = try rest_api.asset_server.createAssetServer(std.heap.smp_allocator, io, .{
        .port = 0,
        .uuidGenerator = fixture.uuidGenerator.uuidGenerator(),
        .timestampProvider = fixture.timestampProvider.timestampProvider(),
        .sessionId = "test-session",
    });
    defer server.close();

    try std.testing.expectEqualStrings("127.0.0.1", server.host);
    const bound = server.server.listener.socket.address;
    try std.testing.expectEqual(@as(u8, 127), bound.ip4.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0), bound.ip4.bytes[1]);
    try std.testing.expectEqual(@as(u8, 0), bound.ip4.bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), bound.ip4.bytes[3]);
    try std.testing.expect(server.port > 0);
    try std.testing.expectEqual(server.port, bound.getPort());
    try std.testing.expect(std.mem.indexOf(u8, fixture.stdout.written(), "Asset server running on http://localhost:") != null);
}

test "createAssetServer listens on the port it is asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();
    // A free port: bind one, note it, release it.
    const probe = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try probe.listen(io, .{});
    const freePort = listener.socket.address.getPort();
    listener.deinit(io);

    const server = try rest_api.asset_server.createAssetServer(std.heap.smp_allocator, io, .{
        .port = freePort,
        .uuidGenerator = fixture.uuidGenerator.uuidGenerator(),
        .timestampProvider = fixture.timestampProvider.timestampProvider(),
        .sessionId = "test-session",
    });
    defer server.close();

    try std.testing.expectEqual(freePort, server.port);
}

test "createAssetServer serves the routes, with CORS headers, and stops answering when it is closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    defer fixture.deinit();
    const server = try rest_api.asset_server.createAssetServer(std.heap.smp_allocator, io, .{
        .port = 0,
        .uuidGenerator = fixture.uuidGenerator.uuidGenerator(),
        .timestampProvider = fixture.timestampProvider.timestampProvider(),
        .sessionId = "test-session",
    });
    const port = server.port;

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(allocator);
    const result = try client.fetch(.{
        .location = .{
            .url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/asset", .{port}),
        },
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    try std.testing.expectEqual(std.http.Status.bad_request, result.status);
    try std.testing.expectEqualStrings("Missing 'id' parameter", body.written());

    server.close();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    try std.testing.expect(std.meta.isError(address.connect(io, .{ .mode = .stream })));
}

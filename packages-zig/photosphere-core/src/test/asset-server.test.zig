const std = @import("std");
const support = @import("test-support.zig");

const expectServerStopped = @import("../../../utils-zig/src/test/expect-server-stopped.zig").expectServerStopped;

const TestApp = support.TestApp;

const io = std.testing.io;

//
// Reads the port out of the page's query, which starts with `restApiUrl=http%3A%2F%2Flocalhost%3A`.
//
fn portOf(query: []const u8) !u16 {
    const prefix = "restApiUrl=http%3A%2F%2Flocalhost%3A";
    try std.testing.expect(std.mem.startsWith(u8, query, prefix));
    const end = std.mem.indexOfScalar(u8, query[prefix.len..], '&') orelse return error.NoSeparator;
    return try std.fmt.parseInt(u16, query[prefix.len .. prefix.len + end], 10);
}

test "the asset server the page's query starts serves the asset routes on a loopback port, and stops with the app" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const query = try app.native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(query);
    const port = try portOf(query);
    try std.testing.expect(port > 0);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(allocator);
    const result = try client.fetch(.{
        .location = .{
            .url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/asset?type=thumb&db=%2Fdb", .{port}),
        },
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    try std.testing.expectEqual(std.http.Status.bad_request, result.status);
    try std.testing.expectEqualStrings("Missing 'id' parameter", body.written());

    // The app stops its asset server as it stops, so nothing of ours listens on the port.
    app.stopCore();
    try expectServerStopped(io, port);
}

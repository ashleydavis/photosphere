const std = @import("std");
const ziggy = @import("ziggy");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;

const expectServerStopped = @import("../../../utils-zig/src/test/expect-server-stopped.zig").expectServerStopped;

const TestApp = support.TestApp;

const io = std.testing.io;

//
// Reads the port out of the asset-server-ready event the task sent.
//
fn readyPort(app: *TestApp, allocator: std.mem.Allocator) !u16 {
    try app.shell.expectMessageContaining("\"data\":{\"type\":\"asset-server-ready\"");
    const index = app.shell.indexOfContaining("\"data\":{\"type\":\"asset-server-ready\"").?;
    const text = try app.shell.messageAt(allocator, index);
    const parsed = try std.json.parseFromSliceLeaky(struct {
        data: struct {
            data: struct {
                port: u16,
                host: []const u8,
            },
        },
    }, allocator, text, .{
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqualStrings("127.0.0.1", parsed.data.data.host);
    return parsed.data.data.port;
}

test "the asset-server task serves the asset routes on a loopback port the page is told, and stops when its source is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    app.core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"asset-server-1\",\"taskType\":\"asset-server\",\"source\":\"asset-server\",\"data\":{\"port\":0},\"priority\":\"background\"}}");
    const port = try readyPort(&app, allocator);
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

    // The main process starts an asset server that ends while the app runs again on the port it had, so the app is marked as
    // stopping first, as it is when it quits. Otherwise the restarted server answers on the port.
    main_state.fromCore(app.core).stopping.store(true, .release);
    app.core.postMessage("{\"kind\":\"system\",\"name\":\"cancel-tasks\",\"data\":\"asset-server\"}");
    try app.shell.expectMessageContaining("\"taskId\":\"asset-server-1\",\"result\":{\"taskId\":\"asset-server-1\",\"status\":\"failed\"");

    // The task is over, so nothing of ours answers on the port.
    try expectServerStopped(io, port);
}

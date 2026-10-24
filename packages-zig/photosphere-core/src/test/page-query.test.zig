const std = @import("std");
const support = @import("test-support.zig");
const page_query = @import("photosphere-core").page_query;

const TestApp = support.TestApp;

const io = std.testing.io;

//
// Reads the port out of a query that starts with `restApiUrl=http%3A%2F%2Flocalhost%3A`, the address as encodeURIComponent writes it.
//
fn portOf(query: []const u8) !u16 {
    const prefix = "restApiUrl=http%3A%2F%2Flocalhost%3A";
    try std.testing.expect(std.mem.startsWith(u8, query, prefix));
    const end = std.mem.indexOfScalar(u8, query[prefix.len..], '&') orelse return error.NoSeparator;
    return try std.fmt.parseInt(u16, query[prefix.len .. prefix.len + end], 10);
}

//
// Asks the asset server on the port for something it answers without a database and returns the status.
//
fn assetServerStatus(allocator: std.mem.Allocator, port: u16) !std.http.Status {
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
    return result.status;
}

test "the page's query holds the address of a running asset server and the theme" {
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
    try std.testing.expect(std.mem.endsWith(u8, query, "&theme=system"));
    try std.testing.expectEqual(std.http.Status.bad_request, try assetServerStatus(allocator, port));
}

test "asking for the query again does not start another asset server" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const first = try app.native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(first);
    const first_port = try portOf(first);
    const second = try app.native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(second);

    // A second server would be on a port of its own.
    try std.testing.expectEqual(first_port, try portOf(second));
}

test "the query says the saved theme" {
    var app: TestApp = undefined;
    try app.startWithTasksAndConfigFile(&.{}, "theme: dark\n");
    defer app.stop();

    const query = try app.native_app.uiQuery(std.testing.allocator);
    defer std.testing.allocator.free(query);

    try std.testing.expect(std.mem.endsWith(u8, query, "&theme=dark"));
}

test "test mode adds testMode=1 to the query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const without = try page_query.buildQuery(allocator, 4321, "system", false);
    const with = try page_query.buildQuery(allocator, 4321, "system", true);

    try std.testing.expectEqualStrings("restApiUrl=http%3A%2F%2Flocalhost%3A4321&theme=system", without);
    try std.testing.expectEqualStrings("restApiUrl=http%3A%2F%2Flocalhost%3A4321&theme=system&testMode=1", with);
}

test "a value of the query is written as encodeURIComponent writes it" {
    const allocator = std.testing.allocator;
    const encoded = try page_query.encodeUriComponent(allocator, "a b!*'()~-_.\xc3\xa9&=/:?#%");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b!*'()~-_.%C3%A9%26%3D%2F%3A%3F%23%25", encoded);
}

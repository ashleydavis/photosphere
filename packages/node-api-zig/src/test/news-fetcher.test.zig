const std = @import("std");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const fetchNews = node_api.news_fetcher.fetchNews;

//
// A local HTTP server that answers every request with one status and body (stands in for the mocked fetch).
//
const FeedServer = struct {
    // The io the server runs on.
    io: std.Io,

    // The listening socket.
    server: std.Io.net.Server,

    // The port.
    port: u16,

    // Runs the one connection the server answers.
    group: std.Io.Group,

    // The status of every response.
    status: std.http.Status,

    // The body of every response.
    body: []const u8,

    //
    // Starts the server.
    //
    fn start(self: *FeedServer, io: std.Io, status: std.http.Status, body: []const u8) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .server = try address.listen(io, .{ .reuse_address = true }), .port = 0, .group = .init, .status = status, .body = body };
        self.port = self.server.socket.address.getPort();
        try self.group.concurrent(io, serveOne, .{self});
    }

    //
    // Stops the server once it has answered its one request. Every test makes exactly one request, so
    // this waits for that answer rather than canceling a blocked accept, which on Windows can miss the
    // cancel and never return.
    //
    fn stop(self: *FeedServer) void {
        self.group.await(self.io) catch {};
        self.server.deinit(self.io);
    }

    //
    // Accepts one connection and answers its request.
    //
    fn serveOne(self: *FeedServer) void {
        const stream = self.server.accept(self.io) catch {
            return;
        };
        defer stream.close(self.io);
        var receiveBuffer: [4096]u8 = undefined;
        var sendBuffer: [4096]u8 = undefined;
        var connectionReader = stream.reader(self.io, &receiveBuffer);
        var connectionWriter = stream.writer(self.io, &sendBuffer);
        var httpServer = std.http.Server.init(&connectionReader.interface, &connectionWriter.interface);
        var request = httpServer.receiveHead() catch {
            return;
        };
        request.respond(self.body, .{ .status = self.status, .keep_alive = false }) catch {};
    }

    //
    // The URL of the feed.
    //
    fn url(self: *FeedServer, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/news.yaml", .{self.port});
    }
};

//
// Fetches a feed served with the status and body.
//
fn fetchServed(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) ![]const node_api.news_fetcher.INewsItem {
    var server: FeedServer = undefined;
    try server.start(std.testing.io, status, body);
    defer server.stop();
    return fetchNews(allocator, std.testing.io, try server.url(allocator));
}

test "returns parsed items when the YAML is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try fetchServed(arena.allocator(), .ok,
        \\items:
        \\  - id: a
        \\    message: Hello
        \\  - id: b
        \\    message: World
        \\    color: warning
        \\    duration: 5000
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].id);
    try std.testing.expectEqualStrings("Hello", items[0].message);
    try std.testing.expect(items[0].color == null and items[0].duration == null and items[0].link == null);
    try std.testing.expectEqualStrings("warning", items[1].color.?);
    try std.testing.expectEqual(@as(f64, 5000), items[1].duration.?);
}

test "throws when the YAML is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, fetchServed(arena.allocator(), .ok, "::: not yaml :::\n  bad\n - indent"));
}

test "throws when items is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, fetchServed(arena.allocator(), .ok, "other: stuff\n"));
    try std.testing.expectEqualStrings("Invalid news feed: missing items array", utils.errors.lastErrorMessage());
}

test "throws when an item is missing id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, fetchServed(arena.allocator(), .ok, "items:\n  - message: Hello\n"));
    try std.testing.expectEqualStrings("Invalid news item: missing id", utils.errors.lastErrorMessage());
}

test "throws when an item is missing message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, fetchServed(arena.allocator(), .ok, "items:\n  - id: a\n"));
    try std.testing.expectEqualStrings("Invalid news item: missing message", utils.errors.lastErrorMessage());
}

test "returns an empty array when items is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try fetchServed(arena.allocator(), .ok, "items: []\n")).len);
}

test "throws when the HTTP response is not ok" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, fetchServed(arena.allocator(), .internal_server_error, ""));
    try std.testing.expectEqualStrings("Failed to fetch news feed: HTTP 500", utils.errors.lastErrorMessage());
}

test "reads from disk for file:// URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "news-fetcher");
    defer helpers.removeTempDir(io, dir);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/news feed.yaml", .{dir});
    try helpers.writeFile(io, filePath,
        \\items:
        \\  - id: a
        \\    message: From file
        \\    link:
        \\      label: Open
        \\      url: https://example.com/open
        \\    action:
        \\      label: Go
        \\      url: https://example.com/go
        \\
    );

    // A file URL has forward slashes and a slash before a Windows drive letter ("file:///C:/dir").
    const forwardSlashDir = try allocator.dupe(u8, dir);
    std.mem.replaceScalar(u8, forwardSlashDir, '\\', '/');
    const slashBeforeDrive = if (std.mem.startsWith(u8, forwardSlashDir, "/")) "" else "/";
    const url = try std.fmt.allocPrint(allocator, "file://{s}{s}/news%20feed.yaml", .{ slashBeforeDrive, forwardSlashDir });
    const items = try fetchNews(allocator, io, url);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("From file", items[0].message);
    try std.testing.expectEqualStrings("Open", items[0].link.?.label);
    try std.testing.expectEqualStrings("https://example.com/open", items[0].link.?.url);
    try std.testing.expectEqualStrings("Go", items[0].action.?.label);
    try std.testing.expectEqualStrings("https://example.com/go", items[0].action.?.url);
}

const std = @import("std");
const builtin = @import("builtin");
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

test "a link label that is not a string is printed as a JavaScript template string prints it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "news-fetcher-labels");
    defer helpers.removeTempDir(io, dir);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/feed.yaml", .{dir});
    try helpers.writeFile(io, filePath,
        \\items:
        \\  - id: a
        \\    message: Labels
        \\    link:
        \\      label: 1e21
        \\      url: [1, null, "b"]
        \\
    );
    const forwardSlashPath = try allocator.dupe(u8, filePath);
    std.mem.replaceScalar(u8, forwardSlashPath, '\\', '/');
    const slashBeforeDrive = if (std.mem.startsWith(u8, forwardSlashPath, "/")) "" else "/";
    const items = try fetchNews(allocator, io, try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ slashBeforeDrive, forwardSlashPath }));

    // `${1e21}` is "1e+21", and `${[1, null, "b"]}` is "1,,b".
    try std.testing.expectEqualStrings("1e+21", items[0].link.?.label);
    try std.testing.expectEqualStrings("1,,b", items[0].link.?.url);
}

test "fileURLToPath parses the URL first, as Bun's fileURLToPath does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fileURLToPath = node_api.news_fetcher.fileURLToPath;

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\b\\c", try fileURLToPath(allocator, "file:///C:/a/../b/./c?x=1#y"));
        try std.testing.expectEqualStrings("\\\\server\\share\\f", try fileURLToPath(allocator, "file://server/share/f"));
        try std.testing.expectError(error.Thrown, fileURLToPath(allocator, "file:///C:/a%2Fb"));
        try std.testing.expectEqualStrings("File URL path must not include encoded \\ or / characters", utils.errors.lastErrorMessage());
        return;
    }

    // The query and fragment are not part of the path, and `.` and `..` segments are resolved.
    try std.testing.expectEqualStrings("/b/c", try fileURLToPath(allocator, "file:///a/../b/./c?x=1#y"));
    // "localhost" is no host at all, and a backslash is a slash.
    try std.testing.expectEqualStrings("/a/b", try fileURLToPath(allocator, "file://localhost/a\\b"));
    // Percent-encoded bytes are decoded, and a % that starts no escape is kept.
    try std.testing.expectEqualStrings("/a b/%zz/\u{E9}", try fileURLToPath(allocator, "file:///a%20b/%zz/%C3%A9"));
    // An empty path is the root.
    try std.testing.expectEqualStrings("/", try fileURLToPath(allocator, "file://"));

    try std.testing.expectError(error.Thrown, fileURLToPath(allocator, "file://host/a/b"));
    try std.testing.expectEqualStrings("TypeError", utils.errors.lastErrorName());
    const expectedHostMessage = if (builtin.os.tag == .macos) "File URL host must be \"localhost\" or empty on darwin" else "File URL host must be \"localhost\" or empty on linux";
    try std.testing.expectEqualStrings(expectedHostMessage, utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, fileURLToPath(allocator, "file:///a/%2Fb"));
    try std.testing.expectEqualStrings("File URL path must not include encoded / characters", utils.errors.lastErrorMessage());
}

test "writes the label and url of a link as a template string would" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "news-fetcher-links");
    defer helpers.removeTempDir(io, dir);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/news.yaml", .{dir});
    try helpers.writeFile(io, filePath,
        \\items:
        \\  - id: array-and-float
        \\    message: m
        \\    link:
        \\      label: [a, null, 2]
        \\      url: 1.5e-7
        \\  - id: bool-and-null
        \\    message: m
        \\    link:
        \\      label: true
        \\      url: null
        \\  - id: object-and-missing
        \\    message: m
        \\    link:
        \\      label: { x: 1 }
        \\  - id: not-an-object
        \\    message: m
        \\    link: somewhere
        \\  - id: falsy
        \\    message: m
        \\    link: 0
        \\    action: 0.0
        \\
    );

    const forwardSlashPath = try allocator.dupe(u8, filePath);
    std.mem.replaceScalar(u8, forwardSlashPath, '\\', '/');
    const slashBeforeDrive = if (std.mem.startsWith(u8, forwardSlashPath, "/")) "" else "/";
    const items = try fetchNews(allocator, io, try std.fmt.allocPrint(allocator, "file://{s}{s}", .{ slashBeforeDrive, forwardSlashPath }));

    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqualStrings("a,,2", items[0].link.?.label);
    try std.testing.expectEqualStrings("1.5e-7", items[0].link.?.url);
    try std.testing.expectEqualStrings("true", items[1].link.?.label);
    try std.testing.expectEqualStrings("null", items[1].link.?.url);
    try std.testing.expectEqualStrings("[object Object]", items[2].link.?.label);
    try std.testing.expectEqualStrings("undefined", items[2].link.?.url);
    try std.testing.expectEqualStrings("undefined", items[3].link.?.label);
    try std.testing.expect(items[4].link == null);
    try std.testing.expect(items[4].action == null);
}

// The URL parser drops tabs, newlines and carriage returns before it reads the path.
test "fileURLToPath drops tabs, newlines and carriage returns from the URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // (The path's own separators are those of the platform, so this runs where they are slashes.)
    if (builtin.os.tag == .windows) {
        return;
    }
    try std.testing.expectEqualStrings("/ab/cd", try node_api.news_fetcher.fileURLToPath(allocator, "file:///a\tb/c\nd\r"));
}

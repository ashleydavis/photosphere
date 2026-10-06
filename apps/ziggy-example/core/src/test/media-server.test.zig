const std = @import("std");
const ziggy = @import("ziggy-core");
const example = @import("ziggy-example-core");
const media_server = example.media_server;

const FakeShell = ziggy.fake_shell.FakeShell;

test "parseRange reads a closed range" {
    const range = (try media_server.parseRange("bytes=10-19", 100)).?;
    try std.testing.expectEqual(@as(usize, 10), range.start);
    try std.testing.expectEqual(@as(usize, 19), range.end);
}

test "parseRange reads an open ended range up to the last byte" {
    const range = (try media_server.parseRange("bytes=90-", 100)).?;
    try std.testing.expectEqual(@as(usize, 90), range.start);
    try std.testing.expectEqual(@as(usize, 99), range.end);
}

test "parseRange reads a suffix range as the last bytes" {
    const range = (try media_server.parseRange("bytes=-10", 100)).?;
    try std.testing.expectEqual(@as(usize, 90), range.start);
    try std.testing.expectEqual(@as(usize, 99), range.end);
}

test "parseRange cuts an end past the file to the last byte" {
    const range = (try media_server.parseRange("bytes=50-500", 100)).?;
    try std.testing.expectEqual(@as(usize, 99), range.end);
}

test "parseRange refuses a start past the end of the file" {
    try std.testing.expectError(error.Unsatisfiable, media_server.parseRange("bytes=100-", 100));
}

test "parseRange returns null when the header does not ask for bytes" {
    try std.testing.expectEqual(@as(?media_server.ByteRange, null), try media_server.parseRange("items=1-2", 100));
}

test "findAsset finds the image and the video and ignores a query" {
    try std.testing.expect(media_server.findAsset("/example.png") != null);
    try std.testing.expect(media_server.findAsset("/example.mp4?x=1") != null);
    try std.testing.expect(media_server.findAsset("/missing.png") == null);
}

//
// Fetches a path from the server on the port with an HTTP request, and returns everything the server sent until it closed.
//
fn fetch(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    return try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

//
// Starts the media-server task, waits for its "media-server" message and returns the port in it.
//
fn startServer(shell: *FakeShell, core: *ziggy.core.Core) !u16 {
    core.postMessage("{\"channel\":\"add-task\",\"data\":{\"taskId\":\"media-1\",\"taskType\":\"media-server\",\"source\":\"media\",\"data\":null,\"priority\":0}}");
    try shell.expectMessageContaining("\"type\":\"media-server\"");
    const message = try shell.messageAt(std.testing.allocator, shell.indexOfContaining("\"type\":\"media-server\"").?);
    defer std.testing.allocator.free(message);
    const marker = "\"port\":";
    const start = std.mem.indexOf(u8, message, marker).? + marker.len;
    var end = start;
    while (end < message.len and std.ascii.isDigit(message[end])) {
        end += 1;
    }
    return try std.fmt.parseInt(u16, message[start..end], 10);
}

test "the media server serves the image whole, the video by range, and stops when its source is cancelled" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(2, 2), example.app);
    defer core.destroy();
    const port = try startServer(&shell, core);

    const image = try fetch(std.testing.allocator, port, "GET /example.png HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer std.testing.allocator.free(image);
    try std.testing.expect(std.mem.startsWith(u8, image, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, image, "Content-Type: image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, image, "Access-Control-Allow-Origin: *") != null);
    try std.testing.expect(std.mem.indexOf(u8, image, "\x89PNG") != null);

    const video = try fetch(std.testing.allocator, port, "GET /example.mp4 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\n\r\n");
    defer std.testing.allocator.free(video);
    try std.testing.expect(std.mem.startsWith(u8, video, "HTTP/1.1 206 Partial Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, video, "Content-Range: bytes 0-99/") != null);
    try std.testing.expect(std.mem.indexOf(u8, video, "Content-Length: 100\r\n") != null);

    const missing = try fetch(std.testing.allocator, port, "GET /nothing HTTP/1.1\r\n\r\n");
    defer std.testing.allocator.free(missing);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));

    const beyond = try fetch(std.testing.allocator, port, "GET /example.png HTTP/1.1\r\nRange: bytes=99999999-\r\n\r\n");
    defer std.testing.allocator.free(beyond);
    try std.testing.expect(std.mem.startsWith(u8, beyond, "HTTP/1.1 416 Range Not Satisfiable\r\n"));

    // A client that connects and says nothing, as a browser does, must not keep the server from stopping.
    var idle_threaded: std.Io.Threaded = .init_single_threaded;
    const idle = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", port)).connect(idle_threaded.io(), .{ .mode = .stream });
    defer idle.close(idle_threaded.io());

    core.postMessage("{\"channel\":\"cancel-tasks\",\"data\":{\"source\":\"media\"}}");
    try shell.expectMessageContaining("task-completed");
    try shell.expectMessageContaining("\"status\":\"cancelled\"");
}

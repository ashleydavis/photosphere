//
// A loopback HTTP server that serves the example's image and video to the page. It is the example's own code and not part of
// Ziggy: an app that needs to show media from outside the page's origin starts one like it, and the web view fetches the media
// from it as it would from any web server. It listens on 127.0.0.1 only, on a port the operating system chooses.
//
// It runs as a task so that the task's stack owns its state and cancelling the task stops it. The task tells the page its port
// with a "media-server" message.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const TaskContext = ziggy.task_runner.TaskContext;

//
// One file the server serves, embedded in the example's core.
//
const Asset = struct {
    // The request path it is served under.
    path: []const u8,
    // Its Content-Type.
    content_type: []const u8,
    // Its bytes.
    bytes: []const u8,
};

const assets = [_]Asset{
    .{
        .path = "/example.png",
        .content_type = "image/png",
        .bytes = @embedFile("../media/example.png"),
    },
    .{
        .path = "/example.mp4",
        .content_type = "video/mp4",
        .bytes = @embedFile("../media/example.mp4"),
    },
};

//
// A range of bytes of a file, both ends included, as a Range header asks for.
//
pub const ByteRange = struct {
    // The first byte.
    start: usize,
    // The last byte.
    end: usize,
};

//
// Reads the value of a Range header against a file of the given size. Returns null when the header does not ask for bytes,
// which means the whole file, and error.Unsatisfiable when the range lies outside the file.
//
pub fn parseRange(header: []const u8, size: usize) error{Unsatisfiable}!?ByteRange {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, header, prefix)) {
        return null;
    }
    const spec = header[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse {
        return null;
    };
    const first_text = spec[0..dash];
    const last_text = spec[dash + 1 ..];
    if (size == 0) {
        return error.Unsatisfiable;
    }
    if (first_text.len == 0) {
        // "bytes=-N" is the last N bytes.
        const suffix = std.fmt.parseInt(usize, last_text, 10) catch {
            return null;
        };
        if (suffix == 0) {
            return error.Unsatisfiable;
        }
        return .{
            .start = size - @min(suffix, size),
            .end = size - 1,
        };
    }
    const first = std.fmt.parseInt(usize, first_text, 10) catch {
        return null;
    };
    if (first >= size) {
        return error.Unsatisfiable;
    }
    const last = if (last_text.len == 0) size - 1 else std.fmt.parseInt(usize, last_text, 10) catch {
        return null;
    };
    if (last < first) {
        return null;
    }
    return .{
        .start = first,
        .end = @min(last, size - 1),
    };
}

//
// Finds the file served under a request path, ignoring any query, or null when there is none.
//
pub fn findAsset(request_path: []const u8) ?*const Asset {
    const path = request_path[0 .. std.mem.indexOfScalar(u8, request_path, '?') orelse request_path.len];
    for (&assets) |*asset| {
        if (std.mem.eql(u8, asset.path, path)) {
            return asset;
        }
    }
    return null;
}

//
// The task: listens, tells the page the port and serves connections until the task is cancelled. A connection is served on a
// thread of its own that owns everything it uses, because a browser opens connections it never sends a request on and a thread
// waiting on one cannot be woken. Such a thread ends when the browser closes the connection, and the task does not wait for it.
//
pub fn mediaServerHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const io = context.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stopping: std.atomic.Value(bool) = .init(false);
    const watcher = try std.Thread.spawn(.{}, watchForCancel, .{ context, &stopping, port });
    try context.sendMessage(.{
        .type = "media-server",
        .port = port,
    });
    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (stopping.load(.acquire)) {
                break;
            }
            std.debug.print("media server: accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (stopping.load(.acquire)) {
            stream.close(io);
            break;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{stream}) catch |err| {
            std.debug.print("media server: could not serve a connection: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
    stopping.store(true, .release);
    watcher.join();
    return error.Cancelled;
}

//
// Wakes the accepting loop when the task is cancelled. Accepting blocks, so a connection made here makes it look at the flag.
//
fn watchForCancel(context: *TaskContext, stopping: *std.atomic.Value(bool), port: u16) void {
    while (!stopping.load(.acquire)) {
        context.checkCancelled() catch {
            stopping.store(true, .release);
            const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            if (address.connect(context.io(), .{ .mode = .stream })) |stream| {
                stream.close(context.io());
            }
            else |_| {}
            return;
        };
        context.io().sleep(.fromMilliseconds(50), .awake) catch {};
    }
}

//
// Reads one request from the connection, answers it and closes the connection.
//
fn serveConnection(stream: std.Io.net.Stream) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    defer stream.close(io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    answerRequest(&reader.interface, &writer.interface) catch |err| {
        if (err != error.ReadFailed and err != error.EndOfStream) {
            std.debug.print("media server: a request failed: {s}\n", .{@errorName(err)});
        }
    };
}

//
// Reads the request line and headers from the reader and writes the response to the writer.
//
fn answerRequest(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const request_line = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse {
        return error.BadRequest;
    };
    const request_path = parts.next() orelse {
        return error.BadRequest;
    };
    var range_header: ?[]const u8 = null;
    var range_copy: [128]u8 = undefined;
    while (true) {
        const line = std.mem.trimEnd(u8, try reader.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) {
            break;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            continue;
        };
        if (std.ascii.eqlIgnoreCase(line[0..colon], "range")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (value.len <= range_copy.len) {
                @memcpy(range_copy[0..value.len], value);
                range_header = range_copy[0..value.len];
            }
        }
    }
    const cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: range\r\n";
    if (std.mem.eql(u8, method, "OPTIONS")) {
        try writer.print("HTTP/1.1 204 No Content\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{cors});
        try writer.flush();
        return;
    }
    const is_head = std.mem.eql(u8, method, "HEAD");
    if (!is_head and !std.mem.eql(u8, method, "GET")) {
        try writer.print("HTTP/1.1 405 Method Not Allowed\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{cors});
        try writer.flush();
        return;
    }
    const asset = findAsset(request_path) orelse {
        try writer.print("HTTP/1.1 404 Not Found\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{cors});
        try writer.flush();
        return;
    };
    const range = if (range_header) |header| parseRange(header, asset.bytes.len) catch {
        try writer.print("HTTP/1.1 416 Range Not Satisfiable\r\n{s}Content-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ cors, asset.bytes.len });
        try writer.flush();
        return;
    } else null;
    if (range) |found| {
        const body = asset.bytes[found.start .. found.end + 1];
        try writer.print(
            "HTTP/1.1 206 Partial Content\r\n{s}Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ cors, asset.content_type, found.start, found.end, asset.bytes.len, body.len },
        );
        if (!is_head) {
            try writer.writeAll(body);
        }
    }
    else {
        try writer.print(
            "HTTP/1.1 200 OK\r\n{s}Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ cors, asset.content_type, asset.bytes.len },
        );
        if (!is_head) {
            try writer.writeAll(asset.bytes);
        }
    }
    try writer.flush();
}

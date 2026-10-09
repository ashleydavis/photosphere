//
// Sends requests to a server on the loopback interface and reads the answers, for the tests of the asset server. It uses the HTTP client
// of the standard library, so a test sees the server as a browser's fetch does. (No TypeScript counterpart: the TypeScript tests call
// `fetch`.)
//

const std = @import("std");

//
// What a server answered.
//
pub const Reply = struct {
    // The status code.
    status: u16,

    // The Content-Type header, or null.
    contentType: ?[]const u8,

    // The Access-Control-Allow-Origin header, or null.
    allowOrigin: ?[]const u8,

    // The Access-Control-Allow-Methods header, or null.
    allowMethods: ?[]const u8,

    // The Access-Control-Allow-Headers header, or null.
    allowHeaders: ?[]const u8,

    // The Content-Length header, or null.
    contentLength: ?u64,

    // The body.
    body: []u8,
};

//
// The headers and the body of a request.
//
pub const RequestOptions = struct {
    // The Content-Type header, or null for none.
    contentType: ?[]const u8,

    // The body, or null for none.
    payload: ?[]const u8,
};

//
// Sends one request to the port and returns what the server answers. Everything the reply holds is allocated with the allocator.
//
pub fn send(allocator: std.mem.Allocator, io: std.Io, method: std.http.Method, port: u16, target: []const u8, options: RequestOptions) !Reply {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();
    const uri = try std.Uri.parse(try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, target }));
    var request = try client.request(method, uri, .{
        .headers = .{
            .content_type = if (options.contentType) |value| .{ .override = value } else .omit,
        },
        .keep_alive = false,
    });
    defer request.deinit();
    if (options.payload) |payload| {
        request.transfer_encoding = .{ .content_length = payload.len };
        var body = try request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try request.connection.?.flush();
    }
    else {
        try request.sendBodiless();
    }
    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    var reply: Reply = .{
        .status = @intFromEnum(response.head.status),
        .contentType = if (response.head.content_type) |value| try allocator.dupe(u8, value) else null,
        .allowOrigin = null,
        .allowMethods = null,
        .allowHeaders = null,
        .contentLength = response.head.content_length,
        .body = &.{},
    };
    var headers = std.http.HeaderIterator.init(response.head.bytes);
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "access-control-allow-origin")) {
            reply.allowOrigin = try allocator.dupe(u8, header.value);
        }
        else if (std.ascii.eqlIgnoreCase(header.name, "access-control-allow-methods")) {
            reply.allowMethods = try allocator.dupe(u8, header.value);
        }
        else if (std.ascii.eqlIgnoreCase(header.name, "access-control-allow-headers")) {
            reply.allowHeaders = try allocator.dupe(u8, header.value);
        }
    }
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    reply.body = try reader.allocRemaining(allocator, .unlimited);
    return reply;
}

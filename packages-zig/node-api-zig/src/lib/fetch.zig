//
// A GET request that resolves to the status and the body text. Redirects are followed. Network failures
// return the Zig error.
//

const std = @import("std");

//
// The response of a GET request.
//
pub const IFetchResponse = struct {
    // The HTTP status code (`response.status`).
    status: u16,

    // True for a 2xx status (`response.ok`).
    ok: bool,

    // The body text (`await response.text()`).
    body: []const u8,
};

//
// Sends a GET request and reads the whole response.
//
pub fn fetch(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !IFetchResponse {
    var client: std.http.Client = .{ .allocator = std.heap.smp_allocator, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(allocator);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    const status: u16 = @intFromEnum(result.status);
    return .{
        .status = status,
        .ok = status >= 200 and status <= 299,
        .body = body.written(),
    };
}

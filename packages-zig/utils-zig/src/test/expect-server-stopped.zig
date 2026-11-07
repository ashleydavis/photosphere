const std = @import("std");

//
// Asserts that a server a test has stopped no longer accepts connections on the port it had, as the TypeScript tests do by expecting a
// fetch to the released port to fail to connect.
//
pub fn expectServerStopped(io: std.Io, port: u16) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = address.connect(io, .{
        .mode = .stream,
    }) catch {
        return;
    };
    stream.close(io);
    std.debug.print("A connection to port {d} succeeded after the server was stopped.\n", .{port});
    return error.ServerStillListening;
}

//
// Tests for the discovery port in lan-share-types.zig and the free port finder in socket.zig.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const lan_share = @import("lan-share-network-zig");

const discoveryPort = lan_share.lan_share_types.discoveryPort;
const process_env = node_utils.process_env;

//
// Runs the check with an environment that holds the variable (or none, for null), and puts back the environment that was there.
//
fn withPortVariable(value: ?[]const u8, check: *const fn () anyerror!void) !void {
    const previous = process_env.getEnvironMap();
    defer process_env.setEnvironMap(previous);
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    if (value) |text| {
        try map.put("PHOTOSPHERE_LAN_SHARE_PORT", text);
    }
    process_env.setEnvironMap(&map);
    try check();
}

fn expectDefault() anyerror!void {
    try std.testing.expectEqual(@as(u16, 54321), try discoveryPort());
}

fn expectNamedPort() anyerror!void {
    try std.testing.expectEqual(@as(u16, 40123), try discoveryPort());
}

fn expectRefused() anyerror!void {
    try std.testing.expectError(error.Thrown, discoveryPort());
    try std.testing.expectEqualStrings("PHOTOSPHERE_LAN_SHARE_PORT must be a port number, not \"abc\".", utils.errors.lastErrorMessage());
}

test "the discovery port is 54321 when PHOTOSPHERE_LAN_SHARE_PORT is not set" {
    try withPortVariable(null, expectDefault);
}

test "the discovery port is the one PHOTOSPHERE_LAN_SHARE_PORT names" {
    try withPortVariable("40123", expectNamedPort);
}

test "a PHOTOSPHERE_LAN_SHARE_PORT that is not a port number is refused with a sentence" {
    try withPortVariable("abc", expectRefused);
}

test "freeUdpPort gives a port a socket can then bind" {
    const port = try lan_share.socket.freeUdpPort();
    try std.testing.expect(port > 0);

    const handle = try lan_share.socket.createUdp(false, false);
    defer lan_share.socket.close(handle);
    try lan_share.socket.bind(handle, .{ .address = .{ 0, 0, 0, 0 }, .port = port });

    try std.testing.expectEqual(port, try lan_share.socket.localPort(handle));
}

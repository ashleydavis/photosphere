//
// The results the MacOS app gives to the native calls the background work makes of the platform. Ziggy's MacOS bridge has no native
// call callback, so the core makes these calls itself on MacOS, in place of the native app, with the results the Linux native app gives
// (apps/photosphere/native/linux/src/main.zig). Without it every one of them failed with "... is only available in the Photosphere app
// on a mobile", which failed the app smoke tests of the MacOS release workflow: opening a database logged the error from
// requestNotificationPermission, and the background import and sync never ran.
//
// - requestNotificationPermission and requestMediaPermission: a desktop has no permission to request, so they are always granted.
// - networkConnectionType: read from the interface the default route names (the routing table via sysctl), with its media type from
//   SIOCGIFMEDIA, classified here.
// - backgroundLog: the message goes to standard error, which is the app's log.
//
// Any other method is not something a desktop can do, and the caller reports that.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const NetworkConnectionType = @import("api-zig").sync_gate.NetworkConnectionType;

//
// Classifies a macOS connection from the interface the default route names and whether that interface is
// wireless or Ethernet, read from its media type. No default route is none, wireless is wifi, Ethernet is wired,
// and anything else is unknown.
//
fn classifyMacosConnection(route_interface: ?[]const u8, is_wireless: bool, is_ethernet: bool) NetworkConnectionType {
    if (route_interface == null) {
        return .none;
    }
    if (is_wireless) {
        return .wifi;
    }
    if (is_ethernet) {
        return .wired;
    }
    return .unknown;
}

//
// The JSON text of a connection type, which is what a native call answers: the tag name in quotes.
//
fn toJsonText(connection_type: NetworkConnectionType) []const u8 {
    return switch (connection_type) {
        .wifi => "\"wifi\"",
        .wired => "\"wired\"",
        .cellular => "\"cellular\"",
        .none => "\"none\"",
        .unknown => "\"unknown\"",
    };
}

//
// The MacOS network headers, imported only when this is compiled for MacOS, so the file still compiles and
// its tests still run on every other platform.
//
const mac = if (builtin.os.tag == .macos) @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/ioctl.h");
    @cInclude("net/route.h");
    @cInclude("net/if.h");
    @cInclude("net/if_media.h");
    @cInclude("ifaddrs.h");
}) else struct {};

//
// What the background work sends with backgroundLog.
//
const IBackgroundLog = struct {
    // Whether the message reports a failure.
    @"error": bool,
    // The message.
    message: []const u8,
};

//
// Makes a native call and returns the JSON text of its result, allocated with the allocator, or null when the method is not one a
// desktop can do. A request that cannot be read is an error that reports it.
//
pub fn call(allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, method, "requestNotificationPermission")) {
        return "{\"granted\":true}";
    }
    if (std.mem.eql(u8, method, "requestMediaPermission")) {
        return "{\"granted\":true}";
    }
    if (std.mem.eql(u8, method, "networkConnectionType")) {
        if (comptime builtin.os.tag == .macos) {
            return macosConnectionType(allocator);
        }
        else {
            return null;
        }
    }
    if (std.mem.eql(u8, method, "backgroundLog")) {
        const parsed = std.json.parseFromSliceLeaky(IBackgroundLog, allocator, request_json, .{}) catch {
            return utils.errors.throwError("backgroundLog needs {{\"error\": true or false, \"message\": text}}, and was given {s}.", .{request_json});
        };
        utils.console.@"error"(parsed.message);
        return "null";
    }
    return null;
}

//
// The JSON text of the connection type the MacOS machine's default route reports. The routing table is
// dumped with sysctl (net.route.0.0.dump), the entry whose destination is the default route names the
// interface that carries traffic by its index, and that interface's media type (SIOCGIFMEDIA) tells
// wireless from Ethernet. The decision is classifyMacosConnection's. Unverified on this machine: the
// function is compiled only for MacOS and checked by the MacOS CI workflow.
//
fn macosConnectionType(allocator: std.mem.Allocator) ![]const u8 {
    var mib = [6]c_int{
        mac.CTL_NET,
        mac.PF_ROUTE,
        0,
        0,
        mac.NET_RT_DUMP,
        0,
    };
    var size: usize = 0;
    if (mac.sysctl(&mib, mib.len, null, &size, null, 0) < 0) {
        return toJsonText(classifyMacosConnection(null, false, false));
    }
    const buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);
    if (mac.sysctl(&mib, mib.len, buffer.ptr, &size, null, 0) < 0) {
        return toJsonText(classifyMacosConnection(null, false, false));
    }

    var offset: usize = 0;
    while (offset < size) {
        const header: *mac.struct_rt_msghdr = @ptrCast(@alignCast(buffer[offset..].ptr));
        const message_length: usize = header.*.rtm_msglen;
        if (message_length == 0) {
            break;
        }
        if ((header.*.rtm_flags & mac.RTF_GATEWAY) != 0 and isDefaultRouteDestination(buffer[offset..], header.*.rtm_addrs)) {
            return classifyMacosInterface(header.*.rtm_index);
        }
        offset += message_length;
    }
    return toJsonText(classifyMacosConnection(null, false, false));
}

//
// Whether the destination address of a routing table entry is the default route (an all zero address).
// The sockaddrs follow the header in the order the rtm_addrs bits name them, RTA_DST first, and each
// starts with its length and family, which a MacOS sockaddr gives.
//
fn isDefaultRouteDestination(message: []const u8, address_bits: c_int) bool {
    if ((address_bits & mac.RTA_DST) == 0) {
        return false;
    }
    const sockaddr_start = message[@sizeOf(mac.struct_rt_msghdr)..];
    if (sockaddr_start.len < 2) {
        return false;
    }
    const family: u8 = sockaddr_start[1];
    if (family == mac.AF_INET) {
        const address = sockaddr_start[4..8];
        return std.mem.allEqual(u8, address, 0);
    }
    if (family == mac.AF_INET6) {
        const address = sockaddr_start[8..24];
        return std.mem.allEqual(u8, address, 0);
    }
    return false;
}

//
// Classifies the MacOS interface of the given name by reading its media type with SIOCGIFMEDIA, which
// reports IFM_IEEE80211 for a wireless interface and IFM_ETHER for an Ethernet one.
//
fn classifyMacosInterface(index: c_ushort) ![]const u8 {
    var name_buffer: [mac.IF_NAMESIZE]u8 = @splat(0);
    const name = mac.if_indextoname(index, &name_buffer);
    if (name == null) {
        return toJsonText(classifyMacosConnection(null, false, false));
    }

    const socket = mac.socket(mac.AF_INET, mac.SOCK_DGRAM, 0);
    if (socket < 0) {
        return toJsonText(classifyMacosConnection(null, false, false));
    }
    defer _ = mac.close(socket);

    var request: mac.struct_ifmediareq = std.mem.zeroes(mac.struct_ifmediareq);
    _ = std.fmt.bufPrint(request.ifm_name[0..], "{s}", .{std.mem.span(name)}) catch {
        return toJsonText(classifyMacosConnection(null, false, false));
    };
    if (mac.ioctl(socket, mac.SIOCGIFMEDIA, &request) < 0) {
        return toJsonText(classifyMacosConnection(null, false, false));
    }

    const media_type = request.ifm_current & mac.IFM_NMASK;
    const is_wireless = media_type == mac.IFM_IEEE80211;
    const is_ethernet = media_type == mac.IFM_ETHER;
    return toJsonText(classifyMacosConnection(std.mem.span(name), is_wireless, is_ethernet));
}

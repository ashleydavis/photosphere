//
// The results the Windows app gives to the native calls the background work makes of the platform. Ziggy's Windows native app has no
// native call callback, so the core makes these calls itself on Windows, in place of the native app, with the results the Linux native
// app gives (apps/photosphere/native/linux/src/main.zig):
//
// - requestNotificationPermission and requestMediaPermission: a desktop has no permission to request, so they are always granted.
// - networkConnectionType: read from the Windows adapter that carries the default route (GetBestInterface and GetAdaptersAddresses),
//   classified here.
// - backgroundLog: the message goes to standard error, which is the app's log.
//
// Any other method is not something a desktop can do, and the caller reports that.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const NetworkConnectionType = @import("api-zig").sync_gate.NetworkConnectionType;

//
// Classifies a Windows connection from whether a default-route adapter was found and its type: wireless is wifi,
// Ethernet is wired, any other type is unknown, and no route at all is none.
//
fn classifyWindowsConnection(has_route: bool, is_wireless: bool, is_ethernet: bool) NetworkConnectionType {
    if (!has_route) {
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
// The Windows network headers, imported only when this is compiled for Windows, so the file still compiles
// and its tests still run on every other platform.
//
const win = if (builtin.os.tag == .windows) @cImport({
    @cInclude("winsock2.h");
    @cInclude("iphlpapi.h");
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
        if (comptime builtin.os.tag == .windows) {
            return windowsConnectionType(allocator);
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
// The JSON text of the connection type the Windows machine's default route reports. GetBestInterface names
// the adapter index of the route to 0.0.0.0, and GetAdaptersAddresses walks the adapters to find that index
// and read its type. Wireless is IF_TYPE_IEEE80211, Ethernet is IF_TYPE_ETHERNET_CSMACD, any other type is
// unknown, and no route at all is none. The decision is classifyWindowsConnection's. Unverified on this
// machine: the function is compiled only for Windows and checked by the Windows CI workflow.
//
fn windowsConnectionType(allocator: std.mem.Allocator) ![]const u8 {
    var best_index: win.ULONG = 0;
    if (win.GetBestInterface(0, &best_index) != win.NO_ERROR) {
        return toJsonText(classifyWindowsConnection(false, false, false));
    }

    var size: win.ULONG = 16 * 1024;
    var attempts: u8 = 0;
    while (attempts < 2) : (attempts += 1) {
        const buffer = allocator.alloc(u8, size) catch {
            return error.OutOfMemory;
        };
        defer allocator.free(buffer);
        const result = win.GetAdaptersAddresses(win.AF_UNSPEC, win.GAA_FLAG_INCLUDE_PREFIX, null, @ptrCast(buffer.ptr), &size);
        if (result == win.ERROR_BUFFER_OVERFLOW) {
            continue;
        }
        if (result != win.NO_ERROR) {
            return toJsonText(classifyWindowsConnection(false, false, false));
        }

        var adapter: ?*win.IP_ADAPTER_ADDRESSES = @ptrCast(@alignCast(buffer.ptr));
        while (adapter) |current| {
            if (current.*.IfIndex == best_index) {
                const is_wireless = current.*.IfType == win.IF_TYPE_IEEE80211;
                const is_ethernet = current.*.IfType == win.IF_TYPE_ETHERNET_CSMACD;
                return toJsonText(classifyWindowsConnection(true, is_wireless, is_ethernet));
            }
            adapter = current.*.Next;
        }
        return toJsonText(classifyWindowsConnection(false, false, false));
    }
    return error.CannotReadNetworkAdapters;
}

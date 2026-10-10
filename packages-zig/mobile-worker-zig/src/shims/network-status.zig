//
// Typed access to the native connection-type host function.
//
// The background sync loop has to know whether the phone is on Wi-Fi, on a cellular connection, or
// on nothing at all, because the "Only sync over Wi-Fi" setting refuses a sync on cellular. The app's
// own network status lives in the WebView, and there may be no WebView: the loop runs while the app
// is off screen. So the worker asks the platform directly, through ConnectivityManager on Android and
// NWPathMonitor on iOS.
//
// (Zig has no process-wide global host, so the host is a value the caller passes in: whoever runs the handler knows how
// the platform is asked (the phone's shell, through the host request callback of Ziggy's core), and passes it. It cannot
// be missing, so there is no "host not installed" case to report. A host returns an error, and it reaches the caller as one.)
//

const std = @import("std");
const api = @import("api-zig");
const NetworkConnectionType = api.sync_gate.NetworkConnectionType;

//
// The native host function the connection type is read through.
// (Zig: a pointer to the implementation and its function, as the other interfaces of the packages are written.)
//
pub const INetworkStatusHost = struct {
    // The implementation.
    ptr: *anyopaque,

    // The functions of the implementation.
    vtable: *const VTable,

    //
    // The functions a host provides.
    //
    pub const VTable = struct {
        // Returns the current connection type as one of "wifi", "cellular", "none" or "unknown", allocated with `allocator`.
        networkConnectionType: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    //
    // Returns the current connection type as the platform reported it.
    //
    pub fn networkConnectionType(self: INetworkStatusHost, allocator: std.mem.Allocator) anyerror![]const u8 {
        return self.vtable.networkConnectionType(self.ptr, allocator);
    }
};

//
// Turns what the platform reported into the connection type computeSyncAllowed understands.
//
// Anything unrecognised, including an empty string, becomes "unknown" rather than throwing. A
// platform reporting a connection nobody anticipated (a new transport, a VPN described some other
// way) must not stop syncing altogether, and "unknown" is the value computeSyncAllowed already
// permits for exactly this reason: the desktop cannot report a type either.
//
pub fn toNetworkConnectionType(reported: []const u8) NetworkConnectionType {
    if (std.mem.eql(u8, reported, "wifi")) {
        return .wifi;
    }
    if (std.mem.eql(u8, reported, "cellular")) {
        return .cellular;
    }
    if (std.mem.eql(u8, reported, "none")) {
        return .none;
    }
    if (std.mem.eql(u8, reported, "unknown")) {
        return .unknown;
    }
    return .unknown;
}

//
// Reads the current connection type from the platform.
//
pub fn readNetworkConnectionType(allocator: std.mem.Allocator, host: INetworkStatusHost) !NetworkConnectionType {
    const reported = try host.networkConnectionType(allocator);
    return toNetworkConnectionType(reported);
}

//
// Typed access to the native connection-type host function.
//
// The background sync loop has to know whether the platform is on Wi-Fi, on a cellular connection, or
// on nothing at all, because the "Only sync over Wi-Fi or wired network" setting refuses a sync on cellular.
// The loop runs with the app off screen, so the worker asks the platform directly: ConnectivityManager on
// Android, NWPathMonitor on iOS, and the operating system's own routing and interface state on the desktop.
//
// (Zig has no process-wide global host, so the host is a value the caller passes in: whoever runs the handler knows how
// the platform is asked (the platform's native app, through the host request callback of Ziggy's core), and passes it. It cannot
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
        networkConnectionType: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    //
    // Returns the current connection type as the platform reported it.
    //
    pub fn networkConnectionType(self: INetworkStatusHost, io: std.Io, allocator: std.mem.Allocator) anyerror![]const u8 {
        return self.vtable.networkConnectionType(self.ptr, io, allocator);
    }
};

//
// Turns what the platform reported into the connection type computeSyncAllowed understands.
//
// Anything unrecognised, including an empty string, becomes "unknown" rather than throwing. A
// platform reporting a connection nobody anticipated (a new transport, a VPN described some other
// way) must not stop syncing altogether, and "unknown" is the value computeSyncAllowed permits for
// exactly this reason.
//
pub fn toNetworkConnectionType(reported: []const u8) NetworkConnectionType {
    if (std.mem.eql(u8, reported, "wifi")) {
        return .wifi;
    }
    if (std.mem.eql(u8, reported, "wired")) {
        return .wired;
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
pub fn readNetworkConnectionType(io: std.Io, allocator: std.mem.Allocator, host: INetworkStatusHost) !NetworkConnectionType {
    const reported = try host.networkConnectionType(io, allocator);
    return toNetworkConnectionType(reported);
}

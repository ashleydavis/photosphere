//
// Tests for network-status.zig.
//
// Tests for the connection-type host function.
//
// computeSyncAllowed treats "cellular" as the one type to refuse and "unknown" as permitted, so what
// this mapping does with a value it does not recognise decides whether a phone reporting something
// new stops syncing altogether or carries on. It carries on.
//
// There is no test for reading with no host installed: the host is a value the caller passes in, so it cannot be missing.
//

const std = @import("std");
const mobile_worker = @import("mobile-worker-zig");
const test_hosts = @import("test-hosts.zig");
const network_status = mobile_worker.network_status;
const toNetworkConnectionType = network_status.toNetworkConnectionType;
const readNetworkConnectionType = network_status.readNetworkConnectionType;
const ReportingHost = test_hosts.ReportingHost;

test "connection type: each value the platforms report maps to itself" {
    try std.testing.expectEqual(.wifi, toNetworkConnectionType("wifi"));
    try std.testing.expectEqual(.cellular, toNetworkConnectionType("cellular"));
    try std.testing.expectEqual(.none, toNetworkConnectionType("none"));
    try std.testing.expectEqual(.unknown, toNetworkConnectionType("unknown"));
}

// A platform reporting a transport nobody anticipated must not stop syncing, and "unknown" is the value computeSyncAllowed
// already permits for exactly this reason.
test "connection type: anything unrecognised maps to unknown rather than throwing" {
    try std.testing.expectEqual(.unknown, toNetworkConnectionType("ethernet"));
    try std.testing.expectEqual(.unknown, toNetworkConnectionType(""));
    try std.testing.expectEqual(.unknown, toNetworkConnectionType("WIFI"));
}

test "connection type: reading goes to the host and comes back as a type computeSyncAllowed knows" {
    var host: ReportingHost = .{
        .reported = "cellular",
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(.cellular, try readNetworkConnectionType(std.testing.io, arena.allocator(), host.networkStatusHost()));
}

// The native side returns an error rather than a type when it cannot tell. Read as a connection type it would map to "unknown"
// and permit a sync on a connection nobody could identify.
test "connection type: a host error is returned rather than read as a connection type" {
    var host: ReportingHost = .{
        .reported = "",
        .failure = error.NoConnectivityManager,
    };

    try std.testing.expectError(error.NoConnectivityManager, readNetworkConnectionType(std.testing.io, std.testing.allocator, host.networkStatusHost()));
}

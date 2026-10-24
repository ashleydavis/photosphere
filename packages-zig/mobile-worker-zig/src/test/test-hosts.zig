//
// The native host the tests of the planning handlers ask for the connection type. It reports what the test says, standing in
// for ConnectivityManager on Android and NWPathMonitor on iOS.
//

const std = @import("std");
const mobile_worker = @import("mobile-worker-zig");
const INetworkStatusHost = mobile_worker.network_status.INetworkStatusHost;

//
// A host that reports what the test says, or fails.
//
pub const ReportingHost = struct {
    // The connection type the host reports.
    reported: []const u8,

    // The error the host fails with instead of reporting, or null.
    failure: ?anyerror = null,

    //
    // Gets the INetworkStatusHost interface for this host.
    //
    pub fn networkStatusHost(self: *ReportingHost) INetworkStatusHost {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The functions of the host.
    //
    const vtable: INetworkStatusHost.VTable = .{
        .networkConnectionType = networkConnectionType,
    };

    //
    // Reports the connection type.
    //
    fn networkConnectionType(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *ReportingHost = @ptrCast(@alignCast(ptr));
        if (self.failure) |failure| {
            return failure;
        }
        return allocator.dupe(u8, self.reported);
    }
};

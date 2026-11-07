const std = @import("std");
const api_zig = @import("api-zig");
const computeSyncAllowed = api_zig.sync_gate.computeSyncAllowed;

test "computeSyncAllowed returns false when syncing is disabled, regardless of other inputs" {
    try std.testing.expectEqual(false, computeSyncAllowed(.{
        .syncEnabled = false,
        .syncOnlyOnWifi = false,
        .connected = true,
        .connectionType = .wifi,
    }));
    try std.testing.expectEqual(false, computeSyncAllowed(.{
        .syncEnabled = false,
        .syncOnlyOnWifi = true,
        .connected = true,
        .connectionType = .cellular,
    }));
}

test "computeSyncAllowed returns false when offline even if enabled" {
    try std.testing.expectEqual(false, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = false,
        .connected = false,
        .connectionType = .wifi,
    }));
}

test "computeSyncAllowed returns false when the connection type is none" {
    try std.testing.expectEqual(false, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = false,
        .connected = true,
        .connectionType = .none,
    }));
}

test "computeSyncAllowed returns false when Wi-Fi-only is on and the connection is cellular" {
    try std.testing.expectEqual(false, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = true,
        .connected = true,
        .connectionType = .cellular,
    }));
}

test "computeSyncAllowed returns true when Wi-Fi-only is on and the connection is wifi" {
    try std.testing.expectEqual(true, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = true,
        .connected = true,
        .connectionType = .wifi,
    }));
}

test "computeSyncAllowed returns true when Wi-Fi-only is on and the connection type is unknown (desktop/web)" {
    try std.testing.expectEqual(true, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = true,
        .connected = true,
        .connectionType = .unknown,
    }));
}

test "computeSyncAllowed returns true when Wi-Fi-only is off and the connection is cellular" {
    try std.testing.expectEqual(true, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = false,
        .connected = true,
        .connectionType = .cellular,
    }));
}

test "computeSyncAllowed returns true when fully enabled, connected, and on wifi" {
    try std.testing.expectEqual(true, computeSyncAllowed(.{
        .syncEnabled = true,
        .syncOnlyOnWifi = true,
        .connected = true,
        .connectionType = .wifi,
    }));
}

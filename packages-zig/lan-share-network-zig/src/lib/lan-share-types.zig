const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

//
// The UDP port discovery broadcasts use unless PHOTOSPHERE_LAN_SHARE_PORT names another.
//
pub const DEFAULT_DISCOVERY_PORT: u16 = 54321;

//
// The UDP port a sender listens on and a receiver announces to: the default, or the port PHOTOSPHERE_LAN_SHARE_PORT names. Two
// programs that share on one machine at once must use different ports, or each one hears the other's receiver.
//
pub fn discoveryPort() !u16 {
    const text = node_utils.process_env.getEnv("PHOTOSPHERE_LAN_SHARE_PORT") orelse {
        return DEFAULT_DISCOVERY_PORT;
    };
    return std.fmt.parseInt(u16, text, 10) catch {
        return utils.errors.throwError("PHOTOSPHERE_LAN_SHARE_PORT must be a port number, not \"{s}\".", .{text});
    };
}

//
// Response body from GET /pairing-code-hash on the receiver.
//
pub const IPairingCodeHashResponse = struct {
    // SHA-256 hash of the pairing code the receiver has on file, hex-encoded.
    codeHash: []const u8,
};

//
// Network endpoint information discovered by the sender via UDP broadcast.
//
pub const IReceiverEndpoint = struct {
    // IP address of the receiver.
    address: []const u8,

    // HTTPS port the receiver is listening on.
    port: u16,

    // SHA-256 fingerprint of the receiver's TLS certificate, for certificate pinning.
    certFingerprint: []const u8,
};

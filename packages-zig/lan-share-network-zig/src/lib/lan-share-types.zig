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

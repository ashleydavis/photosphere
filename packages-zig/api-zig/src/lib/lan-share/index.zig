const std = @import("std");
const lan_share_core = @import("lan-share-core-zig");

// The LAN-share payload types and the conflict-resolution types live in the zero-dependency lan-share-core package,
// so mobile (which cannot import this package) can share them and the import logic. Re-exported so
// the importers of this package are unchanged.
pub const IShareS3Credentials = lan_share_core.IShareS3Credentials;
pub const IShareEncryptionKey = lan_share_core.IShareEncryptionKey;
pub const IShareGeocodingKey = lan_share_core.IShareGeocodingKey;
pub const IDatabaseSharePayload = lan_share_core.IDatabaseSharePayload;
pub const ISecretSharePayload = lan_share_core.ISecretSharePayload;
pub const IConflictResolution = lan_share_core.IConflictResolution;
pub const ConflictResolver = lan_share_core.ConflictResolver;

//
// Represents a database configuration entry with vault key references,
// used as input to resolveDatabaseSharePayload and output of importDatabasePayload.
//
pub const IShareDatabaseConfig = struct {
    // Human-readable display name.
    name: []const u8,

    // Optional description of this database.
    description: []const u8,

    // Absolute filesystem path (or S3 path) to the database directory.
    path: []const u8,

    // Optional origin string from the database config.
    origin: ?[]const u8 = null,

    // Vault secret name for S3 credentials.
    s3Key: ?[]const u8 = null,

    // Vault secret name for the encryption key pair.
    encryptionKey: ?[]const u8 = null,

    // Vault secret name for the geocoding API key.
    geocodingKey: ?[]const u8 = null,
};

//
// Input data for the "receive-share" background task, which hosts a receiver
// on the LAN and waits for a sender to deliver a share payload.
// (Zig: task data travels as JSON (std.json.Value); the `= ""` default lets std.json parse data that leaves the key out.)
//
pub const IReceiveShareTaskData = struct {
    // The pairing code the receiver advertises (entered by the user off the sender).
    code: []const u8 = "",
};

//
// Result of the "receive-share" background task.
// (Zig: the payload is the JSON value of an IDatabaseSharePayload or an ISecretSharePayload.)
//
pub const IReceiveShareTaskResult = struct {
    // Payload delivered by a sender, or null if the receiver timed out or was cancelled.
    payload: ?std.json.Value,
};

//
// Network endpoint of a discovered share receiver. Structurally identical to
// lan-share's IReceiverEndpoint; defined here so neither api nor user-interface
// has to depend on the Node-only lan-share package.
//
pub const IShareReceiverEndpoint = struct {
    // IP address of the receiver.
    address: []const u8,

    // HTTPS port the receiver is listening on.
    port: u16,

    // SHA-256 fingerprint of the receiver's TLS certificate, for certificate pinning.
    certFingerprint: []const u8,
};

//
// Input data for the "find-receiver" background task, which listens for a
// receiver's UDP broadcast for this share session.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out.)
//
pub const IFindReceiverTaskData = struct {
    // The pairing code for this share session.
    code: []const u8 = "",
};

//
// Result of the "find-receiver" background task.
//
pub const IFindReceiverTaskResult = struct {
    // The discovered receiver endpoint, or null if discovery timed out or was cancelled.
    endpoint: ?IShareReceiverEndpoint,
};

//
// Input data for the "send-payload" background task, which delivers a payload
// to a previously discovered receiver over HTTPS.
// (Zig: the payload is the JSON value of an IDatabaseSharePayload or an ISecretSharePayload.)
//
pub const ISendPayloadTaskData = struct {
    // The share payload to deliver to the receiver.
    payload: std.json.Value,

    // The pairing code used to verify the receiver.
    code: []const u8,

    // The receiver endpoint discovered by the "find-receiver" task.
    endpoint: IShareReceiverEndpoint,
};

//
// Result of the "send-payload" background task.
//
pub const ISendPayloadTaskResult = struct {
    // True if the receiver accepted the payload.
    success: bool,
};

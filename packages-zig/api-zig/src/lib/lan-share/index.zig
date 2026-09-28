const lan_share_core = @import("lan-share-core-zig");

// The LAN-share payload types and the conflict-resolution types live in the zero-dependency lan-share-core package,
// so mobile (which cannot import this Node package) can share them and the import logic. Re-exported so
// `from "api"` importers are unchanged.
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

// Not ported: IReceiveShareTaskData, IReceiveShareTaskResult, IShareReceiverEndpoint, IFindReceiverTaskData,
// IFindReceiverTaskResult, ISendPayloadTaskData and ISendPayloadTaskResult (the background tasks of the desktop app,
// not used by the CLI).

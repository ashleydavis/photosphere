const lan_share_core = @import("lan-share-core-zig");

// The LAN-share payload types live in the zero-dependency lan-share-core package, so mobile (which cannot import
// this Node package) can share them. Re-exported so `from "api"` importers are unchanged.
pub const ISecretSharePayload = lan_share_core.ISecretSharePayload;

// Not ported: IShareS3Credentials, IShareEncryptionKey, IShareGeocodingKey, IDatabaseSharePayload,
// IConflictResolution, ConflictResolver, IShareDatabaseConfig and the background task types (the database share of
// psi dbs and the desktop app, not used by psi secrets).

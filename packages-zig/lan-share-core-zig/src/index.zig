//
// Platform-agnostic LAN-share payload types. In TypeScript this zero-dependency package is shared by desktop (the
// Node `api` package, writing to the OS vault) and mobile.
//

//
// Share payload for a single standalone secret.
//
pub const ISecretSharePayload = struct {
    // Discriminator for payload type ("secret").
    type: []const u8,

    // The name of the secret in the sender's vault.
    name: []const u8,

    // The category of the secret being shared ("s3-credentials", "encryption-key" or "api-key").
    secretType: []const u8,

    // JSON string containing the secret value, same format as the vault value field.
    value: []const u8,
};

// Not ported: IShareS3Credentials, IShareEncryptionKey, IShareGeocodingKey, IDatabaseSharePayload,
// IConflictResolution, ConflictResolver, IShareSecretStore, IShareResolvedKeys and importShareSecrets (the database
// share of psi dbs send and receive, not used by psi secrets).

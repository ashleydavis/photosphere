//
// Represents a database configuration entry with vault key references,
// used as input to resolveDatabaseSharePayload and output of importDatabasePayload.
//
export interface IShareDatabaseConfig {
    // Human-readable display name.
    name: string;

    // Optional description of this database.
    description: string;

    // Absolute filesystem path (or S3 path) to the database directory.
    path: string;

    // Optional origin string from the database config.
    origin?: string;

    // Vault secret name for S3 credentials.
    s3Key?: string;

    // Vault secret name for the encryption key pair.
    encryptionKey?: string;

    // Vault secret name for the geocoding API key.
    geocodingKey?: string;
}

//
// Resolved S3 credentials included in a share payload.
//
export interface IShareS3Credentials {
    // The vault key name used by the sender.
    name: string;

    // AWS region (e.g. "us-east-1").
    region: string;

    // Access key ID for authentication.
    accessKeyId: string;

    // Secret access key for authentication.
    secretAccessKey: string;

    // Optional custom endpoint URL (for non-AWS S3-compatible services).
    endpoint?: string;
}

//
// Resolved encryption key pair included in a share payload.
//
export interface IShareEncryptionKey {
    // The vault key name used by the sender.
    name: string;

    // PEM-encoded PKCS#8 private key.
    privateKeyPem: string;

    // PEM-encoded SPKI public key. Optional -- receivers derive it from the private key when omitted.
    publicKeyPem?: string;
}

//
// Resolved geocoding API key included in a share payload.
//
export interface IShareGeocodingKey {
    // The vault key name used by the sender.
    name: string;

    // The API key value.
    apiKey: string;
}

//
// Share payload for a full database configuration with all resolved secrets.
//
export interface IDatabaseSharePayload {
    // Discriminator for payload type.
    type: "database";

    // Human-readable name for the database.
    name: string;

    // Description of the database.
    description: string;

    // Filesystem or S3 path to the database.
    path: string;

    // Optional origin string from the database config.
    origin?: string;

    // Resolved S3 credentials, if the database uses S3 storage.
    s3Credentials?: IShareS3Credentials;

    // Resolved encryption key pair, if the database uses encryption.
    encryptionKey?: IShareEncryptionKey;

    // Resolved geocoding API key, if configured.
    geocodingKey?: IShareGeocodingKey;
}

//
// Share payload for a single standalone secret.
//
export interface ISecretSharePayload {
    // Discriminator for payload type.
    type: "secret";

    // The name of the secret in the sender's vault.
    name: string;

    // The category of the secret being shared.
    secretType: "s3-credentials" | "encryption-key" | "api-key";

    // JSON string containing the secret value, same format as the vault value field.
    value: string;
}

//
// Resolution chosen by the user when an incoming secret name conflicts with
// an existing vault entry.
//
export interface IConflictResolution {
    // 'replace': overwrite the existing vault entry.
    // 'reuse': skip importing; keep the existing entry as-is.
    // 'rename': save the incoming secret under a different name.
    action: "replace" | "reuse" | "rename";

    // Required when action is 'rename'; the new vault key name to use.
    newName?: string;
}

//
// Callback invoked by importDatabasePayload when an incoming secret's name
// already exists in the vault. Returns how to resolve the conflict.
//
export type ConflictResolver = (secretName: string, secretType: string) => Promise<IConflictResolution>;

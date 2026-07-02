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

//
// Input data for the "receive-share" background task, which hosts a receiver
// on the LAN and waits for a sender to deliver a share payload.
//
export interface IReceiveShareTaskData {
    // The pairing code the receiver advertises (entered by the user off the sender).
    code: string;
}

//
// Result of the "receive-share" background task.
//
export interface IReceiveShareTaskResult {
    // Payload delivered by a sender, or null if the receiver timed out or was cancelled.
    payload: IDatabaseSharePayload | ISecretSharePayload | null;
}

//
// Network endpoint of a discovered share receiver. Structurally identical to
// lan-share's IReceiverEndpoint; defined here so neither api nor user-interface
// has to depend on the Node-only lan-share package.
//
export interface IShareReceiverEndpoint {
    // IP address of the receiver.
    address: string;

    // HTTPS port the receiver is listening on.
    port: number;

    // SHA-256 fingerprint of the receiver's TLS certificate, for certificate pinning.
    certFingerprint: string;
}

//
// Input data for the "find-receiver" background task, which listens for a
// receiver's UDP broadcast for this share session.
//
export interface IFindReceiverTaskData {
    // The pairing code for this share session.
    code: string;
}

//
// Result of the "find-receiver" background task.
//
export interface IFindReceiverTaskResult {
    // The discovered receiver endpoint, or null if discovery timed out or was cancelled.
    endpoint: IShareReceiverEndpoint | null;
}

//
// Input data for the "send-payload" background task, which delivers a payload
// to a previously discovered receiver over HTTPS.
//
export interface ISendPayloadTaskData {
    // The share payload to deliver to the receiver.
    payload: IDatabaseSharePayload | ISecretSharePayload;

    // The pairing code used to verify the receiver.
    code: string;

    // The receiver endpoint discovered by the "find-receiver" task.
    endpoint: IShareReceiverEndpoint;
}

//
// Result of the "send-payload" background task.
//
export interface ISendPayloadTaskResult {
    // True if the receiver accepted the payload.
    success: boolean;
}

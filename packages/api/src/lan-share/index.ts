// The LAN-share payload types and the conflict-resolution types now live in the zero-dependency
// lan-share-core package, so mobile (which cannot import this Node package) can share them and the
// import logic. Imported for local use by the task types below and re-exported so existing
// `from "api"` importers are unchanged.
import type { IDatabaseSharePayload, ISecretSharePayload } from "lan-share-core";
export type {
    IShareS3Credentials,
    IShareEncryptionKey,
    IShareGeocodingKey,
    IDatabaseSharePayload,
    ISecretSharePayload,
    IConflictResolution,
    ConflictResolver,
} from "lan-share-core";

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

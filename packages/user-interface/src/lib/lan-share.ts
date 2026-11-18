// The LAN-share payload types and the conflict-resolution types now live in the zero-dependency
// lan-share-core package, so mobile (which cannot import this Node package) can share them and the
// import logic. Imported for local use by the task types below and re-exported so existing
// `from "api"` importers are unchanged.
import type { IDatabaseSharePayload, ISecretSharePayload } from "./lan-share-core";
export type {
    IShareS3Credentials,
    IShareEncryptionKey,
    IShareGeocodingKey,
    IDatabaseSharePayload,
    ISecretSharePayload,
    IConflictResolution,
} from "./lan-share-core";

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
// Result of the "find-receiver" background task.
//
export interface IFindReceiverTaskResult {
    // The discovered receiver endpoint, or null if discovery timed out or was cancelled.
    endpoint: IShareReceiverEndpoint | null;
}

//
// Result of the "send-payload" background task.
//
export interface ISendPayloadTaskResult {
    // True if the receiver accepted the payload.
    success: boolean;
}

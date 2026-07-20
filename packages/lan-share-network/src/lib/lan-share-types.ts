//
// Response body from GET /pairing-code-hash on the receiver.
//
export interface IPairingCodeHashResponse {
    // SHA-256 hash of the pairing code the receiver has on file, hex-encoded.
    codeHash: string;
}

//
// Network endpoint information discovered by the sender via UDP broadcast.
//
export interface IReceiverEndpoint {
    // IP address of the receiver.
    address: string;

    // HTTPS port the receiver is listening on.
    port: number;

    // SHA-256 fingerprint of the receiver's TLS certificate, for certificate pinning.
    certFingerprint: string;
}

//
// The UDP port a sender listens on and a receiver announces to: 54321, or the port PHOTOSPHERE_LAN_SHARE_PORT names. Two
// programs that share on one machine at once must use different ports, or each one hears the other's receiver.
//
export function discoveryPort(): number {
    const text = process.env.PHOTOSPHERE_LAN_SHARE_PORT;
    if (text === undefined) {
        return 54321;
    }
    if (!/^\d+$/.test(text) || Number(text) > 65535) {
        throw new Error(`PHOTOSPHERE_LAN_SHARE_PORT must be a port number, not "${text}".`);
    }
    return Number(text);
}

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

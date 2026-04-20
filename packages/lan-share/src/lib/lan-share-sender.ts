import { createHash } from "crypto";
import { createSocket } from "dgram";
import { request as httpsRequest } from "https";
import type { Socket as DgramSocket } from "dgram";
import type { TLSSocket } from "tls";
import type { IReceiverEndpoint } from "./lan-share-types";

//
// UDP port used for discovery broadcasts.
//
const DISCOVERY_PORT = 54321;

//
// Prefix string for receiver broadcast messages.
//
const BROADCAST_PREFIX = "PSIE_RECV:";

//
// Discovers a receiver on the LAN via UDP broadcast, then sends a payload
// over HTTPS with certificate pinning and pairing code verification.
//
export class LanShareSender {
    // The opaque payload to send to the receiver.
    private payload: unknown;

    // The UDP socket used for listening to receiver broadcasts.
    private udpSocket: DgramSocket | null;

    // Whether the sender has been cancelled.
    private isCancelled: boolean;

    constructor(payload: unknown) {
        this.payload = payload;
        this.udpSocket = null;
        this.isCancelled = false;
    }

    //
    // Listens for receiver UDP broadcasts on the LAN.
    // Returns the receiver endpoint when found, or null on timeout or cancellation.
    //
    async waitForReceiver(timeoutMs: number): Promise<IReceiverEndpoint | null> {
        return new Promise<IReceiverEndpoint | null>((resolve) => {
            this.udpSocket = createSocket({ type: "udp4", reuseAddr: true });

            const timeoutTimer = setTimeout(() => {
                this.cleanupUdp();
                resolve(null);
            }, timeoutMs);

            this.udpSocket.on("message", (message, remoteInfo) => {
                if (this.isCancelled) {
                    return;
                }

                const text = message.toString("utf-8");
                if (!text.startsWith(BROADCAST_PREFIX)) {
                    return;
                }

                // Parse "PSIE_RECV:{port}:{certFingerprint}"
                const parts = text.slice(BROADCAST_PREFIX.length).split(":");
                if (parts.length < 2) {
                    return;
                }

                const port = parseInt(parts[0], 10);
                const certFingerprint = parts.slice(1).join(":"); // fingerprint might contain colons
                if (isNaN(port) || !certFingerprint) {
                    return;
                }

                clearTimeout(timeoutTimer);
                this.cleanupUdp();

                resolve({
                    address: remoteInfo.address,
                    port,
                    certFingerprint,
                });
            });

            this.udpSocket.bind(DISCOVERY_PORT);
        });
    }

    //
    // Sends the payload to the discovered receiver over HTTPS.
    // The certificate fingerprint is pinned to prevent MITM attacks.
    // Returns true on success, false if the pairing code was rejected (403).
    //
    async send(endpoint: IReceiverEndpoint, code: string): Promise<boolean> {
        const pinHash = createHash("sha256").update(code).digest("hex");
        const body = JSON.stringify({ pinHash, payload: this.payload });

        return new Promise<boolean>((resolve, reject) => {
            const requestOptions = {
                hostname: endpoint.address,
                port: endpoint.port,
                path: "/share-payload",
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "Content-Length": Buffer.byteLength(body),
                },
                // Accept self-signed certificates but verify the fingerprint
                rejectUnauthorized: false,
            };

            const request = httpsRequest(requestOptions, (response) => {
                const chunks: Buffer[] = [];
                response.on("data", (chunk: Buffer) => {
                    chunks.push(chunk);
                });
                response.on("end", () => {
                    if (response.statusCode === 403) {
                        resolve(false);
                    }
                    else if (response.statusCode === 200) {
                        resolve(true);
                    }
                    else {
                        reject(new Error(`Unexpected status code: ${response.statusCode}`));
                    }
                });
            });

            // Verify certificate fingerprint on the TLS socket
            request.on("socket", (socket) => {
                const tlsSocket = socket as TLSSocket;
                tlsSocket.on("secureConnect", () => {
                    const cert = tlsSocket.getPeerCertificate();
                    if (cert && cert.raw) {
                        const actualFingerprint = createHash("sha256")
                            .update(cert.raw)
                            .digest("hex");
                        if (actualFingerprint !== endpoint.certFingerprint) {
                            request.destroy(new Error(
                                "Certificate fingerprint mismatch — possible MITM attack. " +
                                `Expected ${endpoint.certFingerprint}, got ${actualFingerprint}`
                            ));
                        }
                    }
                });
            });

            request.on("error", (error) => {
                reject(error);
            });

            request.write(body);
            request.end();
        });
    }

    //
    // Cancels the sender, cleaning up the UDP discovery socket.
    //
    cancel(): void {
        this.isCancelled = true;
        this.cleanupUdp();
    }

    //
    // Closes the UDP socket if it is open.
    //
    private cleanupUdp(): void {
        if (this.udpSocket) {
            this.udpSocket.close();
            this.udpSocket = null;
        }
    }
}

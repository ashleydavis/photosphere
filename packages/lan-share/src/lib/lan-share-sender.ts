import { createHash } from "crypto";
import { createSocket } from "dgram";
import { request as httpsRequest } from "https";
import type { Socket as DgramSocket } from "dgram";
import type { TLSSocket } from "tls";
import type { IReceiverEndpoint, IPairingCodeHashResponse } from "./lan-share-types";

//
// UDP port used for discovery broadcasts.
//
const DISCOVERY_PORT = 54321;

//
// Prefix string for receiver broadcast messages.
//
const BROADCAST_PREFIX = "PSIE_RECV:";

//
// Generates a random 4-digit pairing code (1000–9999).
//
function generatePairingCode(): string {
    const code = Math.floor(1000 + Math.random() * 9000);
    return String(code);
}

//
// Discovers a receiver on the LAN via UDP broadcast, then sends a payload
// over HTTPS with certificate pinning and mutual pairing code verification.
//
export class LanShareSender {
    // The opaque payload to send to the receiver.
    private payload: unknown;

    // The UDP socket used for listening to receiver broadcasts.
    private udpSocket: DgramSocket | null;

    // Whether the sender has been cancelled.
    private isCancelled: boolean;

    // The 4-digit pairing code displayed to the user.
    readonly pairingCode: string;

    constructor(payload: unknown, pairingCode?: string) {
        this.payload = payload;
        this.pairingCode = pairingCode ?? generatePairingCode();
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
    // Makes a cert-pinned HTTPS request to the receiver and returns the parsed response body.
    //
    private makeRequest(endpoint: IReceiverEndpoint, method: string, path: string, requestBody?: string): Promise<{ statusCode: number; body: string }> {
        return new Promise((resolve, reject) => {
            const options = {
                hostname: endpoint.address,
                port: endpoint.port,
                path,
                method,
                headers: requestBody
                    ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(requestBody) }
                    : {},
                rejectUnauthorized: false,
            };

            const req = httpsRequest(options, (response) => {
                const chunks: Buffer[] = [];
                response.on("data", (chunk: Buffer) => {
                    chunks.push(chunk);
                });
                response.on("end", () => {
                    resolve({ statusCode: response.statusCode!, body: Buffer.concat(chunks).toString("utf-8") });
                });
            });

            req.on("socket", (socket) => {
                const tlsSocket = socket as TLSSocket;
                tlsSocket.on("secureConnect", () => {
                    const cert = tlsSocket.getPeerCertificate();
                    if (cert && cert.raw) {
                        const actualFingerprint = createHash("sha256")
                            .update(cert.raw)
                            .digest("hex");
                        if (actualFingerprint !== endpoint.certFingerprint) {
                            req.destroy(new Error(
                                "Certificate fingerprint mismatch — possible MITM attack. " +
                                `Expected ${endpoint.certFingerprint}, got ${actualFingerprint}`
                            ));
                        }
                    }
                });
            });

            req.on("error", reject);

            if (requestBody) {
                req.write(requestBody);
            }
            req.end();
        });
    }

    //
    // Sends the payload to the discovered receiver over HTTPS.
    // First calls GET /pairing-code-hash to verify the receiver knows the same pairing code.
    // Then posts the payload with the code hash for a second layer of verification.
    // Returns true on success, false if the pairing code is rejected by either check.
    //
    async send(endpoint: IReceiverEndpoint): Promise<boolean> {
        const codeHash = createHash("sha256").update(this.pairingCode).digest("hex");

        // Pre-send verification: confirm the receiver has the same pairing code.
        const hashResponse = await this.makeRequest(endpoint, "GET", "/pairing-code-hash");
        if (hashResponse.statusCode !== 200) {
            return false;
        }

        const hashBody = JSON.parse(hashResponse.body) as IPairingCodeHashResponse;
        if (hashBody.codeHash !== codeHash) {
            return false;
        }

        // Send the payload with the code hash for the receiver's second-layer check.
        const payloadBody = JSON.stringify({ codeHash, payload: this.payload });
        const sendResponse = await this.makeRequest(endpoint, "POST", "/share-payload", payloadBody);

        if (sendResponse.statusCode === 403) {
            return false;
        }

        if (sendResponse.statusCode === 200) {
            return true;
        }

        throw new Error(`Unexpected status code: ${sendResponse.statusCode}`);
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

import { createServer as createHttpsServer } from "https";
import { createSocket } from "dgram";
import { createHash, generateKeyPairSync, createSign } from "crypto";
import type { Server as HttpsServer } from "https";
import type { Socket as DgramSocket } from "dgram";
import type { IncomingMessage, ServerResponse } from "http";
import type { IReceiverInfo } from "./lan-share-types";

//
// Maximum number of failed pin attempts before the receiver aborts.
//
const MAX_PIN_FAILURES = 3;

//
// Interval in milliseconds between UDP broadcast announcements.
//
const BROADCAST_INTERVAL_MS = 1000;

//
// UDP port used for discovery broadcasts.
//
const DISCOVERY_PORT = 54321;

//
// Generates a self-signed TLS certificate and private key at runtime.
// Returns the PEM-encoded certificate, private key, and SHA-256 fingerprint.
//
interface ISelfSignedCert {
    // PEM-encoded certificate.
    cert: string;

    // PEM-encoded private key.
    key: string;

    // SHA-256 fingerprint of the certificate in hex.
    fingerprint: string;
}

//
// Creates a self-signed TLS certificate for the HTTPS server.
//
function generateSelfSignedCert(): ISelfSignedCert {
    const keyPair = generateKeyPairSync("rsa", {
        modulusLength: 2048,
        publicKeyEncoding: { type: "spki", format: "pem" },
        privateKeyEncoding: { type: "pkcs8", format: "pem" },
    });

    // Build a minimal self-signed X.509 certificate using Node's crypto.
    // Node 19+ exposes crypto.X509Certificate but not certificate creation,
    // so we use the openssl-compatible approach via the `selfsigned` pattern
    // encoded manually with ASN.1 DER.
    //
    // For simplicity and zero external dependencies, we use the Node built-in
    // `generateKeyPairSync` + a raw TLS approach where the cert is self-signed.
    // We'll use the `tls.createSecureContext` approach instead — Node's HTTPS
    // server accepts PEM cert+key directly.
    //
    // Since Node doesn't have a built-in cert generator, we'll generate
    // a self-signed cert using a small inline ASN.1 builder.
    const cert = buildSelfSignedCert(keyPair.publicKey as string, keyPair.privateKey as string);

    const fingerprint = createHash("sha256")
        .update(extractDerFromPem(cert))
        .digest("hex");

    return {
        cert,
        key: keyPair.privateKey as string,
        fingerprint,
    };
}

//
// Extracts the raw DER bytes from a PEM-encoded string.
//
function extractDerFromPem(pem: string): Buffer {
    const base64 = pem
        .replace(/-----BEGIN [A-Z ]+-----/g, "")
        .replace(/-----END [A-Z ]+-----/g, "")
        .replace(/\s/g, "");
    return Buffer.from(base64, "base64");
}

//
// Builds a minimal self-signed X.509 v3 certificate.
// This avoids any external dependency for certificate generation.
//
function buildSelfSignedCert(publicKeyPem: string, privateKeyPem: string): string {
    // Use Node's native crypto to create a self-signed certificate.
    // Since Node doesn't have createCertificate, we'll use a workaround
    // with the tls module's built-in support.
    //
    // Actually, Node 22+ has `crypto.X509Certificate` for parsing but not creation.
    // We need to use an alternative approach.
    //
    // The simplest zero-dependency approach: use `child_process` to call openssl,
    // but that adds a system dependency. Instead, we'll build the ASN.1 ourselves.

    const publicKeyDer = extractDerFromPem(publicKeyPem);
    const now = new Date();
    const notBefore = now;
    const notAfter = new Date(now.getTime() + 24 * 60 * 60 * 1000); // 1 day validity

    // Build TBSCertificate
    const serialNumber = encodeAsn1Integer(Buffer.from([1]));
    const signatureAlgorithm = encodeAsn1Sequence([
        encodeAsn1Oid([1, 2, 840, 113549, 1, 1, 11]), // sha256WithRSAEncryption
        encodeAsn1Null(),
    ]);
    const issuer = encodeAsn1Sequence([
        encodeAsn1Set([
            encodeAsn1Sequence([
                encodeAsn1Oid([2, 5, 4, 3]), // commonName
                encodeAsn1Utf8String("Photosphere LAN Share"),
            ]),
        ]),
    ]);
    const validity = encodeAsn1Sequence([
        encodeAsn1UtcTime(notBefore),
        encodeAsn1UtcTime(notAfter),
    ]);
    const subject = issuer; // self-signed: subject = issuer

    // version [0] EXPLICIT INTEGER 2 (v3)
    const version = encodeAsn1Explicit(0, encodeAsn1Integer(Buffer.from([2])));

    const tbsCertificate = encodeAsn1Sequence([
        version,
        serialNumber,
        signatureAlgorithm,
        issuer,
        validity,
        subject,
        Buffer.from(publicKeyDer), // SubjectPublicKeyInfo (already a SEQUENCE)
    ]);

    // Sign the TBSCertificate
    const signer = createSign("SHA256");
    signer.update(tbsCertificate);
    const signature = signer.sign(privateKeyPem);

    // Build the full Certificate
    const certificate = encodeAsn1Sequence([
        tbsCertificate,
        signatureAlgorithm,
        encodeAsn1BitString(signature),
    ]);

    // PEM-encode
    const base64Cert = certificate.toString("base64");
    const lines: string[] = [];
    for (let offset = 0; offset < base64Cert.length; offset += 64) {
        lines.push(base64Cert.slice(offset, offset + 64));
    }
    return `-----BEGIN CERTIFICATE-----\n${lines.join("\n")}\n-----END CERTIFICATE-----\n`;
}

//
// ASN.1 DER encoding helpers.
//

function encodeAsn1Length(length: number): Buffer {
    if (length < 0x80) {
        return Buffer.from([length]);
    }
    const bytes: number[] = [];
    let remaining = length;
    while (remaining > 0) {
        bytes.unshift(remaining & 0xff);
        remaining >>= 8;
    }
    return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function encodeAsn1Tag(tag: number, content: Buffer): Buffer {
    return Buffer.concat([Buffer.from([tag]), encodeAsn1Length(content.length), content]);
}

function encodeAsn1Sequence(items: Buffer[]): Buffer {
    return encodeAsn1Tag(0x30, Buffer.concat(items));
}

function encodeAsn1Set(items: Buffer[]): Buffer {
    return encodeAsn1Tag(0x31, Buffer.concat(items));
}

function encodeAsn1Integer(value: Buffer): Buffer {
    // Ensure leading zero if high bit is set
    if (value[0] & 0x80) {
        value = Buffer.concat([Buffer.from([0]), value]);
    }
    return encodeAsn1Tag(0x02, value);
}

function encodeAsn1BitString(data: Buffer): Buffer {
    // Prepend unused-bits byte (0)
    const content = Buffer.concat([Buffer.from([0]), data]);
    return encodeAsn1Tag(0x03, content);
}

function encodeAsn1Null(): Buffer {
    return Buffer.from([0x05, 0x00]);
}

function encodeAsn1Oid(components: number[]): Buffer {
    const bytes: number[] = [];
    // First two components are encoded as 40 * c0 + c1
    bytes.push(40 * components[0] + components[1]);
    for (let index = 2; index < components.length; index++) {
        const component = components[index];
        if (component < 128) {
            bytes.push(component);
        }
        else {
            const encodedBytes: number[] = [];
            let remaining = component;
            encodedBytes.unshift(remaining & 0x7f);
            remaining >>= 7;
            while (remaining > 0) {
                encodedBytes.unshift((remaining & 0x7f) | 0x80);
                remaining >>= 7;
            }
            bytes.push(...encodedBytes);
        }
    }
    return encodeAsn1Tag(0x06, Buffer.from(bytes));
}

function encodeAsn1Utf8String(value: string): Buffer {
    return encodeAsn1Tag(0x0c, Buffer.from(value, "utf-8"));
}

function encodeAsn1UtcTime(date: Date): Buffer {
    const year = date.getUTCFullYear() % 100;
    const month = date.getUTCMonth() + 1;
    const day = date.getUTCDate();
    const hours = date.getUTCHours();
    const minutes = date.getUTCMinutes();
    const seconds = date.getUTCSeconds();
    const timeStr =
        String(year).padStart(2, "0") +
        String(month).padStart(2, "0") +
        String(day).padStart(2, "0") +
        String(hours).padStart(2, "0") +
        String(minutes).padStart(2, "0") +
        String(seconds).padStart(2, "0") +
        "Z";
    return encodeAsn1Tag(0x17, Buffer.from(timeStr, "ascii"));
}

function encodeAsn1Explicit(tagNumber: number, content: Buffer): Buffer {
    const tag = 0xa0 | tagNumber;
    return encodeAsn1Tag(tag, content);
}

//
// Generates a random 4-digit pairing code.
//
function generatePairingCode(): string {
    const code = Math.floor(1000 + Math.random() * 9000);
    return String(code);
}

//
// Request body sent by the sender to deliver a payload.
//
interface IShareRequest {
    // SHA-256 hash of the pairing code, hex-encoded.
    pinHash: string;

    // The opaque JSON payload to deliver.
    payload: unknown;
}

//
// Hosts an HTTPS server on the LAN and broadcasts availability via UDP.
// Accepts a single payload delivery from a sender after pairing code verification.
//
export class LanShareReceiver {
    // Timeout in milliseconds before the receiver gives up waiting.
    private timeoutMs: number;

    // The generated 4-digit pairing code.
    private code: string | null;

    // SHA-256 hash of the pairing code, for comparison.
    private codeHash: string | null;

    // The HTTPS server instance.
    private httpsServer: HttpsServer | null;

    // The UDP socket for broadcasting availability.
    private udpSocket: DgramSocket | null;

    // Interval timer for periodic UDP broadcasts.
    private broadcastTimer: NodeJS.Timeout | null;

    // Number of failed pin attempts so far.
    private pinFailures: number;

    // Resolve function for the receive() promise.
    private receiveResolve: ((payload: unknown) => void) | null;

    // Timeout timer for the overall receive operation.
    private timeoutTimer: NodeJS.Timeout | null;

    // Whether the receiver has been cancelled or completed.
    private isDone: boolean;

    constructor(timeoutMs: number) {
        this.timeoutMs = timeoutMs;
        this.code = null;
        this.codeHash = null;
        this.httpsServer = null;
        this.udpSocket = null;
        this.broadcastTimer = null;
        this.pinFailures = 0;
        this.receiveResolve = null;
        this.timeoutTimer = null;
        this.isDone = false;
    }

    //
    // Starts the receiver: generates a pairing code, creates an HTTPS server,
    // and begins broadcasting availability via UDP.
    // Returns the pairing code so the caller can display it to the user.
    //
    async start(): Promise<IReceiverInfo> {
        this.code = generatePairingCode();
        this.codeHash = createHash("sha256").update(this.code).digest("hex");

        const selfSigned = generateSelfSignedCert();

        // Create HTTPS server
        this.httpsServer = createHttpsServer(
            { key: selfSigned.key, cert: selfSigned.cert },
            (request: IncomingMessage, response: ServerResponse) => this.handleRequest(request, response)
        );

        // Listen on a random port
        const port = await new Promise<number>((resolve) => {
            this.httpsServer!.listen(0, () => {
                const address = this.httpsServer!.address();
                if (address && typeof address !== "string") {
                    resolve(address.port);
                }
            });
        });

        // Start UDP broadcast
        this.udpSocket = createSocket("udp4");
        this.udpSocket.bind(() => {
            this.udpSocket!.setBroadcast(true);
            const message = Buffer.from(`PSIE_RECV:${port}:${selfSigned.fingerprint}`);
            this.broadcastTimer = setInterval(() => {
                this.udpSocket!.send(message, 0, message.length, DISCOVERY_PORT, "255.255.255.255");
            }, BROADCAST_INTERVAL_MS);
            // Send first broadcast immediately
            this.udpSocket!.send(message, 0, message.length, DISCOVERY_PORT, "255.255.255.255");
        });

        return { code: this.code };
    }

    //
    // Waits for a valid payload to arrive from a sender.
    // Returns the payload on success, or null on timeout or cancellation.
    //
    async receive(): Promise<unknown> {
        return new Promise<unknown>((resolve) => {
            this.receiveResolve = resolve;
            this.timeoutTimer = setTimeout(() => {
                this.complete(null);
            }, this.timeoutMs);
        });
    }

    //
    // Cancels the receiver, cleaning up all resources.
    // The receive() promise resolves with null.
    //
    cancel(): void {
        this.complete(null);
    }

    //
    // Handles an incoming HTTP request to the HTTPS server.
    //
    private handleRequest(request: IncomingMessage, response: ServerResponse): void {
        if (request.method !== "POST" || request.url !== "/share-payload") {
            response.writeHead(404, { "Content-Type": "application/json" });
            response.end(JSON.stringify({ error: "Not found" }));
            return;
        }

        const chunks: Buffer[] = [];
        request.on("data", (chunk: Buffer) => {
            chunks.push(chunk);
        });
        request.on("end", () => {
            const body = Buffer.concat(chunks).toString("utf-8");
            let parsed: IShareRequest;
            try {
                parsed = JSON.parse(body) as IShareRequest;
            }
            catch {
                response.writeHead(400, { "Content-Type": "application/json" });
                response.end(JSON.stringify({ error: "Invalid JSON" }));
                return;
            }

            // Verify the pairing code
            if (parsed.pinHash !== this.codeHash) {
                this.pinFailures++;
                if (this.pinFailures >= MAX_PIN_FAILURES) {
                    response.writeHead(403, { "Content-Type": "application/json" });
                    response.end(JSON.stringify({ error: "Too many failed attempts" }));
                    this.complete(null);
                    return;
                }
                response.writeHead(403, { "Content-Type": "application/json" });
                response.end(JSON.stringify({ error: "Invalid pairing code" }));
                return;
            }

            // Pin matches — accept the payload
            response.writeHead(200, { "Content-Type": "application/json" });
            response.end(JSON.stringify({ success: true }));
            this.complete(parsed.payload);
        });
    }

    //
    // Completes the receive operation, resolving the promise and cleaning up resources.
    //
    private complete(payload: unknown): void {
        if (this.isDone) {
            return;
        }
        this.isDone = true;

        if (this.timeoutTimer) {
            clearTimeout(this.timeoutTimer);
            this.timeoutTimer = null;
        }

        if (this.broadcastTimer) {
            clearInterval(this.broadcastTimer);
            this.broadcastTimer = null;
        }

        if (this.udpSocket) {
            this.udpSocket.close();
            this.udpSocket = null;
        }

        if (this.httpsServer) {
            this.httpsServer.close();
            this.httpsServer = null;
        }

        if (this.receiveResolve) {
            this.receiveResolve(payload);
            this.receiveResolve = null;
        }
    }
}

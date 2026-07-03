//
// Minimal `crypto` shim for the embedded mobile worker.
//
// The database read path needs exactly one crypto capability: `createHash('sha256')`, used by
// `packages/serialization` to verify the checksum appended to every serialized file. This is
// provided with a pure-JS SHA-256 (`hash.js`) so no native crypto is required. The asymmetric-key
// functions (`createPrivateKey`/`createPublicKey`) are only used when opening an ENCRYPTED database,
// which is out of scope for this slice, so they throw the loud NOT IMPLEMENTED error.
//

import { Buffer } from "buffer";
import createHashLib from "create-hash";
import { callHost } from "./host-access";

//
// The subset of native host functions the crypto shim calls for RSA key generation and signing.
//
interface ICryptoHost {
    // Generates an RSA key pair and returns a JSON string { privateKeyPem, publicKeyPem }.
    cryptoGenerateRsaKeyPair: (modulusLength: number) => string;

    // Signs base64-encoded data with SHA256withRSA using the PEM private key; returns a base64 signature.
    cryptoSignSha256: (privateKeyPem: string, dataBase64: string) => string;
}

//
// The JSON shape native returns from cryptoGenerateRsaKeyPair.
//
interface IRsaKeyPairJson {
    // PEM-encoded PKCS#8 private key.
    privateKeyPem: string;

    // PEM-encoded SPKI public key.
    publicKeyPem: string;
}

//
// PEM encoding descriptor accepted in generateKeyPairSync options (type/format); ignored at runtime
// because native always returns pkcs8/spki PEM.
//
interface IKeyEncoding {
    // The key encoding type (e.g. "pkcs8", "spki").
    type: string;

    // The key format (always "pem" here).
    format: string;
}

//
// Options accepted by generateKeyPairSync, matching the subset LAN-share passes.
//
interface IKeyPairOptions {
    // RSA modulus length in bits.
    modulusLength?: number;

    // Public key output encoding (spki/pem).
    publicKeyEncoding?: IKeyEncoding;

    // Private key output encoding (pkcs8/pem).
    privateKeyEncoding?: IKeyEncoding;
}

//
// The PEM key pair returned by generateKeyPairSync.
//
interface IKeyPairResult {
    // PEM-encoded public key.
    publicKey: string;

    // PEM-encoded private key.
    privateKey: string;
}

//
// A Node `Sign`-compatible object: chained update(...) and sign(privateKeyPem) returning a Buffer.
//
interface ISign {
    // Feeds data into the signer.
    update(data: Buffer | Uint8Array | string): ISign;

    // Finalises the signature over the accumulated data with the given PEM private key.
    sign(privateKeyPem: string): Buffer;
}

//
// Returns the installed native host bridge for crypto, throwing a clear error if it is missing.
//
function getCryptoHost(): ICryptoHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; crypto shim cannot run.");
    }

    return host as ICryptoHost;
}

//
// The platform string used in NOT IMPLEMENTED messages.
//
function hostPlatform(): string {
    const platform = (globalThis as any).host?.platform;
    return typeof platform === "string" ? platform : "mobile";
}

//
// A Node `Hash`-compatible object: chained `update(...)` and `digest()` (Buffer) / `digest('hex')`.
//
interface IHash {
    // Feeds data into the hash.
    update(data: Buffer | Uint8Array | string): IHash;

    // Finalises the hash; returns a hex string when encoding is 'hex', otherwise a Buffer.
    digest(encoding?: string): Buffer | string;
}

//
// Creates a hash object. Backed by `create-hash` (the browserify createHash), which supports the
// algorithms the storage/database code uses (sha256 for serialization checksums, md5 for asset
// hashing), so it matches Node's crypto.createHash without a native crypto module.
//
export function createHash(algorithm: string): IHash {
    return createHashLib(algorithm) as unknown as IHash;
}

//
// The asymmetric-key and cipher functions below are only used when opening an ENCRYPTED database,
// which is out of scope for this slice. They are exported so the encryption/storage modules bundle,
// but each fails loudly if actually called.
//

//
// Throws the verbatim NOT IMPLEMENTED error for an unsupported crypto function.
//
function notImplemented(name: string): never {
    throw new Error(`NOT IMPLEMENTED: native host function "${name}" is not implemented yet on ${hostPlatform()}. Implement it ASAP.`);
}

//
// The crypto KeyObject type, used only in type position by the bundled code.
//
export class KeyObject {}

//
// The crypto Decipher type, used only in type position by the bundled code.
//
export class Decipher {}

//
// Encrypted-database only; fails loudly.
//
export function createPrivateKey(): never {
    notImplemented("cryptoCreatePrivateKey");
}

//
// Encrypted-database only; fails loudly.
//
export function createPublicKey(): never {
    notImplemented("cryptoCreatePublicKey");
}

//
// Generates an RSA key pair via the native crypto host, returning PEM strings. Used by LAN-share's
// receiver to build its self-signed TLS certificate. The encoding options are accepted for API
// compatibility but ignored: native always returns pkcs8 (private) and spki (public) PEM, which is
// exactly what LAN-share requests.
//
export function generateKeyPairSync(_type: string, options?: IKeyPairOptions): IKeyPairResult {
    const host = getCryptoHost();
    const modulusLength = options && typeof options.modulusLength === "number" ? options.modulusLength : 2048;
    const resultJson = callHost(() => host.cryptoGenerateRsaKeyPair(modulusLength)) as string;
    const parsed = JSON.parse(resultJson) as IRsaKeyPairJson;
    return { publicKey: parsed.publicKeyPem, privateKey: parsed.privateKeyPem };
}

//
// Creates a SHA-256 RSA signer via the native crypto host. Accumulates data through update() and
// produces the signature over all of it with sign(privateKeyPem). Used by LAN-share's receiver to
// self-sign its certificate. The algorithm argument is accepted for API compatibility; native always
// uses SHA256withRSA.
//
export function createSign(_algorithm: string): ISign {
    const chunks: Buffer[] = [];
    const signer: ISign = {
        update(data: Buffer | Uint8Array | string): ISign {
            chunks.push(typeof data === "string" ? Buffer.from(data, "utf8") : Buffer.from(data));
            return signer;
        },
        sign(privateKeyPem: string): Buffer {
            const host = getCryptoHost();
            const data = Buffer.concat(chunks);
            const signatureBase64 = callHost(() => host.cryptoSignSha256(privateKeyPem, data.toString("base64"))) as string;
            return Buffer.from(signatureBase64, "base64");
        },
    };
    return signer;
}

//
// Encrypted-database only; fails loudly.
//
export function createCipheriv(): never {
    notImplemented("cryptoCreateCipheriv");
}

//
// Encrypted-database only; fails loudly.
//
export function createDecipheriv(): never {
    notImplemented("cryptoCreateDecipheriv");
}

//
// Encrypted-database only; fails loudly.
//
export function privateDecrypt(): never {
    notImplemented("cryptoPrivateDecrypt");
}

//
// Encrypted-database only; fails loudly.
//
export function publicEncrypt(): never {
    notImplemented("cryptoPublicEncrypt");
}

//
// Encrypted-database only; fails loudly.
//
export function randomBytes(): never {
    notImplemented("cryptoRandomBytes");
}

//
// The default export mirrors `import crypto from "crypto"` / `"node:crypto"`.
//
const cryptoModule = {
    createHash,
    createSign,
    createPrivateKey,
    createPublicKey,
    generateKeyPairSync,
    createCipheriv,
    createDecipheriv,
    privateDecrypt,
    publicEncrypt,
    randomBytes,
    KeyObject,
    Decipher,
};

export default cryptoModule;

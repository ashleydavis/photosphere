//
// `crypto` shim for the embedded mobile worker.
//
// Capabilities, split by risk:
//   - Hashing (`createHash`) is pure JS via `create-hash`, used by `packages/serialization` to verify
//     the checksum appended to every serialized file, and by the encrypted-file header.
//   - The RSA operations (`publicEncrypt`/`privateDecrypt` and the `createPrivateKey`/`createPublicKey`
//     /`KeyObject.export` key handling around them) run NATIVELY via host functions, because
//     `encrypt-buffer.ts`/`encrypt-stream.ts` encrypt the AES key with RSA using Node's default
//     OAEP padding (SHA-1 OAEP + MGF1). The on-disk format is pinned to that padding and to RSA-4096
//     (the encrypted key is a fixed 512-byte slice), so hand-rolling OAEP in JS would risk making
//     every existing encrypted database permanently unreadable. Platform crypto gets OAEP right by
//     construction, so it is used for the once-per-file RSA step.
//   - The bulk symmetric work (`createCipheriv`/`createDecipheriv` for AES-256-CBC), HMAC-SHA256
//     (`createHmac`, used by the S3 SigV4 signer) and `randomBytes` run in pure JS (`browserify-aes`,
//     `create-hmac`, `randombytes`), consistent with the `create-hash`/`hash.js`/`pako` precedent,
//     where the format is unambiguous and a round-trip test is cheap.
//

import { Buffer } from "buffer";
import createHashLib from "create-hash";
import createHmacLib from "create-hmac";
import { createCipheriv as aesCreateCipheriv, createDecipheriv as aesCreateDecipheriv, type ICipheriv } from "browserify-aes";
import randomBytesLib from "randombytes";
import { callHost } from "./host-access";

//
// The subset of native host functions the crypto shim calls for RSA key generation and signing.
//
interface ICryptoHost {
    // Generates an RSA key pair and returns a JSON string { privateKeyPem, publicKeyPem }.
    cryptoGenerateRsaKeyPair: (modulusLength: number) => string;

    // Signs base64-encoded data with SHA256withRSA using the PEM private key; returns a base64 signature.
    cryptoSignSha256: (privateKeyPem: string, dataBase64: string) => string;

    // RSA-encrypts base64-encoded data with the SPKI PEM public key using OAEP (SHA-1 digest + MGF1,
    // matching Node's default padding); returns the base64 ciphertext.
    cryptoPublicEncryptOaepSha1: (publicKeyPem: string, dataBase64: string) => string;

    // RSA-decrypts base64-encoded data with the PKCS#8 PEM private key using OAEP (SHA-1 digest + MGF1);
    // returns the base64 plaintext.
    cryptoPrivateDecryptOaepSha1: (privateKeyPem: string, dataBase64: string) => string;

    // Derives the SPKI PEM public key from a PKCS#8 PEM private key.
    cryptoPublicKeyFromPrivate: (privateKeyPem: string) => string;
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
// The kind of key a KeyObject wraps.
//
type KeyObjectKind = "public" | "private";

//
// Options accepted by KeyObject.export: the encoding type (spki/pkcs8) and format (pem/der). The type
// is accepted for API compatibility but not transformed: native returns SPKI (public) / PKCS#8
// (private) PEM already, so a public KeyObject always exports SPKI and a private one PKCS#8.
//
export interface IKeyExportOptions {
    // The key encoding type: "spki" for a public key, "pkcs8" for a private key.
    type: string;

    // The output format: "pem" for the PEM string, "der" for the raw DER bytes.
    format: string;
}

//
// A key input as accepted by createPrivateKey/createPublicKey/publicEncrypt/privateDecrypt: a PEM
// string, a KeyObject, or an options object carrying the PEM under `key`.
//
export interface IKeyInputObject {
    // The PEM key material.
    key: string | Buffer | KeyObject;
}

//
// The union of accepted key inputs.
//
export type KeyInput = string | Buffer | KeyObject | IKeyInputObject;

//
// Strips the PEM armour and whitespace from a PEM block and returns the raw DER bytes it base64-encodes.
//
function derFromPem(pem: string): Buffer {
    const body = pem
        .replace(/-----BEGIN [^-]+-----/g, "")
        .replace(/-----END [^-]+-----/g, "")
        .replace(/\s+/g, "");
    return Buffer.from(body, "base64");
}

//
// A Node `KeyObject`-compatible wrapper. It holds the key as PEM (the form native produces and
// consumes) and exports it as either PEM (the stored string) or DER (the base64-decoded body). The
// DER export is on the encrypted-file read path: `hashPublicKey` (key-utils.ts) exports the public
// key as SPKI DER and SHA-256s it into the file header, so DER must be exact, not PEM-only.
//
export class KeyObject {
    //
    // The key material in PEM form (SPKI for a public key, PKCS#8 for a private key).
    //
    private readonly keyPem: string;

    //
    // Whether this wraps a public or private key.
    //
    private readonly keyKind: KeyObjectKind;

    //
    // The asymmetric key algorithm, always RSA here (matches the Node KeyObject property some code reads).
    //
    readonly asymmetricKeyType = "rsa";

    //
    // Builds a KeyObject over the given PEM and kind.
    //
    constructor(keyPem: string, keyKind: KeyObjectKind) {
        this.keyPem = keyPem;
        this.keyKind = keyKind;
    }

    //
    // The wrapped PEM string.
    //
    get pem(): string {
        return this.keyPem;
    }

    //
    // Whether this is a public or private key.
    //
    get kind(): KeyObjectKind {
        return this.keyKind;
    }

    //
    // Exports the key: the stored PEM string for format "pem", or the DER bytes (base64-decoded PEM
    // body) for format "der".
    //
    export(options: IKeyExportOptions): string | Buffer {
        if (options.format === "der") {
            return derFromPem(this.keyPem);
        }
        return this.keyPem;
    }
}

//
// A Node `Decipher`-compatible class: chained update(...) and a final(). The AES decipher the shim
// returns from createDecipheriv structurally satisfies it. Kept as a runtime value export (not a bare
// type) because `encrypt-stream.ts` imports `Decipher` from crypto, and the bundler needs the binding.
//
export class Decipher {
    // Decrypts the next chunk; overridden by the concrete browserify decipher returned to callers.
    update(_data: Buffer | Uint8Array): Buffer {
        throw new Error("Decipher.update is abstract in the crypto shim.");
    }

    // Finalises decryption; overridden by the concrete browserify decipher returned to callers.
    final(): Buffer {
        throw new Error("Decipher.final is abstract in the crypto shim.");
    }
}

//
// A Node `Cipher`-compatible type: chained update(...) and a final().
//
export type Cipher = ICipheriv;

//
// Resolves the PEM string from any accepted key input.
//
function pemFromKeyInput(key: KeyInput): string {
    if (typeof key === "string") {
        return key;
    }
    if (Buffer.isBuffer(key)) {
        return key.toString("utf8");
    }
    if (key instanceof KeyObject) {
        return key.pem;
    }
    if (key && typeof key === "object" && "key" in key) {
        return pemFromKeyInput((key as IKeyInputObject).key);
    }
    throw new Error("Unsupported key input for the mobile crypto shim (expected a PEM string or KeyObject).");
}

//
// Creates a KeyObject for a private key from a PEM string, an existing KeyObject, or a { key } object.
// A private KeyObject is returned as-is.
//
export function createPrivateKey(key: KeyInput): KeyObject {
    if (key instanceof KeyObject && key.kind === "private") {
        return key;
    }
    return new KeyObject(pemFromKeyInput(key), "private");
}

//
// Creates a KeyObject for a public key. From a PEM string or a public KeyObject it wraps/returns it
// directly; from a private KeyObject or a { key } carrying a private PEM it derives the SPKI public
// key natively (Node's createPublicKey(privateKey) behaviour).
//
export function createPublicKey(key: KeyInput): KeyObject {
    if (key instanceof KeyObject) {
        if (key.kind === "public") {
            return key;
        }
        const host = getCryptoHost();
        const publicPem = callHost(() => host.cryptoPublicKeyFromPrivate(key.pem)) as string;
        return new KeyObject(publicPem, "public");
    }
    return new KeyObject(pemFromKeyInput(key), "public");
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
// Signs data in one call, mirroring Node's `crypto.sign(algorithm, data, key)`. It runs through the
// same native SHA256withRSA signer `createSign` uses, so SHA-256 is the only algorithm it accepts;
// anything else is refused rather than signed with the wrong digest.
//
export function sign(algorithm: string, data: Buffer | Uint8Array, key: KeyInput): Buffer {
    if (algorithm.toLowerCase().replace("-", "") !== "sha256") {
        throw new Error(`crypto.sign only supports sha256 in the mobile worker (was asked for ${algorithm}); the native signer is SHA256withRSA.`);
    }

    const host = getCryptoHost();
    const privateKeyPem = pemFromKeyInput(key);
    const dataBase64 = Buffer.from(data).toString("base64");
    const signatureBase64 = callHost(() => host.cryptoSignSha256(privateKeyPem, dataBase64)) as string;
    return Buffer.from(signatureBase64, "base64");
}

//
// Creates a symmetric cipher (AES-256-CBC on the encryption path). Pure JS via `browserify-aes`, which
// implements Node's createCipheriv exactly (PKCS#7 padding, CBC), so the on-disk format is unambiguous.
//
export function createCipheriv(algorithm: string, key: Buffer | Uint8Array, iv: Buffer | Uint8Array): Cipher {
    return aesCreateCipheriv(algorithm, key, iv);
}

//
// Creates a symmetric decipher (AES-256-CBC on the decryption path). Pure JS via `browserify-aes`.
//
export function createDecipheriv(algorithm: string, key: Buffer | Uint8Array, iv: Buffer | Uint8Array): Decipher {
    return aesCreateDecipheriv(algorithm, key, iv) as unknown as Decipher;
}

//
// RSA-decrypts the encrypted AES key with the PKCS#8 private key. Runs natively (OAEP SHA-1 + MGF1,
// Node's default padding) so the padding matches every existing encrypted-file header.
//
export function privateDecrypt(privateKey: KeyInput, data: Buffer | Uint8Array): Buffer {
    const host = getCryptoHost();
    const privateKeyPem = pemFromKeyInput(privateKey);
    const dataBase64 = Buffer.from(data).toString("base64");
    const resultBase64 = callHost(() => host.cryptoPrivateDecryptOaepSha1(privateKeyPem, dataBase64)) as string;
    return Buffer.from(resultBase64, "base64");
}

//
// RSA-encrypts the AES key with the SPKI public key. Runs natively (OAEP SHA-1 + MGF1, Node's default
// padding) so the ciphertext matches what desktop produces and can be decrypted by the same key.
//
export function publicEncrypt(publicKey: KeyInput, data: Buffer | Uint8Array): Buffer {
    const host = getCryptoHost();
    const publicKeyPem = pemFromKeyInput(publicKey);
    const dataBase64 = Buffer.from(data).toString("base64");
    const resultBase64 = callHost(() => host.cryptoPublicEncryptOaepSha1(publicKeyPem, dataBase64)) as string;
    return Buffer.from(resultBase64, "base64");
}

//
// Returns `size` cryptographically-random bytes. Pure JS via `randombytes` (Node crypto.randomBytes
// off-device; the engine's crypto.getRandomValues on device). Used for the AES key and IV.
//
export function randomBytes(size: number): Buffer {
    return randomBytesLib(size);
}

//
// A Node `Hmac`-compatible object: chained update(...) then a single digest().
//
export interface IHmac {
    // Feeds data into the HMAC.
    update(data: Buffer | Uint8Array | string): IHmac;

    // Finalises the HMAC, returning a Buffer, or a hex/base64 string when an encoding is given.
    digest(): Buffer;
    digest(encoding: string): string;
}

//
// Creates an HMAC (HMAC-SHA256 for the S3 SigV4 signer). Pure JS via `create-hmac`, the same lineage
// as `create-hash`. Exported and added to the default map so `crypto.createHmac` resolves rather than
// being `undefined` on the default-import path.
//
export function createHmac(algorithm: string, key: Buffer | Uint8Array | string): IHmac {
    return createHmacLib(algorithm, key) as unknown as IHmac;
}

//
// Generates a random v4 UUID string. Node's crypto.randomUUID is cryptographically strong; the
// mobile worker only needs this for unique temporary file names (see outputFile's atomic write in
// node-utils), so a Math.random-based v4 UUID is sufficient. It is not suitable for security use.
//
export function randomUUID(): string {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, character => {
        const randomNibble = Math.floor(Math.random() * 16);
        const hexValue = character === "x" ? randomNibble : (randomNibble & 0x3) | 0x8;
        return hexValue.toString(16);
    });
}

//
// The default export mirrors `import crypto from "crypto"` / `"node:crypto"`.
//
const cryptoModule = {
    createHash,
    createHmac,
    createSign,
    sign,
    createPrivateKey,
    createPublicKey,
    generateKeyPairSync,
    createCipheriv,
    createDecipheriv,
    privateDecrypt,
    publicEncrypt,
    randomBytes,
    randomUUID,
    KeyObject,
};

export default cryptoModule;

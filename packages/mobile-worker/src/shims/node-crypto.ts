//
// Minimal `crypto` shim for the embedded mobile worker.
//
// The database read path needs exactly one crypto capability: `createHash('sha256')`, used by
// `packages/serialization` to verify the checksum appended to every serialized file. This is
// provided with a pure-JS SHA-256 (`hash.js`) so no native crypto is required. The asymmetric-key
// functions (`createPrivateKey`/`createPublicKey`) are only used when opening an ENCRYPTED database,
// which is out of scope for this slice, so they throw the loud NOT IMPLEMENTED error.
//

import createHashLib from "create-hash";

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
// Placeholder for the crypto KeyObject type, used only in type position by the bundled code.
//
export class KeyObject {}

//
// Placeholder for the crypto Decipher type, used only in type position by the bundled code.
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
// Encrypted-database only; fails loudly.
//
export function generateKeyPairSync(): never {
    notImplemented("cryptoGenerateKeyPairSync");
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

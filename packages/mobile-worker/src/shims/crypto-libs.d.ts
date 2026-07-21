//
// Ambient type declarations for the pure-JS crypto libraries the mobile crypto shim uses for the
// bulk symmetric work (AES-256-CBC), HMAC-SHA256 (SigV4) and random bytes. These are the browserify
// implementations (the same lineage as `create-hash`/`hash.js` already used by the shim); they ship
// no TypeScript types, so the minimal surface the shim calls is declared here.
//

//
// `browserify-aes`: a pure-JS AES implementation exposing Node's createCipheriv/createDecipheriv.
//
declare module "browserify-aes" {
    import { Buffer } from "buffer";

    //
    // A streaming cipher: chained update() producing ciphertext blocks and final() flushing padding.
    //
    export interface ICipheriv {
        // Encrypts the next chunk, returning the produced ciphertext bytes.
        update(data: Buffer | Uint8Array): Buffer;

        // Finalises the cipher, returning the last padded block.
        final(): Buffer;
    }

    //
    // A streaming decipher: chained update() producing plaintext blocks and final() removing padding.
    //
    export interface IDecipheriv {
        // Decrypts the next chunk, returning the produced plaintext bytes.
        update(data: Buffer | Uint8Array): Buffer;

        // Finalises the decipher, returning the last unpadded block.
        final(): Buffer;
    }

    // Creates a symmetric cipher (e.g. "aes-256-cbc") for the given key and IV.
    export function createCipheriv(algorithm: string, key: Buffer | Uint8Array, iv: Buffer | Uint8Array): ICipheriv;

    // Creates a symmetric decipher (e.g. "aes-256-cbc") for the given key and IV.
    export function createDecipheriv(algorithm: string, key: Buffer | Uint8Array, iv: Buffer | Uint8Array): IDecipheriv;
}

//
// `create-hmac`: a pure-JS HMAC exposing Node's createHmac. Used for SigV4 (HMAC-SHA256).
//
declare module "create-hmac" {
    import { Buffer } from "buffer";

    //
    // An HMAC accumulator: chained update() then a single digest().
    //
    interface IHmac {
        // Feeds data into the HMAC.
        update(data: Buffer | Uint8Array | string): IHmac;

        // Finalises the HMAC, returning a Buffer (or a hex/base64 string when an encoding is given).
        digest(): Buffer;
        digest(encoding: string): string;
    }

    // Creates an HMAC for the given algorithm (e.g. "sha256") and key.
    function createHmac(algorithm: string, key: Buffer | Uint8Array | string): IHmac;
    namespace createHmac {
        // Re-exported so callers can type an HMAC value without ReturnType.
        export type Hmac = IHmac;
    }
    export = createHmac;
}

//
// `randombytes`: a pure-JS CSPRNG (Node crypto.randomBytes off-device, crypto.getRandomValues in the
// engine). Used for the AES key/IV during encryption.
//
declare module "randombytes" {
    import { Buffer } from "buffer";

    // Returns `size` cryptographically-random bytes.
    function randomBytes(size: number): Buffer;
    export = randomBytes;
}

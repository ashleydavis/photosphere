import { createCipheriv, createDecipheriv, KeyObject, privateDecrypt, publicEncrypt, randomBytes } from "node:crypto";
import {
    ENCRYPTION_TAG,
    ENCRYPTION_FORMAT_VERSION,
    ENCRYPTION_TYPE,
    LEGACY_HEADER_LENGTH,
    NEW_FORMAT_HEADER_LENGTH,
    PUBLIC_KEY_HASH_LENGTH,
    SUPPORTED_TYPES,
    SUPPORTED_VERSIONS,
    WRAPPED_KEY_LENGTH,
} from "./encryption-constants";
import { log } from "utils";
import { hashPublicKey } from "./key-utils";
import type { IPrivateKeyMap } from "./encryption-types";

//
// Encrypts a buffer using a public key. Always writes the new format (tag, version, type, keyHash + payload).
//
export function encryptBuffer(publicKey: KeyObject, data: Buffer): Buffer {
    const key = randomBytes(32);
    const iv = randomBytes(16);
    const cipher = createCipheriv("aes-256-cbc", key, iv);
    const encrypted = Buffer.concat([cipher.update(data), cipher.final()]);
    const encryptedKey = publicEncrypt(publicKey, key);
    requireWrappableKey(encryptedKey.length);
    const payload = Buffer.concat([encryptedKey, iv, encrypted]);

    const version = ENCRYPTION_FORMAT_VERSION;
    const encType = ENCRYPTION_TYPE;
    const keyHash = hashPublicKey(publicKey);

    const header = Buffer.allocUnsafe(NEW_FORMAT_HEADER_LENGTH);
    Buffer.from(ENCRYPTION_TAG, "ascii").copy(header, 0);
    header.writeUInt32LE(version, 4);
    header.write(encType.padEnd(4).slice(0, 4), 8, "ascii");
    keyHash.copy(header, 12);

    return Buffer.concat([header, payload]);
}

const TAG_BYTES = Buffer.from(ENCRYPTION_TAG, "ascii");

//
// Refuses a wrapped key that the readers could not slice back out of the file.
//
// Checked at the write, where the wrapped key has just been produced and its length is free to read,
// rather than where a key is loaded: this is the one check that works everywhere, because the mobile
// crypto shim's KeyObject carries no key details to inspect and only the wrapped length says what
// size the key really was.
//
// What it prevents is losing the plaintext. Encrypting with a smaller key succeeded and wrote a file
// that no reader here can decrypt, and said nothing at the time; making the read loud does not help,
// because by then the only copy of the data is the unreadable file.
//
export function requireWrappableKey(wrappedKeyLength: number): void {
    if (wrappedKeyLength !== WRAPPED_KEY_LENGTH) {
        throw new Error(`This encryption key wraps into ${wrappedKeyLength} bytes and the file format requires ${WRAPPED_KEY_LENGTH}, which is 4096-bit RSA. Encrypting with it would write files that cannot be decrypted again.`);
    }
}

//
// Decrypts a buffer using a key map. Tries in order: new format, legacy format, then returns data
// unchanged, which is how a file that was never encrypted reads back through an encrypted storage.
//
// A file carrying the encryption tag is the exception: it says outright that it is encrypted, so a
// failure to decrypt it is a failure, not evidence that it was plaintext all along. Handing the
// ciphertext back for one of those produces a wrong answer a long way from its cause: the caller
// deserializes the encrypted bytes and reports whatever that happens to look like, which for a
// database file is "Checksum mismatch: expected <the file's last 32 bytes>". That message names
// serialization while the fault is the key, so it sends a reader to the wrong place entirely.
//
export function decryptBuffer(data: Buffer, privateKeyMap: IPrivateKeyMap): Buffer {
    if (data.length < 4) {
        return data;
    }

    const carriesEncryptionTag = data.subarray(0, 4).equals(TAG_BYTES);

    //
    // Try to decrypt as new format.
    //
    try {
        return decryptNewFormat(data, privateKeyMap);
    }
    catch (err: any) {
        if (carriesEncryptionTag) {
            throw new Error(`Could not decrypt data that says it is encrypted: ${err.message}`, { cause: err });
        }
        log.verbose(`decryptBuffer: new format decryption failed, trying legacy`);
    }

    //
    // Try to decrypt as legacy format.
    //
    const defaultKey = privateKeyMap["default"];
    if (defaultKey) {
        try {
            return decryptLegacy(data, defaultKey);
        }
        catch (err: any) {
            log.verbose(`decryptBuffer: legacy decryption failed, returning data unchanged`);
        }
    }

    //
    // Assume data is not encrypted.
    //
    return data;
}

//
// Decrypts a buffer in new format (PSEN header + version, type, keyHash + payload).
//
export function decryptNewFormat(data: Buffer, privateKeyMap: IPrivateKeyMap): Buffer {
    if (data.length < NEW_FORMAT_HEADER_LENGTH) {
        throw new Error("New-format data too short for header");
    }
    if (!data.slice(0, 4).equals(TAG_BYTES)) {
        throw new Error("New-format data does not start with encryption tag");
    }

    const version = data.readUInt32LE(4);
    const encType = data.slice(8, 12).toString("ascii").replace(/\0/g, "").trim();
    const keyHashBuffer = data.slice(12, 12 + PUBLIC_KEY_HASH_LENGTH);
    const keyHashHex = keyHashBuffer.toString("hex");
    if (!SUPPORTED_VERSIONS.includes(version) || !SUPPORTED_TYPES.includes(encType)) {
        throw new Error(`Unsupported encryption format version=${version} type=${encType}`);
    }

    const privateKey = privateKeyMap[keyHashHex];
    if (!privateKey) {
        throw new Error(`No private key in map for key hash ${keyHashHex}`);
    }

    const payload = data.slice(NEW_FORMAT_HEADER_LENGTH);
    const encryptedKey = payload.slice(0, 512);
    const iv = payload.slice(512, 512 + 16);
    const encrypted = payload.slice(512 + 16);
    const key = privateDecrypt(privateKey, encryptedKey);
    const decipher = createDecipheriv("aes-256-cbc", key, iv);
    return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

//
// Decrypts a buffer in legacy format (no header: encryptedKey + iv + ciphertext) using the default key.
//
export function decryptLegacy(data: Buffer, privateKey: KeyObject): Buffer {
    if (data.length < LEGACY_HEADER_LENGTH) {
        throw new Error("Legacy encrypted data too short");
    }
    const encryptedKey = data.slice(0, 512);
    const iv = data.slice(512, 512 + 16);
    const encrypted = data.slice(512 + 16);
    const key = privateDecrypt(privateKey, encryptedKey);
    const decipher = createDecipheriv("aes-256-cbc", key, iv);
    return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

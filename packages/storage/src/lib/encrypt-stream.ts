import { createCipheriv, createDecipheriv, Decipher, KeyObject, privateDecrypt, publicEncrypt, randomBytes } from "node:crypto";
import { Duplex, Transform } from "node:stream";
import {
    ENCRYPTION_TAG,
    ENCRYPTION_FORMAT_VERSION,
    ENCRYPTION_TYPE,
    LEGACY_HEADER_LENGTH,
    NEW_FORMAT_HEADER_LENGTH,
    NEW_FORMAT_PAYLOAD_OFFSET,
    PUBLIC_KEY_HASH_LENGTH,
    SUPPORTED_TYPES,
    SUPPORTED_VERSIONS,
} from "./encryption-constants";
import { hashPublicKey } from "./key-utils";
import type { IPrivateKeyMap } from "./encryption-types";

//
// Creates a stream that encrypts data with a public key and writes the new format header
// (tag, version, type, keyHash) then the legacy payload (encryptedKey + iv + ciphertext).
//
export function createEncryptionStream(publicKey: KeyObject): Duplex {
    const key = randomBytes(32);
    const iv = randomBytes(16);
    const cipher = createCipheriv('aes-256-cbc', key, iv);
    const keyHash = hashPublicKey(publicKey);

    const header = Buffer.allocUnsafe(NEW_FORMAT_HEADER_LENGTH);
    Buffer.from(ENCRYPTION_TAG, "ascii").copy(header, 0);
    header.writeUInt32LE(ENCRYPTION_FORMAT_VERSION, 4);
    header.write(ENCRYPTION_TYPE.padEnd(4).slice(0, 4), 8, "ascii");
    keyHash.copy(header, 12);

    let headerSent = false;

    return new Transform({
        transform(chunk, encoding, callback) {
            if (!headerSent) {
                const encryptedKey = publicEncrypt(publicKey, key);
                this.push(header);
                this.push(encryptedKey);
                this.push(iv);
                headerSent = true;
            }
            this.push(cipher.update(chunk));
            callback();
        },

        flush(callback) {
            this.push(cipher.final());
            callback();
        },
    });
}

//
// Creates a stream that decrypts data using a key map. Supports legacy (no header, "default" key)
// and new-format (44-byte header then payload; key looked up by hash from header).
//
export function createDecryptionStream(privateKeyMap: IPrivateKeyMap): Duplex {
    let decipher: Decipher | undefined;
    let buffer = Buffer.alloc(0);
    const tagBytes = Buffer.from(ENCRYPTION_TAG, "ascii");

    return new Transform({
        transform(chunk, encoding, callback) {
            buffer = Buffer.concat([buffer, chunk]);

            if (decipher) {
                this.push(decipher.update(buffer));
                buffer = Buffer.alloc(0);
                callback();
                return;
            }

            if (buffer.length < 4) {
                callback();
                return;
            }
            
            const isLegacy = !buffer.slice(0, 4).equals(tagBytes);
            if (isLegacy) {
                const defaultKey = privateKeyMap["default"];
                if (!defaultKey) {
                    callback(new Error('Old-format stream requires privateKeyMap["default"]'));
                    return;
                }
                if (buffer.length < LEGACY_HEADER_LENGTH) {
                    callback();
                    return;
                }
                const encryptedKey = buffer.slice(0, 512);
                const iv = buffer.slice(512, 512 + 16);
                const key = privateDecrypt(defaultKey, encryptedKey);
                decipher = createDecipheriv('aes-256-cbc', key, iv);
                buffer = buffer.slice(LEGACY_HEADER_LENGTH);
                if (buffer.length > 0) {
                    this.push(decipher.update(buffer));
                    buffer = Buffer.alloc(0);
                }
                callback();
                return;
            }

            if (buffer.length < NEW_FORMAT_PAYLOAD_OFFSET) {
                callback();
                return;
            }

            const version = buffer.readUInt32LE(4);
            const encType = buffer.slice(8, 12).toString("ascii").replace(/\0/g, "").trim();
            const keyHashHex = buffer.slice(12, 12 + PUBLIC_KEY_HASH_LENGTH).toString("hex");
            let key = privateKeyMap[keyHashHex];
            if (!key && (!SUPPORTED_VERSIONS.includes(version) || !SUPPORTED_TYPES.includes(encType))) {
                key = privateKeyMap["default"];
            }

            if (!key) {
                if (SUPPORTED_VERSIONS.includes(version) && SUPPORTED_TYPES.includes(encType)) {
                    callback(new Error(`No private key in map for key hash ${keyHashHex}`));
                    return;
                }
                callback(new Error(`Unsupported encryption format version=${version} type=${encType}`));
                return;
            }
            
            const encryptedKey = buffer.slice(NEW_FORMAT_HEADER_LENGTH, NEW_FORMAT_HEADER_LENGTH + 512);
            const iv = buffer.slice(NEW_FORMAT_HEADER_LENGTH + 512, NEW_FORMAT_HEADER_LENGTH + 512 + 16);
            const symKey = privateDecrypt(key, encryptedKey);
            decipher = createDecipheriv('aes-256-cbc', symKey, iv);
            buffer = buffer.slice(NEW_FORMAT_PAYLOAD_OFFSET);
            if (buffer.length > 0) {
                this.push(decipher.update(buffer));
                buffer = Buffer.alloc(0);
            }
            callback();
        },

        flush(callback) {
            if (decipher && buffer.length > 0) {
                this.push(decipher.update(buffer));
            }
            if (decipher) {
                this.push(decipher.final());
            }
            callback();
        },
    });
}


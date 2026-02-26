import { createCipheriv, createDecipheriv, KeyObject, privateDecrypt, publicEncrypt, randomBytes } from "node:crypto";
import {
    ENCRYPTION_TAG,
    ENCRYPTION_FORMAT_VERSION,
    ENCRYPTION_TYPE,
    PUBLIC_KEY_HASH_LENGTH,
} from "./encryption-constants";
import { hashPublicKey } from "./key-utils";
import type { IPrivateKeyMap } from "./encryption-types";

const LEGACY_HEADER_LENGTH = 512 + 16; // encryptedKey + iv
const NEW_FORMAT_HEADER_LENGTH = 4 + 4 + 4 + PUBLIC_KEY_HASH_LENGTH; // tag + version + type + keyHash
const SUPPORTED_VERSIONS = [1];
const SUPPORTED_TYPES = ["A2CB"];

//
// Encrypts a buffer using a public key. Always writes the new format (tag, version, type, keyHash + payload).
//
export async function encryptBuffer(publicKey: KeyObject, data: Buffer): Promise<Buffer> {
    const key = randomBytes(32);
    const iv = randomBytes(16);
    const cipher = createCipheriv("aes-256-cbc", key, iv);
    const encrypted = Buffer.concat([cipher.update(data), cipher.final()]);
    const encryptedKey = publicEncrypt(publicKey, key);
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

//
// Decrypts a buffer using a key map. Supports old format (no header, use "default" key) and new format (header + key lookup by hash).
//
export async function decryptBuffer(data: Buffer, privateKeyMap: IPrivateKeyMap): Promise<Buffer> {
    if (data.length < 4) {
        throw new Error("Encrypted data too short to read format tag");
    }

    const hasNewFormatTag = data.slice(0, 4).equals(Buffer.from(ENCRYPTION_TAG, "ascii"));
    if (!hasNewFormatTag) {
        const defaultKey = privateKeyMap["default"];
        if (!defaultKey) {
            throw new Error('Old-format encrypted data requires privateKeyMap["default"]');
        }
        return decryptLegacy(data, defaultKey);
    }

    if (data.length < NEW_FORMAT_HEADER_LENGTH) {
        throw new Error("New-format encrypted data too short to read header");
    }

    const version = data.readUInt32LE(4);
    const encType = data.slice(8, 12).toString("ascii").replace(/\0/g, "").trim();
    const keyHashBuffer = data.slice(12, 12 + PUBLIC_KEY_HASH_LENGTH);
    const keyHashHex = keyHashBuffer.toString("hex");
    if (!SUPPORTED_VERSIONS.includes(version) || !SUPPORTED_TYPES.includes(encType)) {
        const defaultKey = privateKeyMap["default"];
        if (defaultKey) {
            return decryptLegacy(data, defaultKey);
        }
        throw new Error(`Unsupported encryption format version=${version} type=${encType}`);
    }

    const privateKey = privateKeyMap[keyHashHex];
    if (!privateKey) {
        throw new Error(`No private key in map for key hash ${keyHashHex}`);
    }

    const payload = data.slice(NEW_FORMAT_HEADER_LENGTH);
    return decryptLegacy(payload, privateKey);
}

//
// Decrypts a legacy-format payload (encryptedKey + iv + ciphertext) using the given private key.
// Used for both old-format files (no header) and the payload section of new-format files.
//
function decryptLegacy(data: Buffer, privateKey: KeyObject): Promise<Buffer> {
    if (data.length < LEGACY_HEADER_LENGTH) {
        throw new Error("Legacy encrypted data too short");
    }
    const encryptedKey = data.slice(0, 512);
    const iv = data.slice(512, 512 + 16);
    const encrypted = data.slice(512 + 16);
    const key = privateDecrypt(privateKey, encryptedKey);
    const decipher = createDecipheriv("aes-256-cbc", key, iv);
    const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    return Promise.resolve(decrypted);
}

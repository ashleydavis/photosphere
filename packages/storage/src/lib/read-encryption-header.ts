//
// Peeks at the encryption header of a stored file (raw bytes) to detect format and key.
// Call with the underlying (unencrypted) storage so read() returns raw bytes.
//

import type { IStorage } from "./storage";
import { ENCRYPTION_TAG, NEW_FORMAT_HEADER_LENGTH, PUBLIC_KEY_HASH_LENGTH } from "./encryption-constants";

//
// Reads the first bytes of a file and returns the public key hash from the encryption header if present.
// Pass the raw storage (no decryption layer) so read() returns bytes as stored on disk.
// Returns the 32-byte SHA-256 hash of the public key that encrypted the file, or undefined if
// the file does not exist, is too short, or is not new-format encrypted.
//
export async function readEncryptionHeader(
    rawStorage: IStorage,
    filePath: string
): Promise<Buffer | undefined> {
    const buf = await rawStorage.read(filePath);
    const raw = buf?.slice(0, NEW_FORMAT_HEADER_LENGTH);
    if (!raw || raw.length < 4) {
        return undefined;
    }
    const tag = raw.slice(0, 4).toString("ascii");
    if (tag !== ENCRYPTION_TAG) {
        return undefined;
    }
    if (raw.length < NEW_FORMAT_HEADER_LENGTH) {
        return undefined;
    }
    return raw.slice(12, 12 + PUBLIC_KEY_HASH_LENGTH);
}

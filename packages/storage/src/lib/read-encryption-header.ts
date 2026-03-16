//
// Peeks at the encryption header of a stored file (raw bytes) to detect format and key.
// Call with the underlying (unencrypted) storage so read() returns raw bytes.
//

import type { IStorage } from "./storage";
import { ENCRYPTION_TAG, NEW_FORMAT_HEADER_LENGTH, PUBLIC_KEY_HASH_LENGTH } from "./encryption-constants";
import { retry } from "utils";

//
// Reads exactly `length` bytes from the start of a storage file using its read stream.
// Returns undefined if the file does not exist or produces no data.
//
export async function readFirstBytes(storage: IStorage, filePath: string, length: number): Promise<Buffer | undefined> {
    if (!await storage.fileExists(filePath)) {
        return undefined;
    }

    const stream = storage.readStream(filePath);
    return new Promise<Buffer | undefined>((resolve, reject) => {
        const chunks: Buffer[] = [];
        let collected = 0;

        stream.on("data", (chunk: Buffer) => {
            chunks.push(chunk);
            collected += chunk.length;
            if (collected >= length) {
                stream.destroy();
            }
        });

        stream.on("end", () => {
            if (chunks.length === 0) {
                resolve(undefined);
            }
            else {
                resolve(Buffer.concat(chunks).subarray(0, length));
            }
        });

        stream.on("close", () => {
            if (chunks.length === 0) {
                resolve(undefined);
            }
            else {
                resolve(Buffer.concat(chunks).subarray(0, length));
            }
        });

        stream.on("error", reject);
    });
}

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
    const raw = await retry(() => readFirstBytes(rawStorage, filePath, NEW_FORMAT_HEADER_LENGTH));
    if (!raw || raw.length < 4) {
        return undefined;
    }
    const tag = raw.subarray(0, 4).toString("ascii");
    if (tag !== ENCRYPTION_TAG) {
        return undefined;
    }
    if (raw.length < NEW_FORMAT_HEADER_LENGTH) {
        return undefined;
    }
    return raw.subarray(12, 12 + PUBLIC_KEY_HASH_LENGTH);
}

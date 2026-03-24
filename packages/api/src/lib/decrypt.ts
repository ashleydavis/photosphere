//
// In-place decrypt: copy every file from read storage (encrypted) to write storage (plain),
// update the merkle tree for tree-tracked files, then save the tree.
//

import { IStorage, readEncryptionHeader, walkDirectory } from "storage";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { getItemInfo, IMerkleTree, updateItem } from "merkle-tree";
import { batchGenerator, log, retry } from "utils";
import { LARGE_FILE_TIMEOUT } from "./constants";
import { IDatabaseMetadata } from "./media-file-database";

//
// Callback invoked periodically during decrypt to report progress.
//
export type IDecryptProgress = (message: string) => void;

//
// Result returned by decrypt with counts of files processed.
//
export interface IDecryptResult {
    decrypted: number;
    skipped: number;
}

//
// Decrypts a single file from readStorage and writes it plain to writeStorage.
// Skips files that are not encrypted. Updates the merkle tree entry for non-.db/ files.
// Returns true if the file was decrypted, false if it was skipped (already plain).
//
async function decryptFile(
    fileName: string,
    readStorage: IStorage,
    writeStorage: IStorage,
    rawReadStorage: IStorage,
    merkleTree: IMerkleTree<IDatabaseMetadata>
): Promise<boolean> {
    const srcFileInfo = await retry(() => readStorage.info(fileName));
    if (!srcFileInfo) {
        throw new Error(`Source file "${fileName}" does not exist.`);
    }

    const header = await readEncryptionHeader(rawReadStorage, fileName);
    const shouldDecrypt = header !== undefined || readStorage !== writeStorage;
    if (shouldDecrypt) {
        log.verbose(`Decrypting ${fileName}`);

        await retry(async () => {
            const stream = await readStorage.readStream(fileName);
            await writeStorage.writeStream(
                fileName,
                srcFileInfo.contentType,
                stream,
                srcFileInfo.length
            );
        }, 3, 1_000, 2, LARGE_FILE_TIMEOUT);

        if (!fileName.startsWith(".db/")) {
            const existing = getItemInfo(merkleTree, fileName);
            if (existing) {
                const updatedInfo = await retry(() => writeStorage.info(fileName));
                if (!updatedInfo) {
                    throw new Error(`Written file "${fileName}" has no info.`);
                }
                updateItem(merkleTree, {
                    name: fileName,
                    hash: existing.hash,
                    length: updatedInfo.length,
                    lastModified: updatedInfo.lastModified,
                });
            }
        }

        return true;
    }
    else {
        log.info(`Already decrypted ${fileName}`);
        return false;
    }
}

//
// Yields file names from readStorage that should be decrypted, skipping metadata and config files
// that are either handled separately or not decrypted at all.
//
export async function* decryptableFiles(readStorage: IStorage): AsyncGenerator<string> {
    for await (const { fileName } of walkDirectory(readStorage, "", [])) {
        if (fileName !== ".db/files.dat" && fileName !== ".db/encryption.pub" && fileName !== ".db/config.json" && fileName !== "README.md") {
            yield fileName;
        }
    }
}

//
// Decrypts the database in place: reads each file from readStorage (encrypted),
// writes it plain to writeStorage (same path).
// rawReadStorage is the raw storage (no decryption layer) used to peek encryption headers.
//
export async function decrypt(
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback: IDecryptProgress,
    rawReadStorage: IStorage
): Promise<IDecryptResult> {

    const merkleTree = await retry(() => loadMerkleTree(readStorage));
    if (!merkleTree) {
        throw new Error("Failed to load merkle tree.");
    }

    let decrypted = 0;
    let skipped = 0;
    const BATCH_SIZE = 10;

    for await (const batch of batchGenerator(decryptableFiles(readStorage), BATCH_SIZE)) {
        await Promise.all(batch.map(async fileName => {
            if (await decryptFile(fileName, readStorage, writeStorage, rawReadStorage, merkleTree)) {
                ++decrypted;
            }
            else {
                ++skipped;
            }
        }));
        if (progressCallback) {
            progressCallback(`Decrypted ${decrypted} files, skipped ${skipped} already plain`);
        }
    }

    await retry(() => saveMerkleTree(merkleTree, writeStorage));

    if (progressCallback) {
        progressCallback(`Decrypted ${decrypted} files, skipped ${skipped} already plain, saved merkle tree`);
    }
    return { decrypted, skipped };
}

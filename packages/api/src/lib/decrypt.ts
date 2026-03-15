//
// In-place decrypt: copy every file from read storage (encrypted) to write storage (plain),
// update the merkle tree for tree-tracked files, then save the tree.
//

import { IStorage, readEncryptionHeader, walkDirectory } from "storage";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { getItemInfo, IMerkleTree, updateItem } from "merkle-tree";
import { log, retry } from "utils";
import { IDatabaseMetadata } from "./media-file-database";

//
// Callback invoked periodically during decrypt to report progress.
//
export type IDecryptProgress = (message: string) => void;

//
// Decrypts a single file from readStorage and writes it plain to writeStorage.
// Skips files that are not encrypted. Updates the merkle tree entry for non-.db/ files.
//
async function decryptFile(
    fileName: string,
    readStorage: IStorage,
    writeStorage: IStorage,
    rawReadStorage: IStorage,
    merkleTree: IMerkleTree<IDatabaseMetadata>
): Promise<void> {
    const srcFileInfo = await retry(() => readStorage.info(fileName));
    if (!srcFileInfo) {
        throw new Error(`Source file "${fileName}" does not exist.`);
    }

    const header = await readEncryptionHeader(rawReadStorage, fileName);
    const shouldDecrypt = header !== undefined || readStorage !== writeStorage;
    if (shouldDecrypt) {
        log.verbose(`Decrypting ${fileName}`);

        await retry(async () => {
            const stream = readStorage.readStream(fileName);
            await writeStorage.writeStream(
                fileName,
                srcFileInfo.contentType,
                stream,
                srcFileInfo.length
            );
        });

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
    }
    else {
        log.info(`Already decrypted ${fileName}`);
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
): Promise<void> {

    const merkleTree = await retry(() => loadMerkleTree(readStorage));
    if (!merkleTree) {
        throw new Error("Failed to load merkle tree.");
    }

    let decrypted = 0;
    const BATCH_SIZE = 10;
    let batch: string[] = [];

    for await (const { fileName } of walkDirectory(readStorage, "", [])) {

        if (fileName === ".db/files.dat" || fileName === ".db/encryption.pub" || fileName === "README.md") {
            // .db/file.dat will be written decrypted after this loop.
            // The other files are not decrypted.
            continue;
        }

        batch.push(fileName);

        if (batch.length >= BATCH_SIZE) {
            await Promise.all(batch.map(fileName => decryptFile(fileName, readStorage, writeStorage, rawReadStorage, merkleTree)));
            decrypted += batch.length;
            batch = [];
            if (progressCallback) {
                progressCallback(`Decrypted ${decrypted} files`);
            }
        }
    }

    if (batch.length > 0) {
        await Promise.all(batch.map(fileName => decryptFile(fileName, readStorage, writeStorage, rawReadStorage, merkleTree)));
        decrypted += batch.length;
    }

    await retry(() => saveMerkleTree(merkleTree, writeStorage));

    if (progressCallback) {
        progressCallback(`Decrypted ${decrypted} files, saved merkle tree`);
    }
}

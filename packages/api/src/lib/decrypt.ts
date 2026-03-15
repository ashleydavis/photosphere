//
// In-place decrypt: copy every file from read storage (encrypted) to write storage (plain),
// update the merkle tree for tree-tracked files, then save the tree.
//

import { IStorage, readEncryptionHeader, walkDirectory } from "storage";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { getItemInfo, updateItem } from "merkle-tree";
import { log, retry } from "utils";
import type { IEncryptDecryptProgress } from "./encrypt";

//
// Decrypts the database in place: reads each file from readStorage (encrypted),
// writes it plain to writeStorage (same path).
// rawReadStorage is the raw storage (no decryption layer) used to peek encryption headers.
//
export async function decrypt(
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback: IEncryptDecryptProgress | undefined,
    rawReadStorage: IStorage
): Promise<void> {
    
    const merkleTree = await retry(() => loadMerkleTree(readStorage));    
    if (!merkleTree) {
        throw new Error("Failed to load merkle tree.");
    }
    
    let decrypted = 0;

    for await (const { fileName } of walkDirectory(readStorage, "", [])) {

        if (fileName === ".db/files.dat" || fileName === ".db/encryption.pub" || fileName === "README.md") {
            // .db/file.dat will be written decrypted after this loop.
            // The other files are not decrypted.
            continue;
        }

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

        decrypted++;

        if (progressCallback && decrypted % 10 === 0) {
            progressCallback(`Decrypted ${decrypted} files`);
        }
    }

    await retry(() => saveMerkleTree(merkleTree, writeStorage));

    if (progressCallback) {
        progressCallback(`Decrypted ${decrypted} files, saved merkle tree`);
    }
}


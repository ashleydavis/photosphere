//
// In-place encrypt and decrypt: copy every file from read storage to write storage
// (same logical path), update the merkle tree for tree-tracked files, then save the tree.
// Uses walkDirectory so that all files (including .db/bson/*) are transformed.
//

import { IStorage, walkDirectory } from "storage";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { computeHash } from "./hash";
import { iterateLeaves } from "./replicate";
import { upsertItem } from "merkle-tree";
import { retry } from "utils";

const FILES_TREE_PATH = ".db/files.dat";
const ENCRYPTION_PUB_PATH = ".db/encryption.pub";

export type IEncryptDecryptProgress = (message: string) => void;

async function runInPlaceTransform(
    readStorage: IStorage,
    writeStorage: IStorage,
    progressVerb: "Encrypted" | "Decrypted",
    progressCallback?: IEncryptDecryptProgress
): Promise<void> {
    const merkleTree = await retry(() => loadMerkleTree(readStorage));
    if (!merkleTree?.merkle) {
        throw new Error("Failed to load merkle tree from database.");
    }

    const treeFileNames = new Set([...iterateLeaves([merkleTree.merkle])]);
    const allPaths: string[] = [];
    for await (const { fileName } of walkDirectory(readStorage, "", [])) {
        allPaths.push(fileName);
    }
    allPaths.sort((a, b) => (a === FILES_TREE_PATH ? 1 : b === FILES_TREE_PATH ? -1 : a.localeCompare(b)));
    const filePaths = allPaths.filter(
        path => path !== FILES_TREE_PATH && path !== ENCRYPTION_PUB_PATH
    );

    let copied = 0;
    for (const filePath of filePaths) {
        const srcFileInfo = await retry(() => readStorage.info(filePath));
        if (!srcFileInfo) {
            throw new Error(`Source file "${filePath}" does not exist.`);
        }

        // Read fully then write to avoid reading a file while overwriting it in place
        const data = await retry(() => readStorage.read(filePath));
        if (!data) {
            throw new Error(`Source file "${filePath}" read returned no data.`);
        }
        await retry(() =>
            writeStorage.write(filePath, srcFileInfo.contentType ?? "application/octet-stream", data)
        );

        const copiedHash = await retry(() => computeHash(writeStorage.readStream(filePath)));
        const copiedFileInfo = await retry(() => writeStorage.info(filePath));
        if (!copiedFileInfo) {
            throw new Error(`Failed to read info for written file: ${filePath}`);
        }

        if (treeFileNames.has(filePath)) {
            upsertItem(merkleTree, {
                name: filePath,
                hash: copiedHash,
                length: copiedFileInfo.length,
                lastModified: copiedFileInfo.lastModified,
            });
        }
        copied++;
        if (progressCallback && copied % 10 === 0) {
            progressCallback(`${progressVerb} ${copied} files`);
        }
    }

    await retry(() => saveMerkleTree(merkleTree, writeStorage));

    const treeFileInfo = await retry(() => writeStorage.info(FILES_TREE_PATH));
    if (treeFileInfo) {
        const treeFileHash = await retry(() => computeHash(writeStorage.readStream(FILES_TREE_PATH)));
        upsertItem(merkleTree, {
            name: FILES_TREE_PATH,
            hash: treeFileHash,
            length: treeFileInfo.length,
            lastModified: treeFileInfo.lastModified,
        });
        await retry(() => saveMerkleTree(merkleTree, writeStorage));
    }

    if (progressCallback) {
        progressCallback(`${progressVerb} ${copied} files, saved merkle tree`);
    }
}

//
// Encrypts the database in place: reads each file from readStorage, writes it encrypted
// to writeStorage (same path). Can be run on an already encrypted database to re-encrypt
// with a new key. Use readStorage = plain, writeStorage = encrypted for plain→encrypted;
// or both encrypted for re-encrypt with a new key. The caller must only store the new
// public key in .db/encryption.pub after the entire database has been re-encrypted.
//
export async function encrypt(
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback?: IEncryptDecryptProgress
): Promise<void> {
    await runInPlaceTransform(readStorage, writeStorage, "Encrypted", progressCallback);
}

//
// Decrypts the database in place: reads each file from readStorage (encrypted),
// writes it plain to writeStorage (same path).
//
export async function decrypt(
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback?: IEncryptDecryptProgress
): Promise<void> {
    await runInPlaceTransform(readStorage, writeStorage, "Decrypted", progressCallback);
}

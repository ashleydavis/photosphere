//
// In-place encrypt: copy every file from read storage to write storage (same logical path),
// then save the merkle tree.
// Uses walkDirectory so that all files (including .db/bson/*) are transformed.
//

import type { KeyObject } from "node:crypto";
import { hashPublicKey, IStorage, readEncryptionHeader, walkDirectory } from "storage";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { getItemInfo, IMerkleTree, updateItem } from "merkle-tree";
import { log, retry } from "utils";
import { IDatabaseMetadata } from "./media-file-database";

//
// Callback invoked periodically during encrypt to report progress.
//
export type IEncryptProgress = (message: string) => void;

//
// Encrypts a single file from readStorage and writes it to writeStorage.
// Skips files already encrypted with the given publicKeyHash.
// Updates the merkle tree entry for non-.db/ files with the new storage metadata.
//
//
// Returns true if the file was encrypted, false if it was skipped (already encrypted with the given key).
//
export async function encryptFile(
    fileName: string,
    readStorage: IStorage,
    writeStorage: IStorage,
    rawReadStorage: IStorage,
    publicKeyHash: Buffer,
    merkleTree: IMerkleTree<IDatabaseMetadata>
): Promise<boolean> {
    const srcFileInfo = await retry(() => readStorage.info(fileName));
    if (!srcFileInfo) {
        throw new Error(`Source file "${fileName}" does not exist.`);
    }

    const header = await readEncryptionHeader(rawReadStorage, fileName);
    const shouldEncrypt = header === undefined || !header.equals(publicKeyHash);
    if (shouldEncrypt) {
        log.verbose(`Encrypting ${fileName}`);

        await retry(async () => {
            await writeStorage.writeStream(
                fileName,
                srcFileInfo.contentType,
                readStorage.readStream(fileName),
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

        return true;
    }
    else {
        // log.verbose(`Already encrypted ${fileName}`);
        return false;
    }
}

//
// Encrypts the database in place: reads each file from readStorage, writes it encrypted
// to writeStorage (same path). Can be run on an already encrypted database to re-encrypt
// with a new key. Use readStorage = plain, writeStorage = encrypted for plain→encrypted;
// or both encrypted for re-encrypt with a new key. The caller must only store the new
// public key in .db/encryption.pub after the entire database has been re-encrypted.
// Files already encrypted with this key are skipped.
// rawReadStorage is the raw storage (no decryption layer) used to peek encryption headers; pass the same path as readStorage.
//
export async function encrypt(
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback: IEncryptProgress,
    encryptionPublicKey: KeyObject,
    rawReadStorage: IStorage
): Promise<void> {
    const merkleTree = await retry(() => loadMerkleTree(readStorage));
    if (!merkleTree) {
        throw new Error("Failed to load merkle tree from database.");
    }

    const publicKeyHash = hashPublicKey(encryptionPublicKey);

    let encrypted = 0;
    let skipped = 0;
    const BATCH_SIZE = 10;

    let batch: string[] = [];

    for await (const { fileName } of walkDirectory(readStorage, "", [])) {

        if (fileName === ".db/files.dat" || fileName === ".db/encryption.pub" || fileName === "README.md") {
            // .db/file.dat will be written encrypted after this loop.
            // The other files are not encrypted.
            continue;
        }

        batch.push(fileName);

        console.log(`Added ${batch.length}`); //fio:

        // if (batch.length >= BATCH_SIZE) {
        //     const results = await Promise.all(batch.map(fileName => encryptFile(fileName, readStorage, writeStorage, rawReadStorage, publicKeyHash, merkleTree)));
        //     encrypted += results.filter(result => result).length;
        //     skipped += results.filter(result => !result).length;
        //     batch = [];
        //     progressCallback(`Encrypted ${encrypted} files, skipped ${skipped} already encrypted`);
        //     log.verbose(`Encrypted ${encrypted} files, skipped ${skipped} already encrypted`);
        // }
    }

    console.log(`Collected ${batch.length}`);

    let done = 0;

    if (batch.length > 0) {
        for (const fileName of batch) {
            await encryptFile(fileName, readStorage, writeStorage, rawReadStorage, publicKeyHash, merkleTree);
            ++done;
            console.log(`Processed ${done}`); //fio:
        }
        // const results = await Promise.all(batch.map(fileName => encryptFile(fileName, readStorage, writeStorage, rawReadStorage, publicKeyHash, merkleTree)));
        // encrypted += results.filter(result => result).length;
        // skipped += results.filter(result => !result).length;
    }

    await retry(() => saveMerkleTree(merkleTree, writeStorage));
    progressCallback(`Encrypted ${encrypted} files, skipped ${skipped} already encrypted, saved merkle tree`);
    log.verbose(`!!!!!!!!!!!!!!!!!!!!!!!`);
}


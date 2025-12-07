import { createHash } from "node:crypto";
import { IFileStat } from "./file-scanner";
import fs from "fs-extra";
import { IHashedData } from "merkle-tree";
import { HashCache } from "./hash-cache";
import { validateFile } from "./validation";
import { log, IUuidGenerator } from "utils";
import { extractFileFromZipRecursive } from "./zip-utils";

//
// Computes a hash from a stream.
//
export function computeHash(inputStream: NodeJS.ReadableStream): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const hash = createHash("sha256");

        inputStream.on("data", (chunk: Buffer) => {
            hash.update(chunk);
        });

        inputStream.on("end", () => {
            resolve(hash.digest());
        });

        inputStream.on("error", (error) => {
            reject(error);
        });
    });
}

//
// Computes the hash of an asset storage file (no caching since data is already in merkle tree).
//
export async function computeAssetHash(filePath: string, fileStat: IFileStat, zipFilePath: string | undefined): Promise<IHashedData> {
    //
    // Compute the hash of the file.
    //
    const stream = zipFilePath 
        ? await extractFileFromZipRecursive(zipFilePath, filePath)
        : fs.createReadStream(filePath);
    const hash = await computeHash(stream);
    return {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };
}

//
// Gets a hash from the cache if it matches the file stat.
//
export async function getHashFromCache(filePath: string, fileStat: IFileStat, hashCache: HashCache): Promise<IHashedData | undefined> {
    const cacheEntry = hashCache.getHash(filePath);
    if (cacheEntry) {
        if (cacheEntry.length === fileStat.length && cacheEntry.lastModified.getTime() === fileStat.lastModified.getTime()) {
            return {
                hash: cacheEntry.hash,
                lastModified: fileStat.lastModified,
                length: fileStat.length,
            }
        }
    }
    return undefined;
}

//
// Validates and computes the hash of a file for import.
// Returns the hashed file data on success, or undefined on failure.
//
export async function validateAndHash(
    uuidGenerator: IUuidGenerator,
    filePath: string, 
    fileStat: IFileStat, 
    contentType: string, 
    assetTempDir: string, 
    zipFilePath: string | undefined
): Promise<IHashedData | undefined> {
    try {
        if (!await validateFile(filePath, contentType, assetTempDir, uuidGenerator, zipFilePath)) {
            return undefined;
        }
    }
    catch (error: any) {
        log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);
        return undefined;
    }

    const stream = zipFilePath 
        ? await extractFileFromZipRecursive(zipFilePath, filePath)
        : fs.createReadStream(filePath);
    const hash = await computeHash(stream);
    const hashedFile: IHashedData = {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };

    return hashedFile;
}

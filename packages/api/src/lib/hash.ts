import { createHash } from "node:crypto";
import { IFileStat } from "./file-scanner";
import * as fs from "fs/promises";
import { createReadStream } from "fs";
import path from "path";
import os from "os";
import mime from "mime";
import { IHashedData } from "merkle-tree";
import { HashCache } from "./hash-cache";
import { validateFile } from "./validation";
import { log, IUuidGenerator } from "utils";
import { extractFileFromZipRecursive } from "./zip-utils";
import { writeStreamToFile } from "node-utils";

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
// Takes a stream directly to avoid reading the file back from storage.
//
export async function computeAssetHash(stream: NodeJS.ReadableStream, fileStat: IFileStat): Promise<IHashedData> {
    //
    // Compute the hash of the file.
    //
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
    filePath: string, // Actual file path (always a valid file, already extracted if from zip)
    fileStat: IFileStat, 
    contentType: string, 
    logicalPath: string // Logical path for display (always set - equals filePath for non-zip files)
): Promise<IHashedData | undefined> {
    try {
        // filePath is always a valid file (already extracted if from zip)
        // Validate the file
        if (!await validateFile(filePath, contentType, fileStat)) {
            return undefined;
        }
    }
    catch (error: any) {
        // Use logicalPath for display (always set)
        log.exception(`File "${logicalPath}" has failed its validation with error: ${error.message}`, error);
        return undefined;
    }

    // Compute hash using the file (already extracted if from zip)
    const hash = await computeHash(createReadStream(filePath));
    const hashedFile: IHashedData = {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };

    return hashedFile;
}

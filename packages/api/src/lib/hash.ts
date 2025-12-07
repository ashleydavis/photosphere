import { createHash } from "node:crypto";
import { IFileStat } from "./file-scanner";
import fs from "fs-extra";
import { IHashedData } from "merkle-tree";
import { HashCache } from "./hash-cache";
import { validateFile } from "./validation";
import { log, IUuidGenerator } from "utils";
import { FileScanner } from "./file-scanner";
import { ProgressCallback, IAddSummary } from "./media-file-database";

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
export async function computeAssetHash(filePath: string, fileStat: IFileStat, openStream: (() => NodeJS.ReadableStream) | undefined): Promise<IHashedData> {
    //
    // Compute the hash of the file.
    //
    const hash = await computeHash(openStream ? openStream() : fs.createReadStream(filePath));
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
// Computes the hash of a file for import, validating it first and caching the result in the hash cache.
//
export async function computeCachedHash(
    uuidGenerator: IUuidGenerator,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    filePath: string, 
    fileStat: IFileStat, 
    contentType: string, 
    assetTempDir: string, 
    openStream: (() => NodeJS.ReadableStream) | undefined,
    progressCallback: ProgressCallback,
    summary: IAddSummary
): Promise<{ hashedFile?: IHashedData; summary: IAddSummary }> {
    if (openStream === undefined) {
        openStream = () => fs.createReadStream(filePath);
    }
    
    try {
        if (!await validateFile(filePath, contentType, assetTempDir, uuidGenerator, openStream)) {
            summary.filesFailed++;
            if (progressCallback) {
                progressCallback(localFileScanner.getCurrentlyScanning());
            }            
            return { summary };
        }
    }
    catch (error: any) {
        log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);
        summary.filesFailed++;
        if (progressCallback) {
            progressCallback(localFileScanner.getCurrentlyScanning());
        }            
        return { summary };
    }

    const hash = await computeHash(openStream ? openStream() : fs.createReadStream(filePath));
    const hashedFile: IHashedData = {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };

    localHashCache.addHash(filePath, hashedFile);

    return { hashedFile, summary };
}

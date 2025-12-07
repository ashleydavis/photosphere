import { createHash } from "node:crypto";
import { IFileStat } from "./file-scanner";
import fs from "fs-extra";
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
    uuidGenerator: IUuidGenerator,
    filePath: string, 
    fileStat: IFileStat, 
    contentType: string, 
    assetTempDir: string, 
    zipFilePath: string | undefined
): Promise<IHashedData | undefined> {
    let actualFilePath = filePath;
    let tempFilePath: string | undefined;

    try {
        // If zipFilePath is provided, extract to a temporary file first
        if (zipFilePath) {
            const ext = mime.getExtension(contentType) || path.extname(filePath);
            tempFilePath = path.join(assetTempDir, `temp_validate_${uuidGenerator.generate()}${ext.startsWith('.') ? ext : '.' + ext}`);
            log.verbose(`Extracting file ${filePath} from zip file ${zipFilePath} to temporary file ${tempFilePath}`);
            const stream = await extractFileFromZipRecursive(zipFilePath, filePath);
            await writeStreamToFile(stream, tempFilePath);
            actualFilePath = tempFilePath;
        }

        try {
            // Validate the file (now always working with a local file)
            if (!await validateFile(actualFilePath, contentType)) {
                return undefined;
            }
        }
        catch (error: any) {
            log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);
            return undefined;
        }

        // Compute hash using the same file (already extracted if from zip)
        const hash = await computeHash(fs.createReadStream(actualFilePath));
        const hashedFile: IHashedData = {
            hash,
            lastModified: fileStat.lastModified,
            length: fileStat.length,
        };

        return hashedFile;
    }
    finally {
        // Clean up temporary file if created
        if (tempFilePath) {
            try {
                await fs.unlink(tempFilePath);
            } catch (err) {
                // Ignore cleanup errors
            }
        }
    }
}

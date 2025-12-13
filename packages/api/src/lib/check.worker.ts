//
// Check worker handler - handles file checking tasks
//

import * as fs from "fs/promises";
import { ensureDir } from "node-utils";
import os from "os";
import path from "path";
import { FileStorage, createStorage, loadEncryptionKeys, IStorageDescriptor, IS3Credentials } from "storage";
import type { IWorkerContext } from "task-queue";
import { validateAndHash, getHashFromCache } from "./hash";
import { HashCache } from "./hash-cache";
import { IFileStat } from "./file-scanner";
import { createMediaFileDatabase } from "./media-file-database";

export interface ICheckFileData {
    filePath: string; // Actual file path (always a valid file, possibly temp file from zip)
    fileStat: IFileStat;
    contentType: string;
    storageDescriptor: IStorageDescriptor;
    hashCacheDir: string;
    s3Config?: IS3Credentials;
    logicalPath: string; // Logical path for display (always set - equals filePath for non-zip files)
}

export interface ICheckFileResult {
    hashedFile?: {
        hash: string; // hex string
        lastModified: string; // ISO string
        length: number;
    };
    alreadyInDatabase: boolean;
    hashFromCache: boolean; // true if hash was loaded from cache, false if computed
}

//
// Handler for checking a single file
// Note: Hash cache is loaded read-only in workers. Saving is handled in the main thread.
//
export async function checkFileHandler(data: ICheckFileData, workingDirectory: string, context: IWorkerContext): Promise<ICheckFileResult> {
    const { filePath, fileStat, contentType, storageDescriptor, hashCacheDir, s3Config } = data;
    const { uuidGenerator, timestampProvider } = context;
    
    // Load hash cache (read-only)
    const localHashCache = new HashCache(hashCacheDir, true); // readonly = true
    await localHashCache.load();
   
    // Check cache first
    let hashedFile = await getHashFromCache(filePath, fileStat, localHashCache);
    const hashFromCache = !!hashedFile;
    
    if (!hashedFile) {
        // Not in cache - compute hash
        // filePath is always a valid file (already extracted if from zip)
        hashedFile = await validateAndHash(filePath, fileStat, contentType, data.logicalPath);
        if (!hashedFile) {
            return { hashedFile: undefined, alreadyInDatabase: false, hashFromCache: false };
        }
    }
    
    // Recreate storage and metadata collection in the worker
    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPath, false);
    const { storage: assetStorage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    const metadataCollection = database.metadataCollection;

    // Check if file is already in database
    const localHashStr = hashedFile.hash.toString("hex");
    const records = await metadataCollection.findByIndex("hash", localHashStr); //TODO: This is very slow, especially when the hash is not found.
    const alreadyInDatabase = records.length > 0;
    
    return {
        hashedFile: {
            hash: localHashStr,
            lastModified: hashedFile.lastModified.toISOString(),
            length: hashedFile.length,
        },
        alreadyInDatabase,
        hashFromCache,
    };
}


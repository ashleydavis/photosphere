import { createStorage, loadEncryptionKeysFromPem } from "storage";
import type { ITaskContext } from "task-queue";
import { createMediaFileDatabase } from "./media-file-database";
import { HashCache } from "./hash-cache";
import { getHashFromCache, validateAndHash } from "./hash";
import { IFileStat } from "./file-scanner";
import { IDatabaseDescriptor } from "./database-descriptor";
import { resolveStorageCredentials } from "./resolve-storage-credentials";

//
// Payload for the hash-file task. Contains everything needed to compute the content
// hash of a file and check whether it already exists in the database.
//
export interface IHashFileData {
    // Actual path to the file on disk.
    filePath: string;

    // File size and modification time.
    fileStat: IFileStat;

    // MIME type of the file.
    contentType: string;

    // Identifies the target database and encryption key name.
    storageDescriptor: IDatabaseDescriptor;

    // Directory for the hash cache.
    hashCacheDir: string;

    // Path used in UI (e.g. path inside a zip).
    logicalPath: string;

    // Labels to attach to the asset (e.g. folder hierarchy).
    labels: string[];

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey?: string;

    // Unique identifier for the session.
    sessionId: string;

    // When true, files are scanned and hashed but not written to the database.
    dryRun: boolean;

    // ID to use for this asset if it is imported.
    assetId: string;
}

//
// Result returned by the hash-file task.
//
export interface IHashFileResult {
    // SHA-256 hash bytes of the file content.
    hash: Uint8Array;

    // True if the hash was retrieved from the local cache (not freshly computed).
    hashFromCache: boolean;

    // True if a record with this hash already exists in the database.
    filesAlreadyAdded: boolean;
}

//
// Handler for the hash-file task. Computes or retrieves from cache the SHA-256 hash
// of a file and checks whether an asset with that hash already exists in the database.
// Does not queue any downstream tasks; the orchestrator (import-assets) handles that.
//
export async function hashFileHandler(data: IHashFileData, context: ITaskContext): Promise<IHashFileResult> {
    const { filePath, fileStat, contentType, storageDescriptor, hashCacheDir, logicalPath } = data;
    const { uuidGenerator, timestampProvider } = context;

    // Load the hash cache in read-only mode.
    const localHashCache = new HashCache(hashCacheDir, true);
    await localHashCache.load();

    // Try to retrieve the hash from the cache first.
    const cachedHash = await getHashFromCache(filePath, fileStat, localHashCache);
    let hashFromCache: boolean;
    let hashBuffer: Buffer;

    if (cachedHash) {
        hashBuffer = cachedHash.hash as Buffer;
        hashFromCache = true;
    }
    else {
        const hashedFile = await validateAndHash(filePath, fileStat, contentType, logicalPath);
        if (!hashedFile) {
            throw new Error(`Failed to validate and hash file "${logicalPath}"`);
        }
        hashBuffer = hashedFile.hash as Buffer;
        hashFromCache = false;
    }

    // Check whether this hash is already present in the database.
    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(storageDescriptor.databasePath, storageDescriptor.encryptionKey);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage } = createStorage(storageDescriptor.databasePath, s3Config, storageOptions);
    const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
    const hashHex = hashBuffer.toString("hex");
    const existingRecords = await database.metadataCollection.sortIndex("hash", "asc").findByValue(hashHex);

    return {
        hash: new Uint8Array(hashBuffer),
        hashFromCache,
        filesAlreadyAdded: existingRecords.length > 0,
    };
}

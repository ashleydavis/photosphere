import { createStorage, loadEncryptionKeysFromPem } from "storage";
import type { ITaskContext } from "task-queue";
import { createMediaFileDatabase } from "./media-file-database";
import { HashCache } from "./hash-cache";
import { getHashFromCache, validateAndHash } from "./hash";
import { IFileStat } from "./file-scanner";
import { IDatabaseDescriptor } from "api";
import { IFileCacheIdentity } from "api/src/lib/import-assets.types";
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

    // How this file is identified in the hash cache, when it is not identified by its own path.
    // Only automatic import from a device photo library supplies one. See IFileCacheIdentity.
    cacheIdentity?: IFileCacheIdentity;

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

    // The id of the record that already holds this hash, when there is one. Reported so the import
    // can record it in the hash cache: the next run then knows the file is in the database without
    // asking the database at all.
    existingAssetId: string | undefined;

    // How long the hashing itself took, in milliseconds. Zero when the cache answered, because then
    // nothing was hashed. The import sums this across every file so hashing can be accounted for
    // separately from everything else the import does.
    hashMs: number;

    // How long asking the hash cache took, in milliseconds, whether it answered or not.
    cacheLookupMs: number;

    // How long this task took in total, in milliseconds. The import sums this so hashing can be
    // reported as a share of the work the child tasks did, rather than of the run's wall clock,
    // which several tasks are running inside at once.
    taskMs: number;

    // How many bytes were hashed: the file's length when it was hashed, zero when the cache answered.
    bytesHashed: number;
}

//
// Handler for the hash-file task. Computes or retrieves from cache the SHA-256 hash
// of a file and checks whether an asset with that hash already exists in the database.
// Does not queue any downstream tasks; the orchestrator (import-assets) handles that.
//
export async function hashFileHandler(data: IHashFileData, context: ITaskContext): Promise<IHashFileResult> {
    const { filePath, fileStat, contentType, storageDescriptor, hashCacheDir, logicalPath, cacheIdentity } = data;
    const { uuidGenerator, timestampProvider } = context;

    // When this task started, so the whole of it can be reported alongside the part of it that was
    // hashing. Read here rather than in the caller because the caller only sees when the task was
    // queued, which on a busy import is a different thing entirely.
    const taskStartedAt = Date.now();

    // Load the hash cache in read-only mode.
    const localHashCache = new HashCache(hashCacheDir, true);
    await localHashCache.load();

    // Try to retrieve the hash from the cache first.
    const cacheLookupStartedAt = Date.now();
    const cachedHash = await getHashFromCache(filePath, fileStat, localHashCache, cacheIdentity);
    const cacheLookupMs = Date.now() - cacheLookupStartedAt;

    let hashFromCache: boolean;
    let hashBuffer: Buffer;
    let hashMs: number;
    let bytesHashed: number;

    if (cachedHash) {
        hashBuffer = cachedHash.hash as Buffer;
        hashFromCache = true;
        hashMs = 0;
        bytesHashed = 0;
    }
    else {
        const hashStartedAt = Date.now();
        const hashedFile = await validateAndHash(filePath, fileStat, contentType, logicalPath);
        hashMs = Date.now() - hashStartedAt;
        if (!hashedFile) {
            throw new Error(`Failed to validate and hash file "${logicalPath}"`);
        }
        hashBuffer = hashedFile.hash as Buffer;
        hashFromCache = false;
        bytesHashed = fileStat.length;
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
        existingAssetId: existingRecords.length > 0 ? existingRecords[0]._id : undefined,
        hashMs,
        cacheLookupMs,
        taskMs: Date.now() - taskStartedAt,
        bytesHashed,
    };
}

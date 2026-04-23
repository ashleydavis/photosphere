import * as os from "os";
import * as path from "path";
import { ensureDir, remove } from "node-utils";
import { createStorage, loadEncryptionKeysFromPem } from "storage";
import { IDatabaseDescriptor } from "./database-descriptor";
import { resolveStorageCredentials } from "./resolve-storage-credentials";
import type { ITaskContext } from "task-queue";
import { TaskStatus, TaskQueue } from "task-queue";
import { IAsset } from "defs";
import { log, retry, retryOrLog, sleep, swallowError } from "utils";
import { BsonDatabase } from "bdb";
import { addItem, BufferSet } from "merkle-tree";
import throttle from "lodash/throttle";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { updateDatabaseConfig } from "./database-config";
import { HashCache } from "./hash-cache";
import { scanPaths } from "./file-scanner";
import { IHashFileData, IHashFileResult } from "./hash-file.worker";
import { IUploadAssetData, IUploadAssetResult, IAssetDatabaseData } from "./upload-asset.worker";

//
// Payload for the import-assets task. Contains the paths to scan plus the configuration
// needed by downstream hash-file and upload-asset tasks.
//
export interface IImportAssetsData {
    // Filesystem paths (files or directories) to import.
    paths: string[];

    // Identifies the target database and optional encryption key name.
    storageDescriptor: IDatabaseDescriptor;

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey?: string;

    // Unique identifier for the session, used to acquire the write lock.
    sessionId: string;

    // When true, files are scanned and hashed but not written to the database.
    dryRun: boolean;
}

//
// A single pending database update gathered from a completed upload-asset task.
//
interface IPendingDatabaseUpdate {
    // The asset data returned by the upload-asset worker.
    assetData: IAssetDatabaseData;

    // Logical path of the file being imported (for logging).
    logicalPath: string;

    // Total size of the uploaded asset + derivatives in bytes.
    totalSize: number;

    // Pre-computed hash, kept here so it can be deleted from hashesQueuedForImport after commit.
    expectedHash: ArrayBuffer;
}

//
// Orchestrator handler for the import-assets task. Scans filesystem paths, queues
// hash-file tasks for each file found, deduplicates by content hash, queues
// upload-asset tasks for new files, and batches all database writes under a single
// throttled write lock per batch.
//
export async function importAssetsHandler(data: IImportAssetsData, context: ITaskContext): Promise<void> {
    const { paths, storageDescriptor, googleApiKey, sessionId, dryRun } = data;
    const { uuidGenerator, timestampProvider } = context;
    const hashCacheDir = path.join(os.tmpdir(), "photosphere");

    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(storageDescriptor.databasePath, storageDescriptor.encryptionKey);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage, rawStorage } = createStorage(storageDescriptor.databasePath, s3Config, storageOptions);
    const bsonDatabase = new BsonDatabase(storage, ".db/bson", uuidGenerator, timestampProvider);
    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");

    const localHashCache = new HashCache(hashCacheDir);
    await localHashCache.load();

    // Tracks hashes already queued for import in this scan to prevent duplicate uploads.
    const hashesQueuedForImport = new BufferSet();

    let filesAddedToCache = 0;
    let isProcessingQueue = false;
    const queue = new TaskQueue(context.uuidGenerator, sessionId);
    let pendingDatabaseUpdates: IPendingDatabaseUpdate[] = [];

    //
    // Writes a batch of completed uploads to the Merkle tree and BSON database under the write lock.
    // Returns true on success, false if the write lock could not be acquired.
    //
    async function processPendingDatabaseUpdates(itemsToProcess: IPendingDatabaseUpdate[]): Promise<boolean> {
        if (itemsToProcess.length === 0) {
            return true;
        }

        await bsonDatabase.flush();

        if (!await acquireWriteLock(rawStorage, sessionId, 1)) {
            return false;
        }

        log.verbose(`Have write lock, processing ${itemsToProcess.length} items.`);

        try {
            let merkleTree = await retry(() => loadMerkleTree(storage));
            if (!merkleTree) {
                throw new Error(`Failed to load merkle tree.`);
            }

            for (const item of itemsToProcess) {
                const { assetData, logicalPath } = item;

                merkleTree = addItem(merkleTree, {
                    name: assetData.assetPath,
                    hash: Buffer.from(assetData.assetHash, "hex"),
                    length: assetData.assetLength,
                    lastModified: assetData.assetLastModified,
                });

                if (assetData.thumbPath) {
                    merkleTree = addItem(merkleTree, {
                        name: assetData.thumbPath,
                        hash: Buffer.from(assetData.thumbHash!, "hex"),
                        length: assetData.thumbLength!,
                        lastModified: assetData.thumbLastModified!,
                    });
                }

                if (assetData.displayPath) {
                    merkleTree = addItem(merkleTree, {
                        name: assetData.displayPath,
                        hash: Buffer.from(assetData.displayHash!, "hex"),
                        length: assetData.displayLength!,
                        lastModified: assetData.displayLastModified!,
                    });
                }

                if (!dryRun) {
                    await metadataCollection.insertOne(assetData.assetRecord);
                }

                log.verbose(`Added file "${logicalPath}" to the database with ID "${assetData.assetId}".`);
                context.sendMessage({ type: "import-success", assetId: assetData.assetId, logicalPath, micro: assetData.assetRecord.micro });
            }

            if (!merkleTree.databaseMetadata) {
                merkleTree.databaseMetadata = { filesImported: 0 };
            }
            merkleTree.databaseMetadata.filesImported += itemsToProcess.length;

            if (!dryRun) {
                await retry(() => saveMerkleTree(merkleTree, storage));
                await bsonDatabase.commit();
                await updateDatabaseConfig(rawStorage, { lastModifiedAt: new Date().toISOString() });
            }

            return true;
        }
        finally {
            await releaseWriteLock(rawStorage);
            log.verbose(`Released write lock.`);
        }
    }

    //
    // Throttled processor that drains pendingDatabaseUpdates in batches.
    // Trailing-edge throttled so that multiple completions that arrive close together
    // are coalesced into a single write-lock acquisition.
    //
    const throttledProcessQueue = throttle(async () => {
        if (isProcessingQueue || pendingDatabaseUpdates.length === 0) {
            return;
        }

        isProcessingQueue = true;

        try {
            const itemsToProcess = pendingDatabaseUpdates;
            pendingDatabaseUpdates = [];

            const processed = await processPendingDatabaseUpdates(itemsToProcess);
            if (!processed) {
                pendingDatabaseUpdates = pendingDatabaseUpdates.concat(itemsToProcess);
            }
            else {
                for (const item of itemsToProcess) {
                    hashesQueuedForImport.delete(Buffer.from(item.expectedHash));
                }
            }
        }
        catch (error: any) {
            log.exception(`Error processing pending database updates`, error);
        }
        finally {
            isProcessingQueue = false;
        }
    }, 1000, { leading: false, trailing: true });

    //
    // Subscribe to task completions for hash-file and upload-asset tasks that belong
    // to this import session. The source filter prevents concurrent imports from
    // processing each other's completions.
    //
    queue.onTaskComplete(async (result) => { //todo: would be good to have two separate handles here for better type checking!
        if (context.isCancelled()) {
            return;
        }

        if (result.type === "hash-file") {
            const hashFileData = result.inputs as IHashFileData;
            if (result.status === TaskStatus.Succeeded) {
                const hashResult = result.outputs as IHashFileResult;

                if (!hashResult.hashFromCache) {
                    localHashCache.addHash(hashFileData.filePath, {
                        hash: Buffer.from(hashResult.hash),
                        lastModified: hashFileData.fileStat.lastModified,
                        length: hashFileData.fileStat.length,
                    });
                    filesAddedToCache++;
                    if (filesAddedToCache % 100 === 0) {
                        await swallowError(() => localHashCache.save());
                    }
                }

                if (hashResult.filesAlreadyAdded) {
                    context.sendMessage({ type: "import-skipped", assetId: hashFileData.assetId, logicalPath: hashFileData.logicalPath });
                }
                else {
                    const hashBuffer = Buffer.from(hashResult.hash);
                    if (hashesQueuedForImport.has(hashBuffer)) {
                        log.verbose(`File "${hashFileData.logicalPath}" is a duplicate in this scan, skipping.`);
                    }
                    else {
                        hashesQueuedForImport.add(hashBuffer);
                        queue.addTask("upload-asset", {
                            filePath: hashFileData.filePath,
                            fileStat: hashFileData.fileStat,
                            contentType: hashFileData.contentType,
                            storageDescriptor: hashFileData.storageDescriptor,
                            logicalPath: hashFileData.logicalPath,
                            labels: hashFileData.labels,
                            googleApiKey: hashFileData.googleApiKey,
                            sessionId: hashFileData.sessionId,
                            dryRun: hashFileData.dryRun,
                            assetId: hashFileData.assetId,
                            expectedHash: hashResult.hash,
                        });
                    }
                }
            }
            else if (result.status === TaskStatus.Failed) {
                log.error(`Failed to hash file "${hashFileData.logicalPath}": ${result.errorMessage}`);
                context.sendMessage({ type: "import-failed", assetId: hashFileData.assetId, logicalPath: hashFileData.logicalPath });
            }
        }
        else if (result.type === "upload-asset") {
            const uploadData = result.inputs as IUploadAssetData;
            if (result.status === TaskStatus.Succeeded) {
                const uploadResult = result.outputs as IUploadAssetResult;
                pendingDatabaseUpdates.push({
                    assetData: uploadResult.assetData,
                    logicalPath: uploadData.logicalPath,
                    totalSize: uploadResult.totalSize,
                    expectedHash: uploadData.expectedHash.slice().buffer,
                });
                throttledProcessQueue();
            }
            else if (result.status === TaskStatus.Failed) {
                log.error(`Failed to upload file "${uploadData.logicalPath}": ${result.errorMessage}`);
                context.sendMessage({ type: "import-failed", assetId: uploadData.assetId, logicalPath: uploadData.logicalPath });
            }
        }
    });

    const sessionTempDir = path.join(os.tmpdir(), "photosphere", uuidGenerator.generate());
    await ensureDir(sessionTempDir);

    try {
        // Track how many files have been reported as ignored so we can emit one
        // file-ignored message per newly ignored file (scanPaths reports a cumulative count).
        let prevIgnoredCount = 0;

        await scanPaths(
            paths,
            async (result) => {
                if (context.isCancelled()) {
                    return;
                }

                queue.addTask("hash-file", {
                    filePath: result.filePath,
                    fileStat: result.fileStat,
                    contentType: result.contentType,
                    storageDescriptor,
                    hashCacheDir,
                    logicalPath: result.logicalPath,
                    labels: result.labels,
                    googleApiKey,
                    sessionId,
                    dryRun,
                    assetId: uuidGenerator.generate(),
                });
            },
            (currentlyScanning, state) => {
                const newIgnored = state.numFilesIgnored - prevIgnoredCount;
                prevIgnoredCount = state.numFilesIgnored;
                if (newIgnored > 0) {
                    context.sendMessage({ type: "file-ignored", count: newIgnored });
                }
                if (currentlyScanning) {
                    context.sendMessage({ type: "scan-progress", currentPath: currentlyScanning });
                }
            },
            { ignorePatterns: [/\.db/] },
            sessionTempDir,
            uuidGenerator
        );

        //
        // Wait for all child tasks to complete.
        // If the task is cancelled, childQueue.shutdown() in the finally block
        // will resolve this immediately rather than waiting for the backlog.
        //
        await queue.awaitAllTasks();

        if (context.isCancelled()) {
            return;
        }

        // Flush the throttled queue and wait for any in-progress batch to finish.
        throttledProcessQueue.flush();
        throttledProcessQueue.cancel();

        while (isProcessingQueue) {
            await sleep(100);
        }

        // Process any remaining items, retrying until the write lock is acquired.
        while (pendingDatabaseUpdates.length > 0) {
            const processed = await processPendingDatabaseUpdates(pendingDatabaseUpdates);
            if (!processed) {
                log.error(`Failed to acquire write lock for final ${pendingDatabaseUpdates.length} pending database updates; retrying.`);
                await sleep(1000);
            }
            else {
                for (const item of pendingDatabaseUpdates) {
                    hashesQueuedForImport.delete(Buffer.from(item.expectedHash));
                }
                pendingDatabaseUpdates = [];
            }
        }

        await retryOrLog(() => localHashCache.save(), "Failed to save hash cache");
    }
    finally {
        queue.shutdown();
        await swallowError(() => remove(sessionTempDir));
    }
}

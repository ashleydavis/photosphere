import { log, retryOrLog, IUuidGenerator, retry, swallowError, sleep } from "utils";
import { HashCache } from "./hash-cache";
import { scanPaths } from "./file-scanner";
import { IAddSummary } from "./media-file-database";
import { TaskStatus } from "task-queue";
import { IImportFileData, IImportFileResult, IImportFileDatabaseData, IHashFileResult } from "./import.worker";
import type { ITaskQueueProvider } from "task-queue";
import { IStorage, IStorageDescriptor, IS3Credentials } from "storage";
import { IBsonCollection } from "bdb";
import { IAsset } from "defs";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { addItem, BufferSet } from "merkle-tree";
import { throttle } from "lodash";
import * as os from "os";
import * as path from "path";

//
// Progress callback for addPaths that includes the current summary
//
export type AddPathsProgressCallback = (currentlyScanning: string | undefined, summary: IAddSummary) => void;

//
// Pending database update item
//
interface IPendingDatabaseUpdate {
    assetData: IImportFileDatabaseData;
    logicalPath: string;
    totalSize: number;
    expectedHash: ArrayBuffer; // Convert to Buffer only when deleting from hashesQueuedForImport (delayed).
}

//
// Processes pending database updates if write lock can be acquired.
// Returns true if all items were processed, false if lock couldn't be acquired.
//
async function processPendingDatabaseUpdates(
    itemsToProcess: IPendingDatabaseUpdate[],
    metadataStorage: IStorage,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    summary: IAddSummary,
    dryRun: boolean
): Promise<boolean> {
    if (itemsToProcess.length === 0) {
        return true;
    }
    
    if (!await acquireWriteLock(metadataStorage, sessionId, 1)) {
        // Couldn't acquire lock
        return false;
    }
    
    log.verbose(`Have write lock, processing ${itemsToProcess.length} items to update database.`);
    
    try {
        let merkleTree = await retry(() => loadMerkleTree(metadataStorage));
        if (!merkleTree) {
            throw new Error(`Failed to load media file database.`);
        }
        
        // Process all items in the batch
        for (const item of itemsToProcess) {
            const { assetData, logicalPath, totalSize } = item;
            
            // Add asset to merkle tree
            merkleTree = addItem(merkleTree, {
                name: assetData.assetPath,
                hash: Buffer.from(assetData.assetHash, "hex"),
                length: assetData.assetLength,
                lastModified: assetData.assetLastModified,
            });
            
            // Add thumbnail to merkle tree if present
            if (assetData.thumbPath) {
                merkleTree = addItem(merkleTree, {
                    name: assetData.thumbPath,
                    hash: Buffer.from(assetData.thumbHash!, "hex"),
                    length: assetData.thumbLength!,
                    lastModified: assetData.thumbLastModified!,
                });
            }
            
            // Add display to merkle tree if present
            if (assetData.displayPath) {
                merkleTree = addItem(merkleTree, {
                    name: assetData.displayPath,
                    hash: Buffer.from(assetData.displayHash!, "hex"),
                    length: assetData.displayLength!,
                    lastModified: assetData.displayLastModified!,
                });
            }
            
            if (!dryRun) {
                // Insert metadata record
                await metadataCollection.insertOne(assetData.assetRecord);
            }
            
            log.verbose(dryRun 
                ? `[DRY RUN] Would add file "${logicalPath}" to the database with ID "${assetData.assetId}" with id ${assetData.assetId}.`
                : `Added file "${logicalPath}" to the database with ID "${assetData.assetId}" with id ${assetData.assetId}.`);
            summary.filesAdded++;
            summary.totalSize += totalSize;
        }
        
        // Update database metadata
        if (!merkleTree.databaseMetadata) {
            merkleTree.databaseMetadata = { filesImported: 0 };
        }

        merkleTree.databaseMetadata.filesImported += itemsToProcess.length;
        
        // Save merkle tree (skip in dry-run mode)
        if (!dryRun) {
            await retry(() => saveMerkleTree(merkleTree, metadataStorage));
        }
        
        return true;
    }
    finally {
        await releaseWriteLock(metadataStorage);

        log.verbose(`Released write lock, processed ${itemsToProcess.length} items to update database.`);
    }
}

//
// Adds a list of files or directories to the media file database.
//
export async function addPaths(
    metadataStorage: IStorage,
    googleApiKey: string | undefined,
    uuidGenerator: IUuidGenerator,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    paths: string[],
    progressCallback: AddPathsProgressCallback | undefined,
    sessionTempDir: string,
    taskQueueProvider: ITaskQueueProvider,
    storageDescriptor: IStorageDescriptor,
    s3Config: IS3Credentials | undefined,
    dryRun: boolean = false
): Promise<IAddSummary> {
    // Create hash cache for file hashing optimization
    const hashCacheDir = path.join(os.tmpdir(), "photosphere");
    
    const summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        filesProcessed: 0,
        totalSize: 0,
        averageSize: 0,
    };
    // Queue for background import tasks.
    const queue = await taskQueueProvider.create();

    // Counts the number of files added to the cache.
    let filesAddedToCache = 0;

    // Hashes we have already queued for import in this scan (same content at multiple paths = only import once).
    const hashesQueuedForImport = new BufferSet();

    // Set to true when we're processing the queue, set to false when we're done.
    // Prevents us from processing the queue twice.
    let isProcessingQueue = false;
    
    // Queue for pending database updates.
    let pendingDatabaseUpdates: IPendingDatabaseUpdate[] = [];
    
    // Throttled function to process pending database updates
    // Execute on trailing edge (after 1s of inactivity)
    const throttledProcessQueue = throttle(async () => {
        if (isProcessingQueue) {
            // Already processing the queue, return.
            return;
        }

        if (pendingDatabaseUpdates.length === 0) {
            // No items to process, return.
            return;
        }

        log.verbose(`Processing ${pendingDatabaseUpdates.length} pending database updates.`);

        // Stops this function being called again while we're processing the queue.
        isProcessingQueue = true;

        try {
            // Swap the queue with an empty one so we don't process the same items twice.
            // This operation is atomic and no other JS code will be running at this point.
            // Swapping this means we can asynchronously add to the queue while we're processing this batch of items.
            const itemsToProcess = pendingDatabaseUpdates;
            pendingDatabaseUpdates = [];
            
            // Process items (processPendingDatabaseUpdates will handle lock acquisition)
            const processed = await processPendingDatabaseUpdates(itemsToProcess, metadataStorage, sessionId, metadataCollection, summary, dryRun);
            if (!processed) {
                // Lock acquisition failed - re-queue items.
                // This operation is atomic and no other JS code will be running at this point.
                pendingDatabaseUpdates = pendingDatabaseUpdates.concat(itemsToProcess);
            }
            else {
                // Remove from set so hashesQueuedForImport does not grow unbounded (memory bound).
                for (const item of itemsToProcess) {
                    hashesQueuedForImport.delete(Buffer.from(item.expectedHash));
                }
            }

            log.verbose(`Processed ${itemsToProcess.length} pending database updates.`);
        }
        catch (error: any) {
            log.exception(`Error processing pending database updates`, error);
        }
        finally {
            isProcessingQueue = false;
        }
    }, 1000, { leading: false, trailing: true }); // 1s throttle delay, execute on trailing edge

    try {
        //
        // Registers a callback to integrate results as tasks complete.
        // Hash-file completions may trigger an import-file task; import-file completions queue database updates.
        //
        queue.onTaskComplete(async (task, result) => {
            const taskData = task.data as IImportFileData;

            if (task.type === "hash-file") {
                summary.filesProcessed++;

                if (result.status === TaskStatus.Succeeded) {
                    const hashResult = result.outputs as IHashFileResult;

                    // Add hash to cache if computation was successful and hash wasn't already in cache.
                    if (!hashResult.hashFromCache) {
                        localHashCache.addHash(taskData.filePath, {
                            hash: Buffer.from(hashResult.hash),
                            lastModified: taskData.fileStat.lastModified,
                            length: taskData.fileStat.length,
                        });

                        filesAddedToCache++;

                        // Save cache periodically (every 100 files added to cache).
                        if (filesAddedToCache % 100 === 0) {
                            await swallowError(() => localHashCache.save());
                        }
                    }

                    if (hashResult.filesAlreadyAdded) {
                        log.verbose(`File "${taskData.logicalPath}" is already in the database.`);
                        summary.filesAlreadyAdded++;
                    }
                    else {
                        const hashBuffer = Buffer.from(hashResult.hash);
                        if (hashesQueuedForImport.has(hashBuffer)) {
                            log.verbose(`File "${taskData.logicalPath}" has same content as another file in this scan, skipping import (already queued).`);
                        }
                        else {
                            hashesQueuedForImport.add(hashBuffer);
                            log.verbose(`File "${taskData.logicalPath}" is not in the database, queueing import task.`);

                            // Not in database - queue import task with pre-computed hash so worker skips hashing and duplicate check.
                            queue.addTask("import-file", {
                                ...taskData,
                                expectedHash: hashResult.hash,
                            });
                        }
                    }
                }
                else if (result.status === TaskStatus.Failed) {
                    if (result.error) {
                        log.exception(`Failed to hash file "${taskData.logicalPath}": ${result.errorMessage}`, result.error);
                    }
                    else {
                        log.error(`Failed to hash file "${taskData.logicalPath}": ${result.errorMessage}`);
                    }
                    summary.filesFailed++;
                }
            }
            else if (task.type === "import-file") {
                if (result.status === TaskStatus.Succeeded) {
                    const importResult = result.outputs as IImportFileResult;

                    // Worker has uploaded files, now queue for database update.
                    if (!importResult.assetData) {
                        throw new Error(`Missing assetData for file "${taskData.logicalPath}"`);
                    }

                    pendingDatabaseUpdates.push({
                        assetData: importResult.assetData,
                        logicalPath: taskData.logicalPath,
                        totalSize: importResult.totalSize,
                        expectedHash: taskData.expectedHash,
                    });

                    log.verbose(`Added ${taskData.logicalPath} (${taskData.assetId}) to pending database updates queue.`);

                    throttledProcessQueue();
                }
                else if (result.status === TaskStatus.Failed) {
                    if (result.error) {
                        log.exception(`Failed to import file "${taskData.logicalPath}": ${result.errorMessage}`, result.error);
                    }
                    else {
                        log.error(`Failed to import file "${taskData.logicalPath}": ${result.errorMessage}`);
                    }
                    summary.filesFailed++;
                }
            }
        });

        //
        // Queue hash-file tasks as files are scanned. When a hash completes and the file is not already in the database,
        // an import-file task is queued to do metadata extraction, uploads, and database updates.
        //
        await scanPaths(paths, async (result) => {
            queue.addTask("hash-file", {
                filePath: result.filePath,
                fileStat: result.fileStat,
                contentType: result.contentType,
                storageDescriptor,
                hashCacheDir,
                s3Config,
                logicalPath: result.logicalPath,
                labels: result.labels,
                googleApiKey,
                sessionId,
                dryRun,
                assetId: uuidGenerator.generate(),
            });
        }, (currentlyScanning, state) => {
            summary.filesIgnored = state.numFilesIgnored;
            if (progressCallback) {
                progressCallback(currentlyScanning, summary);
            }
        }, { ignorePatterns: [/\.db/] }, sessionTempDir, uuidGenerator);

        log.verbose(`Waiting for all tasks to complete.`);

        //
        // Wait for all tasks to complete.
        //
        await queue.awaitAllTasks();

        log.verbose(`All tasks completed, flushing throttled queue.`);
        
        //
        // Flush the throttled queue then cancel any pending calls.
        //
        throttledProcessQueue.flush();
        throttledProcessQueue.cancel();

        log.verbose(`Waiting for queue processing to complete.`);

        while (isProcessingQueue) {
            await sleep(100);
        }

        log.verbose(`Queue processing complete, processing final ${pendingDatabaseUpdates.length} pending database updates.`);

        if (pendingDatabaseUpdates.length !== 0) {
            const processed = await processPendingDatabaseUpdates(pendingDatabaseUpdates, metadataStorage, sessionId, metadataCollection, summary, dryRun);
            if (!processed) {
                log.error(`Failed to process final ${pendingDatabaseUpdates.length} pending database updates.`);
            }
        }

        log.verbose(`All done`);

        // Final save of hash cache.
        // We'd like to retry in case of error, but if it fails we just log it and move on.
        await retryOrLog(() => localHashCache.save(), "Failed to save hash cache");
        
        summary.averageSize = summary.filesAdded > 0 ? Math.floor(summary.totalSize / summary.filesAdded) : 0;
        return summary;
    }
    finally {
        queue.shutdown();
    }
}


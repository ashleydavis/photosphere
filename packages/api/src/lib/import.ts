import { log, retryOrLog, IUuidGenerator, retry, swallowError, sleep } from "utils";
import { HashCache } from "./hash-cache";
import { scanPaths } from "./file-scanner";
import { IAddSummary } from "./media-file-database";
import { TaskStatus } from "task-queue";
import { IImportFileData, IImportFileResult, IImportFileDatabaseData } from "./import.worker";
import type { ITaskQueueProvider } from "task-queue";
import { IStorage, IStorageDescriptor, IS3Credentials } from "storage";
import { IBsonCollection } from "bdb";
import { IAsset } from "defs";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { addItem } from "merkle-tree";
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
                ? `[DRY RUN] Would add file "${logicalPath}" to the database with ID "${assetData.assetId}".`
                : `Added file "${logicalPath}" to the database with ID "${assetData.assetId}".`);
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
    const queue = await taskQueueProvider.create();
    let filesAddedToCache = 0;
    
    // Queue for pending database updates
    let pendingDatabaseUpdates: IPendingDatabaseUpdate[] = [];

    try {
        //
        // Registers a callback to integrate results as tasks complete.
        //
        queue.onTaskComplete<IImportFileData, IImportFileResult>(async (task, result) => {
            
            summary.filesProcessed++;

            if (result.status === TaskStatus.Succeeded) {
                const importResult = result.outputs!;
                const taskData = task.data;
                
                // Add hash to cache if computation was successful and hash wasn't already in cache
                if (!importResult.hashFromCache) {
                    localHashCache.addHash(taskData.filePath, {
                        hash: Buffer.from(importResult.hashedFile.hash, "hex"),
                        lastModified: new Date(importResult.hashedFile.lastModified),
                        length: importResult.hashedFile.length,
                    });
                    
                    filesAddedToCache++;
                    
                    // Save cache periodically (every 100 files added to cache)
                    if (filesAddedToCache % 100 === 0) {
                        // This can fail because workers are constantly loading the hash cache. 
                        // If it fails we just swallow it, the hash cache remains dirty and we'll try to save again in another 100 files.
                        await swallowError(() => localHashCache.save()); 
                    }
                }
                
                // Process results from worker
                if (importResult.filesAlreadyAdded) {
                    log.verbose(`File "${taskData.logicalPath}" is already in the database.`);
                    summary.filesAlreadyAdded++;
                }
                else {
                    // Worker has uploaded files, now queue for database update
                    // assetData must be present if task completed successfully and filesAlreadyAdded is false
                    if (!importResult.assetData) {
                        throw new Error(`Missing assetData for file "${taskData.logicalPath}"`);
                    }
                    
                    // Add to pending database updates queue
                    pendingDatabaseUpdates.push({
                        assetData: importResult.assetData,
                        logicalPath: taskData.logicalPath,
                        totalSize: importResult.totalSize,
                    });

                    log.verbose(`Added ${taskData.logicalPath} to pending database updates queue.`);
                    
                    // Try to process the queue if lock is free (non-blocking - if lock can't be acquired, items stay in queue)
                    const lockInfo = await metadataStorage.checkWriteLock(".db/write.lock");
                    if (lockInfo) {
                        log.verbose(`Write lock is held, have ${pendingDatabaseUpdates.length} items queued to update database.`);
                    }
                    else {
                        // Lock is free and we have items - try to process
                        const itemsToProcess = pendingDatabaseUpdates;
                        pendingDatabaseUpdates = [];
                        const processed = await processPendingDatabaseUpdates(itemsToProcess, metadataStorage, sessionId, metadataCollection, summary, dryRun);
                        if (!processed) {
                            // Lock acquisition failed - re-queue items
                            pendingDatabaseUpdates = pendingDatabaseUpdates.concat(itemsToProcess);
                        }
                    }
                }                
            } 
            else if (result.status === TaskStatus.Failed) {
                if (result.error) {
                    log.exception(`Failed to import file "${task.data.logicalPath}": ${result.errorMessage}`, result.error);
                } 
                else {
                    log.error(`Failed to import file "${task.data.logicalPath}": ${result.errorMessage}`);
                }
                summary.filesFailed++;
            }
        });

        //
        // Queue up all import tasks as files are scanned.
        // All files are queued - workers will handle everything: hashing, checking, metadata extraction, uploads, and database updates.
        //
        await scanPaths(paths, async (result) => {
            // Queue all files for worker processing (workers will handle everything)
            queue.addTask("import-file", {
                filePath: result.filePath, // Use filePath for checking (always a valid file, possibly temp file from zip)
                fileStat: result.fileStat,
                contentType: result.contentType,
                storageDescriptor,
                hashCacheDir,
                s3Config,
                logicalPath: result.logicalPath, // Use logicalPath for display to user
                labels: result.labels,
                googleApiKey,
                sessionId,
                dryRun,
            } as IImportFileData);
        }, (currentlyScanning, state) => {
            summary.filesIgnored = state.numFilesIgnored;
            if (progressCallback) {
                progressCallback(currentlyScanning, summary);
            }
        }, { ignorePatterns: [/\.db/] }, sessionTempDir, uuidGenerator);

        //
        // Wait for all tasks to complete.
        //
        await queue.awaitAllTasks();
        
        // Process any remaining items in the database update queue
        // Wait until write lock is free before processing (previous processing should be done by now)
        if (pendingDatabaseUpdates.length > 0) {           
            // Wait until write lock is free
            let lockInfo = await metadataStorage.checkWriteLock(".db/write.lock");
            while (lockInfo) {
                await sleep(50);
                lockInfo = await metadataStorage.checkWriteLock(".db/write.lock");
            }
            
            // Now process the remaining items
            if (!await processPendingDatabaseUpdates(pendingDatabaseUpdates, metadataStorage, sessionId, metadataCollection, summary, dryRun)) {
                throw new Error(`Failed to process ${pendingDatabaseUpdates.length} remaining items`);
            }
        }


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


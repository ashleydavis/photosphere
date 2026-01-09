import { log, retry, tryOrLog, retryOrLog, swallowError, IUuidGenerator } from "utils";
import { HashCache } from "./hash-cache";
import { scanPaths } from "./file-scanner";
import { IAddSummary } from "./media-file-database";
import { TaskStatus } from "task-queue";
import { ICheckFileData, ICheckFileResult } from "./check.worker";
import type { ITaskQueueProvider } from "task-queue";
import { IStorageDescriptor, IS3Credentials } from "storage";
import * as os from "os";
import * as path from "path";

//
// Progress callback for checkPaths that includes the current summary
//
export type CheckPathsProgressCallback = (currentlyScanning: string | undefined, summary: IAddSummary) => void;

//
// Checks a list of files or directories to find files already added to the media file database.
//
export async function checkPaths(
    storageDescriptor: IStorageDescriptor,
    paths: string[],
    progressCallback: CheckPathsProgressCallback | undefined,
    taskQueueProvider: ITaskQueueProvider,
    s3Config: IS3Credentials | undefined,
    uuidGenerator: IUuidGenerator,
    sessionTempDir: string
): Promise<IAddSummary> {
    // Create hash cache for file hashing optimization
    const hashCacheDir = path.join(os.tmpdir(), "photosphere");
    const localHashCache = new HashCache(hashCacheDir);
    await localHashCache.load();

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

    try {
        //
        // Registers a callback to integrate results as tasks complete.
        //
        queue.onTaskComplete<ICheckFileData, ICheckFileResult>(async (task, result) => {
            if (result.status === TaskStatus.Succeeded) {

                summary.filesProcessed++;

                const checkResult = result.outputs!;
                const taskData = task.data;
                
                // Add hash to cache if computation was successful and hash wasn't already in cache
                if (checkResult.hashedFile) {
                    if (!checkResult.hashFromCache) {
                        localHashCache.addHash(taskData.filePath, {
                            hash: Buffer.from(checkResult.hashedFile.hash, "hex"),
                            lastModified: new Date(checkResult.hashedFile.lastModified),
                            length: checkResult.hashedFile.length,
                        });
                        
                        filesAddedToCache++;
                        
                        // Save cache periodically (every 100 files added to cache)
                        if (filesAddedToCache % 100 === 0) {

                            await swallowError(() => localHashCache.save());
                        }
                    }
                    
                    // Use database lookup result from worker
                    // Use logicalPath for display (always set)
                    if (checkResult.matchingRecordsCount > 0) {
                        log.verbose(`File "${taskData.logicalPath}" with hash "${checkResult.hashedFile.hash}", matches ${checkResult.matchingRecordsCount} existing records.`);
                        summary.filesAlreadyAdded++;
                    } 
                    else {
                        log.verbose(`File "${taskData.logicalPath}" has not been added to the media file database.`);
                        summary.filesAdded++;
                        summary.totalSize += taskData.fileStat.length;
                    }
                } 
                else {
                    log.error(`Failed to get hash for file ${taskData.logicalPath}`);
                    summary.filesFailed++;
                }                
            } 
            else if (result.status === TaskStatus.Failed) {
                const taskData = task.data as ICheckFileData;
                const logicalPath = taskData.logicalPath || "unknown";
                if (result.error) {
                    log.exception(`Failed to check file "${logicalPath}": ${result.errorMessage}`, result.error);
                } 
                else {
                    log.error(`Failed to check file "${logicalPath}": ${result.errorMessage}`);
                }
                summary.filesFailed++;
                summary.filesProcessed++;
            }
        });

        //
        // Queue up all checking tasks as files are scanned.
        // All files are queued - workers will check cache and database.
        //
        await scanPaths(paths, async (result) => {
            // Queue all files for worker processing (workers will check cache and database)
            queue.addTask("check-file", {
                filePath: result.filePath, // Use filePath for checking (always a valid file, possibly temp file from zip)
                fileStat: result.fileStat,
                contentType: result.contentType,
                storageDescriptor,
                hashCacheDir,
                s3Config,
                logicalPath: result.logicalPath, // Use logicalPath for display to user
            } as ICheckFileData);
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

        // Final save of hash cache
        await retryOrLog(() => localHashCache.save(), "Failed to save hash cache");
        
        summary.averageSize = summary.filesAdded > 0 ? Math.floor(summary.totalSize / summary.filesAdded) : 0;
        return summary;
    } finally {
        queue.shutdown();
    }
}


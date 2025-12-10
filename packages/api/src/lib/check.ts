import { log, retry } from "utils";
import { HashCache } from "./hash-cache";
import { ScannerOptions, scanPaths } from "./file-scanner";
import { IAddSummary } from "./media-file-database";
import { TaskStatus, ITaskResult } from "task-queue";
import { ICheckFileData, ICheckFileResult } from "./check.worker";
import { ITaskQueueProvider } from "./verify";
import { IStorageDescriptor, IS3Credentials } from "storage";

//
// Progress callback for checkPaths that includes the current summary
//
export type CheckPathsProgressCallback = (currentlyScanning: string | undefined, summary: IAddSummary) => void;

//
// Checks a list of files or directories to find files already added to the media file database.
//
export async function checkPaths(
    storageDescriptor: IStorageDescriptor,
    localHashCache: HashCache,
    paths: string[],
    progressCallback: CheckPathsProgressCallback | undefined,
    taskQueueProvider: ITaskQueueProvider,
    hashCacheDir: string,
    s3Config: IS3Credentials | undefined
): Promise<IAddSummary> {
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
        queue.onTaskComplete<ICheckFileData, ICheckFileResult>(async (taskResult) => {
            if (taskResult.status === TaskStatus.Completed) {

                summary.filesProcessed++;

                const checkResult = taskResult.outputs!;
                const taskData = taskResult.inputs;
                
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
                            await retry(() => localHashCache.save());
                        }
                    }
                    
                    // Use database lookup result from worker
                    if (checkResult.alreadyInDatabase) {
                        log.verbose(`File "${taskData.filePath}" with hash "${checkResult.hashedFile.hash}", matches existing records.`);
                        summary.filesAlreadyAdded++;
                    } 
                    else {
                        log.verbose(`File "${taskData.filePath}" has not been added to the media file database.`);
                        summary.filesAdded++;
                        summary.totalSize += taskData.fileStat.length;
                    }
                } 
                else {
                    summary.filesFailed++;
                }                
            } 
            else if (taskResult.status === TaskStatus.Failed) {
                const fileName = taskResult.inputs.filePath || "unknown";
                if (taskResult.error) {
                    log.exception(`Failed to check file "${fileName}": ${taskResult.errorMessage}`, taskResult.error);
                } 
                else {
                    log.error(`Failed to check file "${fileName}": ${taskResult.errorMessage}`);
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
                filePath: result.filePath,
                fileStat: result.fileStat,
                contentType: result.contentType,
                storageDescriptor,
                hashCacheDir,
                s3Config,
                zipFilePath: result.zipFilePath,
            } as ICheckFileData);
        }, (currentlyScanning, state) => {
            summary.filesIgnored = state.numFilesIgnored;
            if (progressCallback) {
                progressCallback(currentlyScanning, summary);
            }
        }, { ignorePatterns: [/\.db/] });

        //
        // Wait for all tasks to complete.
        //
        await queue.awaitAllTasks();

        // Final save of hash cache
        await retry(() => localHashCache.save());
        
        summary.averageSize = summary.filesAdded > 0 ? Math.floor(summary.totalSize / summary.filesAdded) : 0;
        return summary;
    } finally {
        queue.shutdown();
    }
}


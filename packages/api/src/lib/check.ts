import { log, retry } from "utils";
import { HashCache } from "./hash-cache";
import { FileScanner } from "./file-scanner";
import { ProgressCallback, IAddSummary } from "./media-file-database";
import { TaskStatus, ITaskResult } from "task-queue";
import { ICheckFileData, ICheckFileResult } from "./check.worker";
import { ITaskQueueProvider } from "./verify";
import { IStorageDescriptor, IS3Credentials } from "storage";

//
// Checks a list of files or directories to find files already added to the media file database.
//
export async function checkPaths(
    storageDescriptor: IStorageDescriptor,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    paths: string[],
    progressCallback: ProgressCallback,
    taskQueueProvider: ITaskQueueProvider,
    hashCacheDir: string,
    s3Config: IS3Credentials | undefined,
    summary: IAddSummary
): Promise<IAddSummary> {
    const queue = await taskQueueProvider.create();

    try {
        //
        // Registers a callback to integrate results as tasks complete.
        //
        queue.onTaskComplete(async (taskResult: ITaskResult) => {
            if (taskResult.status === TaskStatus.Completed) {
                const checkResult = taskResult.outputs as ICheckFileResult;
                const taskData = taskResult.inputs as ICheckFileData;
                
                // Add hash to cache if computation was successful
                if (checkResult.hashedFile) {
                    localHashCache.addHash(taskData.filePath, {
                        hash: Buffer.from(checkResult.hashedFile.hash, "hex"),
                        lastModified: new Date(checkResult.hashedFile.lastModified),
                        length: checkResult.hashedFile.length,
                    });
                    
                    // Save cache periodically
                    if (summary.filesAdded % 100 === 0) {
                        await retry(() => localHashCache.save());
                    }
                    
                    // Use database lookup result from worker
                    if (checkResult.alreadyInDatabase) {
                        log.verbose(`File "${taskData.filePath}" with hash "${checkResult.hashedFile.hash}", matches existing records.`);
                        summary.filesAlreadyAdded++;
                    } else {
                        log.verbose(`File "${taskData.filePath}" has not been added to the media file database.`);
                        summary.filesAdded++;
                        summary.totalSize += taskData.fileStat.length;
                    }
                } else {
                    summary.filesFailed++;
                }
                
                if (progressCallback) {
                    progressCallback(localFileScanner.getCurrentlyScanning());
                }
            } else if (taskResult.status === TaskStatus.Failed) {
                const taskData = taskResult.inputs as ICheckFileData;
                log.error(`Failed to check file "${taskData.filePath}"`);
                summary.filesFailed++;
            }
        });

        //
        // Queue up all checking tasks as files are scanned.
        // All files are queued - workers will check cache and database.
        //
        await localFileScanner.scanPaths(paths, async (result) => {
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
            
            if (progressCallback) {
                progressCallback(localFileScanner.getCurrentlyScanning());
            }
        }, progressCallback);

        //
        // Wait for all tasks to complete.
        //
        await queue.awaitAllTasks();

        // Final save of hash cache
        await retry(() => localHashCache.save());
        
        // Add scanner's ignored and failed counts to summary
        summary.filesIgnored += localFileScanner.getNumFilesIgnored();
        summary.filesFailed += localFileScanner.getNumFilesFailed();
        
        summary.averageSize = summary.filesAdded > 0 ? Math.floor(summary.totalSize / summary.filesAdded) : 0;
        return summary;
    } finally {
        queue.shutdown();
    }
}


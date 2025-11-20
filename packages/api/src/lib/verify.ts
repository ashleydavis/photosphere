import {  log, retry } from "utils";
import { ProgressCallback, getDatabaseSummary } from "./media-file-database";
import { SortNode, traverseTreeAsync } from "merkle-tree";
import { loadMerkleTree } from "./tree";
import { IStorage, IStorageDescriptor } from "storage";
import { TaskStatus, ITaskResult, ITaskQueue } from "task-queue";
import { deserializeError } from "serialize-error";

//
// Provider object that creates and manages task queues.
//
export interface ITaskQueueProvider {
    create(): Promise<ITaskQueue>;
}

//
// Options for verifying the media file database.
//


export interface IVerifyOptions {
    //
    // Enables full verification where all files are re-hashed.
    //
    full?: boolean;

    //
    // Path filter to only verify files matching this path (file or directory).
    //
    pathFilter?: string;
}

//
// Result of the verification process.
//
export interface IVerifyResult {
    //
    // The total number of files imported into the database.
    //
    totalImports: number;

    //
    // The total number of files verified (including thumbnails, display, BSON, etc.).
    //
    totalFiles: number;

    //
    // The total database size.
    //
    totalSize: number;

    //
    // The number of files that were unmodified.
    //
    numUnmodified: number;

    //
    // The number of files that failed to verify.
    //
    numFailures: number;

    //
    // The list of files that were modified.
    //
    modified: string[];

    //
    // The list of new files that were added to the database.
    //
    new: string[];

    //
    // The list of files that were removed from the database.
    //
    removed: string[];

    //
    // The number of files that were processed from the file system.
    // 
    filesProcessed: number;

    //
    // The number of nodes processed in the merkle tree.
    //
    nodesProcessed: number;
}

//
// Verifies the media file database.
// Checks for missing files, modified files, and new files.
// If any files are corrupted, this will pick them up as modified.
//
export async function verify(assetStorage: IStorage, metadataStorage: IStorage, taskQueueProvider: ITaskQueueProvider, options?: IVerifyOptions, progressCallback?: ProgressCallback, storageDescriptor?: IStorageDescriptor) : Promise<IVerifyResult> {

    let pathFilter = options?.pathFilter 
        ? options.pathFilter.replace(/\\/g, '/') // Normalize path separators
        : undefined;

    const summary = await getDatabaseSummary(assetStorage, metadataStorage);
    const result: IVerifyResult = {
        totalImports: summary.totalImports,
        totalFiles: summary.totalFiles,
        totalSize: summary.totalSize,
        numUnmodified: 0,
        numFailures: 0,
        modified: [],
        new: [],
        removed: [],
        filesProcessed: 0,
        nodesProcessed: 0,
    };

    //
    // Check the merkle tree to find files that have been removed.
    //
    if (progressCallback) {
        if (options?.pathFilter) {
            progressCallback(`Verifying files matching: ${options.pathFilter}`);
        } else {
            progressCallback(`Verifying files...`);
        }
    }

    //
    // Result from verifying a single file.
    //
    interface IVerifyFileResult {
        fileName: string;
        status: "removed" | "modified" | "unmodified";
        reasons?: string[];
    }

    //
    // Get the task queue from the provider (lazily created).
    // Handlers are registered in the worker file (apps/cli/src/lib/worker.ts).
    // maxWorkers is set in the provider constructor (defaults to number of CPUs).
    //
    const queue = await taskQueueProvider.create();

    try {
        //
        // Registers a callback to integrate results as tasks complete.
        //
        queue.onTaskComplete((taskResult: ITaskResult) => {
            if (taskResult.status === TaskStatus.Completed) {
                const fileResult = taskResult.outputs as IVerifyFileResult;
                result.filesProcessed++;

                if (progressCallback) {
                    const status = queue.getStatus();
                    progressCallback(`Verified file ${result.filesProcessed} of ${summary.totalFiles} (${status.running} tasks running in parallel)`);
                }

                if (fileResult.status === "removed") {
                    result.removed.push(fileResult.fileName);
                } else if (fileResult.status === "modified") {
                    result.modified.push(fileResult.fileName);
                } else {
                    result.numUnmodified++;
                }
            } else if (taskResult.status === TaskStatus.Failed) {
                // Task failed - track the failure separately
                let errorMessage: string;
                if (taskResult.error) {
                    try {
                        const errorObj = JSON.parse(taskResult.error);
                        const deserializedError = deserializeError(errorObj);
                        errorMessage = deserializedError.message || String(deserializedError);
                    } catch {
                        // Error is not JSON, use it as-is
                        errorMessage = taskResult.error;
                    }
                } else {
                    errorMessage = "Unknown error";
                }
                const fileName = taskResult.inputs?.node?.name || "unknown";
                log.error(`Failed to verify file "${fileName}": ${errorMessage}`);
                result.filesProcessed++;
                result.numFailures++;
            }
        });

        const merkleTree = await retry(() => loadMerkleTree(metadataStorage));
        if (!merkleTree) {
            throw new Error(`Failed to load merkle tree`);
        }

        //
        // Queue up all verification tasks as quickly as possible.
        // Pass the storage descriptor instead of the storage object (which can't be serialized).
        // Filter nodes by pathFilter before queuing tasks.
        //
        const descriptor: IStorageDescriptor = storageDescriptor || {
            location: assetStorage.location
        };
        await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
            result.nodesProcessed++;

            if (node.name) {
                // Apply path filter before queuing the task
                if (pathFilter && !node.name.startsWith(pathFilter)) {
                    return true; // Skip this node
                }

                queue.addTask("verify-file", {
                    node,
                    storageDescriptor: descriptor,
                    options,
                });
            }

            return true;
        });

        //
        // Wait for all tasks to complete.
        //
        await queue.awaitAllTasks();

        //
        // Log debug information about task execution.
        //
        const stats = queue.getExecutionStats();
        log.verbose(`Verification complete: ${stats.tasksQueued} tasks queued, ${stats.peakWorkers} workers allocated, ${stats.completed} completed, ${stats.failed} failed`);

        return result;
    } finally {
        queue.shutdown();
    }
}

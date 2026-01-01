import { log, retry } from "utils";
import { ProgressCallback } from "./media-file-database";
import { SortNode, traverseTreeAsync } from "merkle-tree";
import { loadMerkleTree } from "./tree";
import { IStorage, IStorageDescriptor, IS3Credentials } from "storage";
import { TaskStatus } from "task-queue";
import { IVerifyFileData } from "./verify.worker";
import type { ITaskQueueProvider } from "task-queue";

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

    //
    // Optional S3 configuration for accessing S3-hosted storage.
    //
    s3Config?: IS3Credentials;
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
export async function verify(storageDescriptor: IStorageDescriptor, metadataStorage: IStorage, taskQueueProvider: ITaskQueueProvider, options?: IVerifyOptions, progressCallback?: ProgressCallback) : Promise<IVerifyResult> {

    let pathFilter = options?.pathFilter 
        ? options.pathFilter.replace(/\\/g, '/') // Normalize path separators
        : undefined;

    // Load the merkle tree once and reuse it throughout the verification process
    const merkleTree = await retry(() => loadMerkleTree(metadataStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    const totalFiles = merkleTree.sort?.leafCount || 0;
    const result: IVerifyResult = {
        totalImports: merkleTree.databaseMetadata?.filesImported || 0,
        totalFiles,
        totalSize: merkleTree.sort?.size || 0,
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
        queue.onTaskComplete<IVerifyFileData, IVerifyFileResult>((taskResult) => {

            result.filesProcessed++;
            
            if (taskResult.status === TaskStatus.Completed) {
                const fileResult = taskResult.outputs!;

                if (progressCallback) {
                    const status = queue.getStatus();
                    progressCallback(`Verified file ${result.filesProcessed} of ${totalFiles} (${status.running} tasks running in parallel)`);
                }

                if (fileResult.status === "removed") {
                    result.removed.push(fileResult.fileName);
                }
                else if (fileResult.status === "modified") {
                    result.modified.push(fileResult.fileName);
                }
                else {
                    result.numUnmodified++;
                }
            } 
            else if (taskResult.status === TaskStatus.Failed) {
                const fileName = taskResult.inputs.node?.name || "unknown";
                if (taskResult.error) {
                    log.exception(`Failed to verify file "${fileName}": ${taskResult.errorMessage}`, taskResult.error);
                } 
                else {
                    log.error(`Failed to verify file "${fileName}": ${taskResult.errorMessage}`);
                }
                result.numFailures++;
            }
        });

        //
        // Queue up all verification tasks as quickly as possible.
        // Pass the storage descriptor instead of the storage object (which can't be serialized).
        // Filter nodes by pathFilter before queuing tasks.
        //
        await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
            result.nodesProcessed++;

            if (node.name) {
                // Apply path filter before queuing the task
                if (pathFilter && !node.name.startsWith(pathFilter)) {
                    return true; // Skip this node
                }

                queue.addTask("verify-file", {
                    node,
                    storageDescriptor,
                    s3Config: options?.s3Config,
                    options: {
                        full: options?.full,
                    },
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
        const status = queue.getStatus();
        log.verbose(`Verification complete: ${status.tasksQueued} tasks queued, ${status.peakWorkers} workers allocated, ${status.completed} completed, ${status.failed} failed`);

        return result;
    } finally {
        queue.shutdown();
    }
}

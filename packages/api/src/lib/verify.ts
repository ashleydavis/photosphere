import { formatFileSize, log, retry } from "utils";
import { ProgressCallback, getDatabaseSummary } from "./media-file-database";
import { computeAssetHash } from "./hash";
import { SortNode, traverseTreeAsync } from "merkle-tree";
import { loadMerkleTree } from "./tree";
import { IStorage } from "storage";
import { TaskQueue, TaskStatus, ITaskResult } from "task-queue";

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
export async function verify(assetStorage: IStorage, options?: IVerifyOptions, progressCallback?: ProgressCallback) : Promise<IVerifyResult> {

    let pathFilter = options?.pathFilter 
        ? options.pathFilter.replace(/\\/g, '/') // Normalize path separators
        : undefined;

    const summary = await getDatabaseSummary(assetStorage);
    const result: IVerifyResult = {
        totalImports: summary.totalImports,
        totalFiles: summary.totalFiles,
        totalSize: summary.totalSize,
        numUnmodified: 0,
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
        progressCallback(`Checking for modified/removed files...`);
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
    // Creates a task queue and registers the verify file handler.
    //
    const queue = new TaskQueue(4); // Use 4 workers for parallel verification

    //
    // Registers a handler that verifies a single file.
    //
    queue.registerHandler("verify-file", async (data: { node: SortNode; assetStorage: IStorage; options?: IVerifyOptions; pathFilter?: string }) => {
        const { node, assetStorage, options, pathFilter } = data;
        const fileName = node.name!;

        if (pathFilter) {
            if (!fileName.startsWith(pathFilter)) {
                // Skip files that don't match the path filter
                return {
                    fileName,
                    status: "unmodified",
                };
            }
        }

        const fileInfo = await assetStorage.info(fileName);
        if (!fileInfo) {
            // The file doesn't exist in the storage.
            log.warn(`File "${fileName}" is missing, even though we just found it by walking the directory.`);
                return {
                    fileName,
                    status: "removed",
                };
        }

        const sizeChanged = node.size !== fileInfo.length;
        const timestampChanged = node.lastModified === undefined || node.lastModified!.getTime() !== fileInfo.lastModified.getTime();             
        if (sizeChanged || timestampChanged) {
            // File metadata has changed - check if content actually changed by computing the hash.
            const freshHash = await computeAssetHash(fileName, fileInfo, () => assetStorage.readStream(fileName));
            if (Buffer.compare(freshHash.hash, node.contentHash!) !== 0) {
                // The file content has actually been modified.
                const reasons: string[] = [];
                if (sizeChanged) {
                    const oldSize = formatFileSize(node.size);
                    const newSize = formatFileSize(fileInfo.length);
                    reasons.push(`size changed (${oldSize} → ${newSize})`);
                }
                if (timestampChanged) {
                    const oldTime = node.lastModified!.toLocaleString();
                    const newTime = fileInfo.lastModified.toLocaleString();
                    reasons.push(`timestamp changed (${oldTime} → ${newTime})`);
                }
                reasons.push('content hash changed');
                
                if (log.verboseEnabled) {
                    log.verbose(`Modified file: ${node.name} - ${reasons.join(', ')}`);
                }
                
                return {
                    fileName,
                    status: "modified",
                    reasons,
                };
            } 
            else {
                // Content is the same, just metadata changed - cache is already updated by computeHash.
                return {
                    fileName,
                    status: "unmodified",
                };
            }
        }
        else if (options?.full) {
            // The file doesn't seem to have changed, but the full verification is requested.
            const freshHash = await computeAssetHash(fileName, fileInfo, () => assetStorage.readStream(fileName));
            if (Buffer.compare(freshHash.hash, node.contentHash!) === 0) {
                // The file is unmodified.
                return {
                    fileName,
                    status: "unmodified",
                };
            } 
            else {
                // The file has been modified (content only, since metadata matched).
                if (log.verboseEnabled) {
                    log.verbose(`Modified file: ${node.name} - content hash changed`);
                }
                return {
                    fileName,
                    status: "modified",
                    reasons: ["content hash changed"],
                };
            }
        }
        else {
            return {
                fileName,
                status: "unmodified",
            };
        }
    });

    //
    // Registers a callback to integrate results as tasks complete.
    //
    queue.onTaskComplete((taskResult: ITaskResult) => {
        if (taskResult.status === TaskStatus.Completed) {
            const fileResult = taskResult.outputs as IVerifyFileResult;
            result.filesProcessed++;

            if (progressCallback) {
                progressCallback(`Verified file ${result.filesProcessed} of ${summary.totalFiles}`);
            }

            if (fileResult.status === "removed") {
                result.removed.push(fileResult.fileName);
            } else if (fileResult.status === "modified") {
                result.modified.push(fileResult.fileName);
            } else {
                result.numUnmodified++;
            }
        } else if (taskResult.status === TaskStatus.Failed) {
            // Task failed - treat as error but continue processing
            const errorObj = JSON.parse(taskResult.error || "{}");
            log.error(`Failed to verify file: ${errorObj.message}`);
            result.filesProcessed++;
        }
    });

    const merkleTree = await retry(() => loadMerkleTree(assetStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    //
    // Queue up all verification tasks as quickly as possible.
    //
    await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
        result.nodesProcessed++;

        if (node.name) {
            queue.addTask("verify-file", {
                node,
                assetStorage,
                options,
                pathFilter,
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
    log.verbose(`Verification complete: ${stats.tasksQueued} tasks queued, ${stats.maxWorkers} workers, ${stats.completed} completed, ${stats.failed} failed`);

    queue.shutdown();

    

    return result;
}

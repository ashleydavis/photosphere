import { TaskQueue, TaskStatus } from "task-queue";
import type { IUuidGenerator } from "utils";
import type { IReplicateDatabaseData, IReplicateProgressEvent } from "api";

//
// Result of the replication process.
//
export interface IReplicationResult {
    //
    // The total number of files imported.
    //
    filesImported: number;

    //
    // The number of files copied to the destination storage.
    //
    copiedFiles: number;

    //
    // The number of BSON database records copied/updated in the destination database.
    //
    copiedRecords: number;

    //
    // List of file names that were pruned from the destination.
    //
    prunedFiles: string[];

    //
    // Names of files the source's merkle tree describes but the source does not hold.
    //
    // Only ever non-empty for a partial replica, which is exactly what a phone holds: its tree is the
    // whole origin's, and the files it has are a subset. Reported rather than silently dropped, so a
    // replication that copied less than the tree describes says how much less.
    //
    missingFromSource: string[];
}

//
// Progress callback fired for each progress message emitted by the replicate-database worker.
//
export type ReplicateProgressCallback = (progress: string) => void;

//
// Replicates a database via the replicate-database background task and waits for completion.
// Both the CLI and the desktop dialog call this — it encapsulates the TaskQueue dance (subscribe,
// addTask, awaitTask, shutdown) so callers do not duplicate it.
//
// The task is queued against the registered IQueueBackend (set up at process startup by the caller
// — WorkerPoolBun in the CLI, ElectronRendererQueueBackend in the renderer).
//
// Throws the task error message when replication fails; returns the replication summary on success.
//
export async function replicateDatabase(
    uuidGenerator: IUuidGenerator,
    data: IReplicateDatabaseData,
    onProgress?: ReplicateProgressCallback,
): Promise<IReplicationResult> {
    const queue = new TaskQueue(uuidGenerator, data.sourcePath);

    if (onProgress) {
        queue.onTaskMessage<IReplicateProgressEvent>("replicate-progress", ({ message }) => {
            onProgress(message.progress);
        });
    }

    // Named after the destination, because that is what tells two replications of the same database
    // apart, and it is what the user picked.
    const destName = data.destPath.split(/[\\/]/).filter(Boolean).pop() ?? data.destPath;
    const taggedData: IReplicateDatabaseData = {
        ...data,
        job: {
            id: `replicate:${data.destPath}`,
            name: `Replicating to ${destName}`,
            cancelSource: data.sourcePath,
        },
    };
    const taskId = queue.addTask("replicate-database", taggedData);
    const result = await queue.awaitTask(taskId);
    queue.shutdown();

    if (!result) {
        throw new Error("Replication was cancelled before completion");
    }
    if (result.status !== TaskStatus.Succeeded) {
        throw new Error(result.errorMessage || "Replication failed");
    }
    return result.outputs as IReplicationResult;
}

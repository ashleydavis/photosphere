import { TaskQueue, TaskStatus } from "task-queue";
import type { IUuidGenerator } from "utils";
import type { IReplicationResult } from "./replicate";
import type { IReplicateDatabaseData, IReplicateProgressMessage } from "./replicate-database.types";

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
        queue.onTaskMessage<IReplicateProgressMessage>("replicate-progress", ({ message }) => {
            onProgress(message.progress);
        });
    }

    const taskId = queue.addTask("replicate-database", data);
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

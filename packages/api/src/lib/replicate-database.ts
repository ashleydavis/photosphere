//
// Runs a replication as a background task from the user interface and waits for it to finish.
//

import { TaskQueue, TaskStatus } from "task-queue";
import type { IUuidGenerator } from "utils";
import type { IReplicateDatabaseData, IReplicateProgressEvent, IReplicationResult } from "./replicate-database.types";

//
// Progress callback fired for each progress message emitted by the replicate-database worker.
//
export type ReplicateProgressCallback = (progress: string) => void;

//
// Replicates a database via the replicate-database background task and waits for completion.
// The replicate dialog calls this. It holds the TaskQueue steps (subscribe, addTask, awaitTask,
// shutdown) so a caller does not repeat them.
//
// The task is queued against the registered IQueueBackend, which the app sets up at startup
// (ZiggyQueueBackend in the Photosphere App).
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

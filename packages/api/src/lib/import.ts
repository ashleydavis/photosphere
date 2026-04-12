import { log } from "utils";
import { IAddSummary } from "./media-file-database";
import { TaskStatus } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { IStorageDescriptor, IS3Credentials } from "storage";
import { IAddPathsData } from "./add-paths.worker";

//
// Summary callback invoked after each task message so the caller can update progress display.
//
export type AddPathsMessageCallback = (message: any) => void;

//
// Adds a list of files or directories to the media file database.
// Dispatches a single add-paths task and waits for all downstream tasks to complete.
// Progress is reported via the optional onMessage callback.
//
export async function addPaths(
    taskQueueProvider: ITaskQueueProvider,
    storageDescriptor: IStorageDescriptor,
    paths: string[],
    googleApiKey: string | undefined,
    sessionId: string,
    s3Config: IS3Credentials | undefined,
    dryRun: boolean,
    onMessage?: AddPathsMessageCallback
): Promise<IAddSummary> {
    const queue = taskQueueProvider.get();

    const summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        filesProcessed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    queue.onAnyTaskMessage((data) => {
        if (data.message.type === "asset-imported") {
            summary.filesAdded++;
            summary.filesProcessed++;
        }
        else if (data.message.type === "file-already-added") {
            summary.filesAlreadyAdded++;
            summary.filesProcessed++;
        }
        else if (data.message.type === "file-ignored") {
            summary.filesIgnored++;
        }

        onMessage?.(data.message);
    });

    queue.onTaskComplete((_task, result) => {
        if (result.status === TaskStatus.Failed) {
            summary.filesFailed++;
            log.error(`Task failed: ${result.errorMessage}`);
        }
    });

    queue.addTask("add-paths", {
        paths,
        storageDescriptor,
        googleApiKey,
        sessionId,
        dryRun,
        s3Config,
    } satisfies IAddPathsData, storageDescriptor.dbDir);

    await queue.awaitAllTasks();

    summary.averageSize = summary.filesAdded > 0
        ? Math.floor(summary.totalSize / summary.filesAdded)
        : 0;

    return summary;
}

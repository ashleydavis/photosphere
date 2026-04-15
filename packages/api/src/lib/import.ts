import { IAddSummary } from "./media-file-database";
import { TaskQueue } from "task-queue";
import type { ITaskMessageData } from "task-queue";
import { IStorageDescriptor, IS3Credentials } from "storage";
import type { IUuidGenerator } from "utils";

//
// Progress callback invoked after each file event during import, receiving the running summary.
//
export type AddPathsProgressCallback = (currentlyScanning: string | undefined, summary: IAddSummary) => void;

//
// Adds a list of files or directories to the media file database.
// Dispatches a single add-paths task and waits for all downstream tasks to complete.
// Progress is reported via the optional onProgress callback.
//
export async function addPaths(
    uuidGenerator: IUuidGenerator,
    storageDescriptor: IStorageDescriptor,
    paths: string[],
    googleApiKey: string | undefined,
    sessionId: string,
    s3Config: IS3Credentials | undefined,
    dryRun: boolean,
    onProgress?: AddPathsProgressCallback
): Promise<IAddSummary> {
    const queue = new TaskQueue(uuidGenerator, storageDescriptor.dbDir);

    const summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        filesProcessed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    let currentlyScanning: string | undefined = undefined;

    queue.onAnyTaskMessage((data: ITaskMessageData) => {
        if (data.message.type === "import-success") {
            summary.filesAdded++;
            summary.filesProcessed++;
        }
        else if (data.message.type === "import-skipped") {
            summary.filesAlreadyAdded++;
            summary.filesProcessed++;
        }
        else if (data.message.type === "file-ignored") {
            summary.filesIgnored += data.message.count;
        }
        else if (data.message.type === "import-failed") {
            summary.filesFailed++;
            summary.filesProcessed++;
        }
        else if (data.message.type === "scan-progress") {
            currentlyScanning = data.message.currentPath;
        }
        else if (data.message.type === "import-pending") {
            // no-op: pending messages are informational only
            return;
        }

        onProgress?.(currentlyScanning, summary);
    });

    const taskId = queue.addTask("import-assets", {
        paths,
        storageDescriptor,
        googleApiKey,
        sessionId,
        dryRun,
        s3Config,
    });

    await queue.awaitTask(taskId);

    queue.shutdown();

    summary.averageSize = summary.filesAdded > 0
        ? Math.floor(summary.totalSize / summary.filesAdded)
        : 0;

    return summary;
}

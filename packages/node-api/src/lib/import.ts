import { IAddSummary } from "./media-file-database";
import { TaskQueue } from "task-queue";
import type { ITaskMessageData } from "task-queue";
import { IDatabaseDescriptor } from "api";
import type { IUuidGenerator } from "utils";
import { registerTerminationCallback } from "node-utils";
import type { IImportOptions } from "./import-assets.worker";

//
// Progress callback invoked after each file event during import, receiving the running summary.
//
export type AddPathsProgressCallback = (currentlyScanning: string | undefined, summary: IAddSummary) => void;

//
// Adds media to the database and waits for the import to finish.
//
// One import task does the work either way. Without `options.auto` it walks `paths` once and ends,
// which is `psi add`. With it, the same task is fed by a scanner that watches those places and
// imports what turns up, so it runs until it is cancelled: that is `psi add --watch`. Everything
// between the two is the same code, which is the point of it.
//
// Progress is reported via the optional onProgress callback.
//
export async function addPaths(
    uuidGenerator: IUuidGenerator,
    storageDescriptor: IDatabaseDescriptor,
    paths: string[],
    googleApiKey: string | undefined,
    sessionId: string,
    dryRun: boolean,
    onProgress?: AddPathsProgressCallback,
    options?: IImportOptions
): Promise<IAddSummary> {
    const queue = new TaskQueue(uuidGenerator, storageDescriptor.databasePath);

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
        options,
    });

    // Ctrl-C has to reach the task, not just this process: the task is what holds the watchers and
    // the temporary directory, and shutting the queue down is what tells it to stop. A watching
    // import only ends this way; a one-shot import ends on its own and never needs it.
    registerTerminationCallback(async () => {
        queue.shutdown();
    });

    await queue.awaitTask(taskId);

    queue.shutdown();

    summary.averageSize = summary.filesAdded > 0
        ? Math.floor(summary.totalSize / summary.filesAdded)
        : 0;

    return summary;
}

import * as path from "path";
import { ensureDir, getProcessTmpDir, remove } from "node-utils";
import { createStorage, loadEncryptionKeysFromPem, IStorage } from "storage";
import { IAutoImportSettings, IDatabaseDescriptor, IFolderAutoImportSource, loadDatabaseState, normaliseAutoImportSettings, updateDatabaseStateLocked } from "api";
import {
    IAutoImportItemMessage,
    IAutoImportProgressMessage,
    IAutoImportResult,
    runAutoImportLoop,
} from "api/src/lib/auto-import-loop";
import type { ITaskContext } from "task-queue";
import { TaskQueue, TaskStatus } from "task-queue";
import { iterateLeaves, SortNode } from "merkle-tree";
import { log, sleep, swallowError } from "utils";
import { resolveStorageCredentials } from "./resolve-storage-credentials";
import { loadMerkleTree } from "./tree";
import { AutoImportQueue, IBackfillCursor } from "./auto-import-queue";
import { FolderMediaSource } from "./folder-media-source";
import { buildMediaSource, registerMediaSourceBuilder } from "./media-source-registry";
import { IImportAssetsResult } from "./import-assets.worker";

//
// The long-running task that notices photos and imports them on its own. The same task runs on the
// CLI, the desktop and mobile; only the media source underneath it differs, and the task talks to
// that through IMediaSource without knowing which it has.
//
// The decisions are `runAutoImportLoop` in `packages/api`, kept apart so they can be tested with no
// filesystem, no photo library and no clock. Everything here is the part that needs a worker:
// opening the database's storage, reading its content hashes, persisting the backfill cursor under
// the write lock, and queueing the import task.
//
// This task holds an engine slot for as long as it runs, and the import it queues holds another,
// and the hash-file and upload-asset tasks that import queues in turn hold more. On mobile that
// chain has to fit inside EnginePool.POOL_SIZE with room to spare, or it deadlocks and the counts
// sit at zero forever with no error anywhere.
//

//
// The pacing used for a single pass. A single pass is an explicit one-off import rather than
// background work, so it is not paced: the caller asked for the library to be imported now.
//
const SINGLE_PASS_ITEMS_PER_MINUTE = 1000000;

//
// Payload for the auto-import task.
//
export interface IAutoImportData {
    // Identifies the target database and its optional encryption key.
    storageDescriptor: IDatabaseDescriptor;

    // What to watch, how fast to backfill, and whether to delete source files after import.
    settings: IAutoImportSettings;

    // Identifies the session, used to take the database write lock.
    sessionId: string;

    // When true the task imports everything once and returns, rather than running until cancelled.
    once: boolean;

    // Google Maps API key for reverse geocoding, passed through to the import.
    googleApiKey?: string;
}

//
// The progress and arrival messages, and the result. Defined in `packages/api` beside the code that
// produces them, and re-exported here because every caller reaches for them through this task.
//
export type { IAutoImportProgressMessage, IAutoImportItemMessage, IAutoImportResult };

//
// Folders are the source kind node-api can serve, so it registers the builder for them. The mobile
// worker registers its own builder for the device photo library, and the task itself knows about
// neither.
//
registerMediaSourceBuilder("folder", (sources, options) => {
    return new FolderMediaSource(
        sources as IFolderAutoImportSource[],
        options.pollIntervalMs,
        options.sessionTempDir,
        options.uuidGenerator
    );
});

//
// Every content hash the database holds an original for, lower-case hex.
//
// This is what confirmation means for the cleanup: not that the import said it worked, but that the
// database itself holds a file with that hash.
//
export async function loadAssetContentHashes(assetStorage: IStorage): Promise<Set<string>> {
    const hashes = new Set<string>();

    const merkleTree = await loadMerkleTree(assetStorage);
    if (!merkleTree) {
        return hashes;
    }

    for (const leaf of iterateLeaves<SortNode>(merkleTree.sort)) {
        if (!leaf.name || !leaf.contentHash) {
            continue;
        }
        if (!leaf.name.startsWith("asset/")) {
            continue;
        }
        hashes.add(leaf.contentHash.toString("hex").toLowerCase());
    }

    return hashes;
}

//
// The long-running automatic import task.
//
export async function autoImportHandler(data: IAutoImportData, context: ITaskContext): Promise<IAutoImportResult> {
    const settings = normaliseAutoImportSettings(data.settings);
    if (settings.sources.length === 0) {
        throw new Error("Automatic import was started with no sources configured. Nothing would be imported.");
    }

    const sessionTempDir = path.join(getProcessTmpDir(), "photosphere", context.uuidGenerator.generate());
    await ensureDir(sessionTempDir);

    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(data.storageDescriptor.databasePath, data.storageDescriptor.encryptionKey);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage, rawStorage } = createStorage(data.storageDescriptor.databasePath, s3Config, storageOptions);

    const savedState = await loadDatabaseState(rawStorage);
    const backfillCursor: IBackfillCursor = {
        pageCursor: savedState?.autoImportBackfillCursor,
        completed: savedState?.autoImportBackfillCompleted ?? false,
    };

    const queue = new AutoImportQueue(
        data.once ? SINGLE_PASS_ITEMS_PER_MINUTE : settings.backfillItemsPerMinute,
        backfillCursor
    );

    const source = buildMediaSource(settings.sources, {
        pollIntervalMs: settings.pollIntervalMs,
        sessionTempDir,
        uuidGenerator: context.uuidGenerator,
    });

    const importQueue = new TaskQueue(context.uuidGenerator, `auto-import-${context.taskId}`);

    //
    // Writes where the backfill has reached into the database state, so a restart resumes here.
    //
    async function persistBackfillCursor(cursor: IBackfillCursor): Promise<void> {
        await updateDatabaseStateLocked(rawStorage, data.sessionId, {
            autoImportBackfillCursor: cursor.pageCursor,
            autoImportBackfillCompleted: cursor.completed,
        });
    }

    try {
        return await runAutoImportLoop({
            source,
            queue,
            databasePath: data.storageDescriptor.databasePath,
            cleanupEnabled: settings.cleanupEnabled,
            once: data.once,
            isCancelled: () => context.isCancelled(),
            nowMs: () => Date.now(),
            sleep,

            //
            // Hands one batch to the existing import task and waits for it to finish.
            //
            importBatch: async (paths: string[]) => {
                const importTaskId = importQueue.addTask("import-assets", {
                    paths,
                    storageDescriptor: data.storageDescriptor,
                    googleApiKey: data.googleApiKey,
                    sessionId: data.sessionId,
                    dryRun: false,
                    // Every photo this brings in is badged as having arrived on its own, so the
                    // Import page can tell it from one the user asked for.
                    source: "automatic" as const,
                });
                const importTaskResult = await importQueue.awaitTask(importTaskId);

                if (importTaskResult === undefined) {
                    // The queue was shut down before the import finished, which happens when this
                    // task is cancelled. There is nothing to record about this batch.
                    return undefined;
                }

                if (importTaskResult.status !== TaskStatus.Succeeded) {
                    // The whole batch failed rather than individual files, so every file in it is a
                    // failure. Reporting none would report a clean run over an import that did not
                    // happen.
                    log.error(`Automatic import batch of ${paths.length} item(s) failed: ${importTaskResult.errorMessage}`);
                    return { imported: [], skipped: [], failedCount: paths.length };
                }

                return importTaskResult.outputs as IImportAssetsResult;
            },

            loadDatabaseHashes: () => loadAssetContentHashes(storage),
            persistCursor: persistBackfillCursor,
            onProgress: (message: IAutoImportProgressMessage) => context.sendMessage(message),
            onItem: (message: IAutoImportItemMessage) => context.sendMessage(message),
            logInfo: (message: string) => log.info(message),
            logError: (message: string) => log.error(message),
        });
    }
    finally {
        importQueue.shutdown();
        await swallowError(() => persistBackfillCursor(backfillCursor));
        await swallowError(() => remove(sessionTempDir));
    }
}

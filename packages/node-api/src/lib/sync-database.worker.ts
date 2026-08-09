import type { ITaskContext } from "task-queue";
import { createMediaFileDatabase } from "./media-file-database";
import { openStorage } from "./open-storage";
import { merkleTreeExists } from "./tree";
import { loadDatabaseConfig } from "api";
import { syncDatabases } from "./sync";
import type { ISyncDatabaseData, ISyncChange, ISyncBatchMessage, ISyncSkippedMessage, ISyncCompletedMessage } from "api";
import type { IAsset } from "api";
import { log } from "utils";

//
// Number of changes to accumulate before flushing a sync-batch message.
//
const SYNC_BATCH_SIZE = 50;

//
// Background task handler that syncs a local database with its configured origin.
// Returns early (synced: false) if there is no origin or the origin is unreachable.
// Sends sync-started / sync-completed messages so the main process can relay them to the frontend.
// Sends incremental sync-batch messages as records are synced so the UI can update live.
//
export async function syncDatabaseHandler(
    data: ISyncDatabaseData,
    context: ITaskContext
): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    try {
        const { storage: localStorage, rawStorage: localRawStorage } = await openStorage(data.databasePath);

        const config = await loadDatabaseConfig(localRawStorage);
        if (!config?.origin) {
            const reason = "no origin configured";
            log.info(`Sync skipped for "${data.databasePath}": ${reason}`);
            const skippedMessage: ISyncSkippedMessage = { type: "sync-skipped", databasePath: data.databasePath, reason };
            context.sendMessage(skippedMessage);
            return;
        }

        // Open the origin storage up-front so credentials, encryption keys, etc. are resolved via
        // the standard openStorage path. The connectivity check then runs against that storage,
        // which avoids false-negative skips when the origin needs credentials the worker would not
        // otherwise have (e.g. S3 origins registered in databases.toml with an s3_key).
        const { storage: originStorage, rawStorage: originRawStorage } = await openStorage(config.origin);

        const connected = await merkleTreeExists(originStorage);
        if (!connected) {
            const reason = `origin not accessible (${config.origin})`;
            log.info(`Sync skipped for "${data.databasePath}": ${reason}`);
            const skippedMessage: ISyncSkippedMessage = { type: "sync-skipped", databasePath: data.databasePath, reason };
            context.sendMessage(skippedMessage);
            return;
        }

        log.info(`Sync started for "${data.databasePath}" (origin: ${config.origin})`);

        context.sendMessage({ type: "sync-started", databasePath: data.databasePath });

        const localDb = createMediaFileDatabase(localStorage, uuidGenerator, timestampProvider);
        const originDb = createMediaFileDatabase(originStorage, uuidGenerator, timestampProvider);

        //
        // Accumulates changes and flushes them as sync-batch task messages in groups of SYNC_BATCH_SIZE.
        //
        let pendingBatch: ISyncChange[] = [];

        function flushBatch(): void {
            if (pendingBatch.length === 0) {
                return;
            }

            const added: IAsset[] = [];
            const updated: IAsset[] = [];
            const deletedIds: string[] = [];

            for (const change of pendingBatch) {
                if (change.type === "added" && change.asset) {
                    added.push(change.asset);
                }
                else if (change.type === "updated" && change.asset) {
                    updated.push(change.asset);
                }
                else if (change.type === "deleted" && change.assetId) {
                    deletedIds.push(change.assetId);
                }
            }

            const batchMessage: ISyncBatchMessage = {
                type: "sync-batch",
                databasePath: data.databasePath,
                added,
                updated,
                deletedIds,
            };
            context.sendMessage(batchMessage);
            pendingBatch = [];
        }

        function onLocalChange(change: ISyncChange): void {
            pendingBatch.push(change);
            if (pendingBatch.length >= SYNC_BATCH_SIZE) {
                flushBatch();
            }
        }

        // source = local, target = origin.
        // syncDatabases pulls target → source then pushes source → target.
        // So local receives origin changes, then origin receives local changes.
        // syncDatabases records lastSyncedAt and the content hash in both state files when it runs.
        const result = await syncDatabases(
            localStorage,
            localRawStorage,
            localDb.bsonDatabase,
            originStorage,
            originRawStorage,
            originDb.bsonDatabase,
            sessionId,
            onLocalChange
        );

        // Flush any remaining changes that didn't fill a full batch.
        flushBatch();

        if (result.synced) {
            log.info(`Sync completed for "${data.databasePath}"`);
        }
        else {
            log.info(`Sync skipped for "${data.databasePath}": databases already identical`);
        }

        const completedMessage: ISyncCompletedMessage = { type: "sync-completed", databasePath: data.databasePath, synced: result.synced };
        context.sendMessage(completedMessage);
    }
    catch (error) {
        log.exception(`Sync failed for "${data.databasePath}"`, error as Error);
        throw error;
    }
}

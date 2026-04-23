import type { ITaskContext } from "task-queue";
import { createStorage, loadEncryptionKeysFromPem } from "storage";
import { createMediaFileDatabase, checkConnectivity } from "./media-file-database";
import { resolveStorageCredentials } from "./resolve-storage-credentials";
import { loadDatabaseConfig, updateDatabaseConfig } from "./database-config";
import { syncDatabases } from "./sync";
import type { ISyncDatabaseData, ISyncChange, ISyncBatchMessage } from "./sync-database.types";
import type { IAsset } from "defs";
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

    const { s3Config: localS3Config, encryptionKeyPems: localEncryptionKeyPems } = await resolveStorageCredentials(data.databasePath);
    const { options: localStorageOptions } = await loadEncryptionKeysFromPem(localEncryptionKeyPems);
    const { storage: localStorage, rawStorage: localRawStorage } =
        createStorage(data.databasePath, localS3Config, localStorageOptions);

    const config = await loadDatabaseConfig(localRawStorage);
    if (!config?.origin) {
        log.info(`Sync skipped for ${data.databasePath}: no origin configured`);
        return;
    }

    const connected = await checkConnectivity(config.origin);
    if (!connected) {
        log.info(`Sync skipped for ${data.databasePath}: origin not accessible (${config.origin})`);
        return;
    }

    log.info(`Sync started`);

    context.sendMessage({ type: "sync-started", databasePath: data.databasePath });

    const { s3Config: originS3Config, encryptionKeyPems: originEncryptionKeyPems } = await resolveStorageCredentials(config.origin);
    const { options: originStorageOptions } = await loadEncryptionKeysFromPem(originEncryptionKeyPems);
    const { storage: originStorage, rawStorage: originRawStorage } =
        createStorage(config.origin, originS3Config, originStorageOptions);

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
    await syncDatabases(
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

    await updateDatabaseConfig(localRawStorage, {
        lastSyncedAt: new Date().toISOString(),
    });

    log.info(`Sync completed.`);

    context.sendMessage({ type: "sync-completed", databasePath: data.databasePath });

}

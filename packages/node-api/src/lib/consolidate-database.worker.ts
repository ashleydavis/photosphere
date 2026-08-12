import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { createMediaFileDatabase } from "./media-file-database";
import { openStorage } from "./open-storage";
import { merkleTreeExists } from "./tree";
import { consolidateDatabases, IConsolidationResult } from "./consolidate";
import { prefetchDatabaseHandler } from "./prefetch-database.worker";

//
// Payload for the consolidate-database task.
//
export interface IConsolidateDatabaseData {
    // Path of the standalone local database to join to the remote.
    databasePath: string;

    // Path or URI of the remote database to join it to.
    remotePath: string;

    // Identifies the session, used to take the write locks on both databases.
    sessionId: string;
}

//
// Streamed as consolidation pushes assets, so the user interface can show progress on what may be a
// long upload.
//
export interface IConsolidateProgressMessage {
    // Discriminator matched by onTaskMessage("consolidate-progress").
    type: "consolidate-progress";

    // How many assets have been pushed to the remote so far.
    pushed: number;

    // How many assets are being pushed in total.
    total: number;
}

//
// Joins a standalone local database to a remote that already has content in it.
//
export async function consolidateDatabaseHandler(data: IConsolidateDatabaseData, context: ITaskContext): Promise<IConsolidationResult> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }
    if (!data.remotePath) {
        throw new Error("remotePath is required");
    }

    const { uuidGenerator, timestampProvider } = context;

    const { storage: localStorage, rawStorage: localRawStorage } = await openStorage(data.databasePath);
    const { storage: remoteStorage, rawStorage: remoteRawStorage } = await openStorage(data.remotePath);

    if (!await merkleTreeExists(remoteStorage)) {
        throw new Error(`There is no database at "${data.remotePath}" to consolidate into.`);
    }

    const localDatabase = createMediaFileDatabase(localStorage, uuidGenerator, timestampProvider);
    const remoteDatabase = createMediaFileDatabase(remoteStorage, uuidGenerator, timestampProvider);

    log.info(`Consolidating "${data.databasePath}" into "${data.remotePath}".`);

    const result = await consolidateDatabases(
        data.databasePath,
        localStorage,
        localRawStorage,
        localDatabase.bsonDatabase,
        data.remotePath,
        remoteStorage,
        remoteRawStorage,
        remoteDatabase.bsonDatabase,
        data.sessionId,
        uuidGenerator,
        timestampProvider,
        (pushed, total) => {
            const message: IConsolidateProgressMessage = { type: "consolidate-progress", pushed, total };
            context.sendMessage(message);
        }
    );

    // The local database is now a partial replica whose records and thumbnails live on the remote.
    // Pulling them down is what makes it usable: without it the gallery is empty until something
    // happens to read each file, and a machine that goes offline straight after connecting would
    // show nothing at all. This is the same prefetch a partial replica gets after replication.
    await prefetchDatabaseHandler({ databasePath: data.databasePath }, context);

    log.info(`Consolidated "${data.databasePath}" into "${data.remotePath}": ${result.pushedCount} pushed, ${result.alreadyPresentCount} already there.`);

    return result;
}

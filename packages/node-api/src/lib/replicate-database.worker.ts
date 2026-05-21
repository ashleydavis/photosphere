import type { ITaskContext } from "task-queue";
import { createMediaFileDatabase } from "./media-file-database";
import { openStorage } from "./open-storage";
import { replicate, type IReplicationResult } from "./replicate";
import type { IReplicateDatabaseData, IReplicateProgressMessage } from "api";
import { log } from "utils";

//
// Background task handler that replicates a source database to a destination path.
// Wraps the pure replicate() function, opening source and destination storage via the unified
// openStorage helper. Forwards progress strings via replicate-progress task messages and returns
// the replication summary as task output.
//
export async function replicateDatabaseHandler(
    data: IReplicateDatabaseData,
    context: ITaskContext
): Promise<IReplicationResult> {
    const { uuidGenerator, timestampProvider } = context;

    if (!data.sourcePath) {
        throw new Error("sourcePath is required");
    }

    if (!data.destPath) {
        throw new Error("destPath is required");
    }

    //
    // Open source storage. When the source is registered in databases.json its credentials come
    // from there; otherwise data.sourceEncryptionKey (file path or vault name) supplies the key.
    //
    const { storage: sourceStorage } = await openStorage(data.sourcePath, data.sourceEncryptionKey);
    const sourceDb = createMediaFileDatabase(sourceStorage, uuidGenerator, timestampProvider);

    //
    // Open destination storage. The destination need not be registered in databases.json — the
    // caller passes destEncryptionKey (file path or vault name) and destS3Key (vault name) directly.
    //
    const { storage: destStorage, rawStorage: destRawStorage, encryptionKeyPems: destPems } = await openStorage(
        data.destPath,
        data.destEncryptionKey,
        data.destS3Key
    );

    log.info(`Replication started from ${data.sourcePath} to ${data.destPath}`);

    const progressCallback = (progress: string | undefined): void => {
        const message: IReplicateProgressMessage = {
            type: "replicate-progress",
            databasePath: data.sourcePath,
            progress: progress ?? "",
        };
        context.sendMessage(message);
    };

    const result = await replicate(
        data.sourcePath,
        sourceStorage,
        sourceDb.bsonDatabase,
        uuidGenerator,
        timestampProvider,
        destStorage,
        destRawStorage,
        {
            force: data.force,
            partial: data.partial,
            pathFilter: data.pathFilter,
        },
        progressCallback
    );

    //
    // If the destination is encrypted, write the public key PEM so the database can be opened later.
    //
    if (destPems.length > 0) {
        await destRawStorage.write(".db/encryption.pub", undefined, Buffer.from(destPems[0].publicKeyPem, "utf-8"));
    }

    log.info(`Replication completed from ${data.sourcePath} to ${data.destPath}`);

    return result;
}

import type { ITaskContext } from "task-queue";
import { createStorage, loadEncryptionKeysFromPem } from "storage";
import { createDatabase, createMediaFileDatabase } from "./media-file-database";
import { resolveStorageCredentials } from "./resolve-storage-credentials";

//
// Input data for the create-database task.
//
export interface ICreateDatabaseData {
    //
    // Filesystem path of the directory in which to create the new database.
    //
    databasePath: string;
}

//
// Task handler that initializes a new empty media file database at the given path.
//
export async function createDatabaseHandler(
    data: ICreateDatabaseData,
    context: ITaskContext
): Promise<void> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(data.databasePath);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage, rawStorage } = createStorage(data.databasePath, s3Config, storageOptions);
    const database = createMediaFileDatabase(storage, context.uuidGenerator, context.timestampProvider);
    await createDatabase(storage, rawStorage, context.uuidGenerator, database.metadataCollection);
}

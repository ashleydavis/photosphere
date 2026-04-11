import type { ITaskContext } from "task-queue";
import { createStorage } from "storage";
import { createDatabase, createMediaFileDatabase } from "./media-file-database";

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

    const { storage, rawStorage } = createStorage(data.databasePath, undefined, undefined);
    const database = createMediaFileDatabase(storage, context.uuidGenerator, context.timestampProvider);
    await createDatabase(storage, rawStorage, context.uuidGenerator, database.metadataCollection);
}

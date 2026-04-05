import type { ITaskContext } from "task-queue";
import { createStorage, walkDirectory } from "storage";
import { loadMerkleTree } from "./tree";
import { loadDatabaseConfig } from "./database-config";
import { retry, batchGenerator } from "utils";

//
// Number of simultaneous file fetch requests during prefetch.
//
const PREFETCH_CONCURRENCY = 3;

//
// Input data for the prefetch-database task.
//
export interface IPrefetchDatabaseData {
    //
    // Path to the partial database to prefetch.
    //
    databasePath: string;
}

//
// Task handler that pre-fetches all files missing from a partial database replica.
//
// Fetches thumbnails and BSON database files (collections + sort indexes) that
// are missing from the local replica, copying them from origin storage.
//
// Exits immediately when called against a full (non-partial) database.
//
export async function prefetchDatabaseHandler(
    data: IPrefetchDatabaseData,
    _context: ITaskContext
): Promise<void> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    //
    // Check whether this is a partial database. Skip immediately for full databases.
    //
    const { storage: localStorage, rawStorage } = createStorage(data.databasePath, undefined, undefined);
    const merkleTree = await loadMerkleTree(localStorage);
    if (!merkleTree?.databaseMetadata?.isPartial) {
        return;
    }

    //
    // Load the database config to find the origin URL.
    //
    const config = await loadDatabaseConfig(rawStorage);
    if (!config?.origin) {
        return;
    }

    const { storage: originStorage } = createStorage(config.origin, undefined, undefined);

    //
    // Yields file paths that exist in origin but are missing locally,
    // covering thumbnails and the BSON database (collections + sort indexes).
    //
    async function* missingFiles(): AsyncGenerator<string> {
        for (const dir of ["thumb", ".db/bson"]) {
            for await (const file of walkDirectory(originStorage, dir)) {
                if (!await localStorage.fileExists(file.fileName)) {
                    yield file.fileName;
                }
            }
        }
    }

    //
    // Fetch missing files PREFETCH_CONCURRENCY at a time without accumulating them in memory.
    //
    for await (const batch of batchGenerator(missingFiles(), PREFETCH_CONCURRENCY)) {
        await Promise.all(batch.map(async filePath => {
            await retry(async () => {
                const stream = await originStorage.readStream(filePath);
                await localStorage.writeStream(filePath, undefined, stream);
            });
        }));
    }
}

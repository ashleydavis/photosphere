import type { ITaskContext } from "task-queue";
import { walkDirectory } from "storage";
import { openStorage } from "./open-storage";
import { loadMerkleTree } from "./tree";
import { loadDatabaseConfig, LARGE_FILE_TIMEOUT } from "api";
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
    context: ITaskContext
): Promise<void> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    //
    // Check whether this is a partial database. Skip immediately for full databases.
    //
    const { storage: localStorage, rawStorage } = await openStorage(data.databasePath);
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

    const { storage: originStorage } = await openStorage(config.origin);

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
        if (context.isCancelled()) {
            break;
        }
        await Promise.all(batch.map(async filePath => {
            // The long timeout, because this is a file copy and a file copy is allowed to take a
            // while. `retry`'s thirty second default was what applied here, and the metadata hash
            // index of a real database is nine files of about 13 MB each: a phone cannot pull one of
            // those down and write it in thirty seconds, so each timed out, was retried, timed out
            // again, and eventually one exhausted its attempts and took the whole prefetch with it.
            // Measured on a Pixel 6, that killed the prefetch 38 minutes in, with every thumbnail
            // already fetched and the index files left behind.
            //
            // `sync.ts` and `replicate.ts` pass it at exactly this point in their own copy loops and
            // `sync.ts` carries a comment about having been bitten by it on a phone. This is the same
            // mistake in a third place.
            await retry(async () => {
                const stream = await originStorage.readStream(filePath);
                await localStorage.writeStream(filePath, undefined, stream);
            }, 3, 1_000, 2, LARGE_FILE_TIMEOUT, `Failed to prefetch ${filePath}`);
        }));
    }
}

import type { ITaskContext } from "task-queue";
import { createStorage } from "storage";
import { loadMerkleTree } from "./tree";
import { createMediaFileDatabase } from "./media-file-database";
import { loadDatabaseConfig } from "./database-config";
import { retry } from "utils";

//
// Number of simultaneous thumb fetch requests during prefetch.
//
const THUMB_PREFETCH_CONCURRENCY = 3;

//
// Input data for the prefetch-thumbs task.
//
export interface IPrefetchThumbsData {
    //
    // Path to the database whose thumbs should be prefetched.
    //
    databasePath: string;
}

//
// Task handler that pre-fetches all missing thumbnails for a partial database.
//
// When run against a full database the handler exits immediately. For a partial
// database it iterates every sort index page, checks which thumb files are absent
// locally, and drains each missing thumb stream so that LazyOriginStorage fetches
// the file from origin and writes it to the local cache.
//
// Cancellation: the task runs inside the same ITaskQueue as the preceding
// load-assets task. Calling queue.shutdown() (e.g. when the user opens a different
// database) discards any still-pending tasks before they start. If this task is
// already running it will finish its current page naturally, which is acceptable.
//
export async function prefetchThumbsHandler(
    data: IPrefetchThumbsData,
    context: ITaskContext
): Promise<void> {
    const { uuidGenerator, timestampProvider } = context;

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
    // Create the database from local storage. Sort index pages are already cached
    // locally by the preceding load-assets task.
    //
    const database = createMediaFileDatabase(localStorage, uuidGenerator, timestampProvider);

    let nextPageId: string | undefined;

    while (true) {
        const result = await database.metadataCollection.sortIndex("photoDate", "desc").getPage(nextPageId);

        //
        // Collect asset IDs from this page that do not yet have a local thumb file.
        //
        const missingIds: string[] = [];
        for (const record of result.records) {
            if (!await localStorage.fileExists(`thumb/${record._id}`)) {
                missingIds.push(record._id);
            }
        }

        //
        // Fetch missing thumbs THUMB_PREFETCH_CONCURRENCY at a time.
        // Read each thumb from origin and write it to local storage.
        //
        for (let i = 0; i < missingIds.length; i += THUMB_PREFETCH_CONCURRENCY) {
            const batch = missingIds.slice(i, i + THUMB_PREFETCH_CONCURRENCY);
            await Promise.all(batch.map(async assetId => {
                try {
                    const thumbPath = `thumb/${assetId}`;
                    await retry(async () => {
                        const stream = await originStorage.readStream(thumbPath);
                        await localStorage.writeStream(thumbPath, undefined, stream);
                    });
                }
                catch {
                    // Non-fatal: the thumb will be fetched on demand when viewed.
                }
            }));
        }

        if (!result.nextPageId) {
            break;
        }

        nextPageId = result.nextPageId;
    }
}

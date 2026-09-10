import type { ITaskContext, IJobTag } from "task-queue";
import { sendJobProgress } from "task-queue";
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

    //
    // Names the job this task belongs to, so filling a replica in shows up in the interface's job
    // list. It carries no cancel source: a background pass is queued by the host under a source the
    // interface never learns, and it is switched off from Settings rather than stopped from the job
    // list.
    //
    job?: IJobTag;
}

//
// What one prefetch pass did, which is what tells the background loop whether to keep going.
//
// A pass that fetched nothing and found nothing missing has filled the replica in, and the loop that
// asked for it can stop until a database is opened again. Anything else means there is more to do, or
// that something is in the way, and the loop asks again after its gap.
//
export interface IPrefetchDatabaseResult {
    //
    // How many files this pass copied down from the origin.
    //
    filesFetched: number;

    //
    // How many files this pass found missing and did not copy, because it was cancelled part way
    // through. Zero when the pass got to the end of what it found.
    //
    filesStillMissing: number;
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
): Promise<IPrefetchDatabaseResult> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const runStartedAt = Date.now();

    //
    // Nothing to fetch is a result, not a failure, and both of the ways of having nothing to fetch
    // are answered the same way: no files copied and none left behind, which is what tells the
    // background loop the replica is complete and it can stop asking.
    //
    const nothingToFetch: IPrefetchDatabaseResult = {
        filesFetched: 0,
        filesStillMissing: 0,
    };

    //
    // Check whether this is a partial database. Skip immediately for full databases.
    //
    const { storage: localStorage, rawStorage } = await openStorage(data.databasePath);
    const merkleTree = await loadMerkleTree(localStorage);
    if (!merkleTree?.databaseMetadata?.isPartial) {
        return nothingToFetch;
    }

    //
    // Load the database config to find the origin URL.
    //
    const config = await loadDatabaseConfig(rawStorage);
    if (!config?.origin) {
        return nothingToFetch;
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

    let filesFetched = 0;
    let filesStillMissing = 0;

    // The job the interface lists. Sent before the walk starts, because walking the origin is itself
    // minutes of work on a phone and a job that appears only once bytes move looks like nothing is
    // happening.
    sendJobProgress(context, data.job, runStartedAt, undefined);

    //
    // Fetch missing files PREFETCH_CONCURRENCY at a time without accumulating them in memory.
    //
    for await (const batch of batchGenerator(missingFiles(), PREFETCH_CONCURRENCY)) {
        if (context.isCancelled()) {
            // The batch was drawn from the walk and is not going to be fetched, so it is left behind.
            // Reporting it is what stops the loop reading a cancelled pass as a finished one.
            filesStillMissing += batch.length;
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

            filesFetched += 1;
        }));

        sendJobProgress(context, data.job, runStartedAt, `${filesFetched} files fetched`);
    }

    return {
        filesFetched,
        filesStillMissing,
    };
}

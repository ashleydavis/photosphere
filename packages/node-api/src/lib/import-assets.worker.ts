import * as os from "os";
import * as path from "path";
import { ensureDir, remove, getProcessTmpDir } from "node-utils";
import { createStorage, loadEncryptionKeysFromPem, IStorage } from "storage";
import { IAutoImportSource, IDatabaseDescriptor } from "api";
import { resolveStorageCredentials } from "./resolve-storage-credentials";
import type { ITaskContext, ITaskResult } from "task-queue";
import { TaskStatus, TaskQueue } from "task-queue";
import { IAsset } from "api";
import { log, retry, retryOrLog, sleep, swallowError } from "utils";
import { BsonDatabase } from "bdb";
import { addItem, BufferSet } from "merkle-tree";
import throttle from "lodash/throttle";
import { acquireWriteLock, releaseWriteLock } from "api";
import { loadDatabaseState } from "api";
import { loadMerkleTree, saveMerkleTree, stampDatabaseModified } from "./tree";
import { getHashCacheDir, HashCache } from "./hash-cache";
import { IImportScanner } from "./import-scanner";
import { ManualImportScanner } from "./manual-import-scanner";
import { createAutoImportScanner } from "./create-auto-import-scanner";
import { IAutoImportScannerProgress } from "./auto-import-scanner";
import { IHashFileData, IHashFileResult } from "./hash-file.worker";
import { IUploadAssetData, IUploadAssetResult, IAssetDatabaseData } from "./upload-asset.worker";
import { IImportAssetsResult, IImportedAsset, IImportProgressMessage, IImportSuccessMessage, ISkippedImport } from "api/src/lib/import-assets.types";
import { IImportRecordEntry, ImportSource } from "api/src/lib/import-record";
import { recordImports } from "./import-record-storage";
import { addDatabaseWriteBreakdown, addDatabaseWriteTiming, withExportMs, addHashFileTiming, addUploadAssetTiming, createEmptyImportTimings, formatImportTimings, withSkippedBeforeOpening, withTotalMs } from "./import-timings";

//
// How many import record entries pile up before they are written out.
//
// One hundred, the same as the hash cache, and for the same reason: each flush is a full
// read-modify-write of one file, so flushing per file would make a long import mostly writing.
//
export const IMPORT_RECORD_FLUSH_SIZE = 100;

//
// How many freshly hashed files pile up before the hash cache is written out.
//
export const CACHE_FLUSH_SIZE = 100;

//
// How many finished assets pile up before they are written to the database as one batch.
//
// Every batch pays for a full database commit, and that commit costs more as the database grows:
// measured on a Pixel 6 it went from 6.4 seconds for the first batch to 10.2 seconds by the fifth,
// against an item count that did not change. So the cost is per commit and per database size, not
// per asset, and the way to reduce it is fewer commits.
//
// A hundred was measured over a seventy minute import of a real library rather than the ten minute
// passes the earlier numbers came from: 1,416 photos taken in against 1,061 for fifty, with commit
// falling from 51% of the import to 39%. Two hundred and fifty was tried at the same time and was
// ahead for seventy minutes before stopping dead, which was put down to a commit of that many
// records holding the write lock long enough for every upload to queue behind it. That was wrong: a
// hundred stops dead in the same way, and the cause was the caught-up escape in
// shouldWriteDatabaseBatch giving every remaining photo a commit of its own. With that fixed, two
// hundred and fifty took a full import from 55 minutes to 50 and held a steady rate to the end.
//
// The cost is that a photo waits longer to appear in the gallery during a bulk backfill, and that a
// run interrupted before a batch fills loses the assets in it from the database, having already paid
// to upload and process them. That is the right trade for a first backup of a whole library, which
// is what this number is for; the scanner's caught-up escape means a phone that has finished
// backfilling still writes a photo it has just taken without waiting for the rest of a batch.
//
export const DATABASE_BATCH_SIZE = 250;

//
// Whether the assets waiting to go into the database should be written now.
//
// A batch's worth is the usual answer, because every write pays for a full database commit whatever
// its size, and a commit rewrites every shard it touches, so it costs more as the database grows.
//
// The other answer is a run that has genuinely finished with everything: an automatic import that
// brought in a handful of photos and then went quiet has to write those few rather than hold them
// for a batch that may be hours away. That is only true when nothing is in flight as well. The
// scanner reports itself caught up the moment it has read the library to the end, which on a
// backfill happens while hundreds of the photos it handed over are still being hashed and uploaded,
// and writing on that alone gave every one of those photos a full commit to itself: measured on a
// Pixel 6 against a real library, an import ran at sixty photos a minute until the scanner finished
// its walk and then fell to four and a half a minute, one twenty-six second commit per photo.
//
export function shouldWriteDatabaseBatch(pendingCount: number, scannerHasNothingLeft: boolean, hasWorkInFlight: boolean): boolean {
    if (pendingCount === 0) {
        return false;
    }

    if (pendingCount >= DATABASE_BATCH_SIZE) {
        return true;
    }

    return scannerHasNothingLeft && !hasWorkInFlight;
}

//
// Payload for the import-assets task. Contains the paths to scan plus the configuration
// needed by downstream hash-file and upload-asset tasks.
//
export interface IImportAssetsData {
    // Filesystem paths (files or directories) to import.
    paths: string[];

    // Identifies the target database and optional encryption key name.
    storageDescriptor: IDatabaseDescriptor;

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey?: string;

    // Unique identifier for the session, used to acquire the write lock.
    sessionId: string;

    // When true, files are scanned and hashed but not written to the database.
    dryRun: boolean;

    // How this import runs. Absent is the default: `paths` above is walked once and the import
    // ends, which is what every manual import does.
    options?: IImportOptions;
}

//
// How an import runs, and what it watches when it is an automatic one.
//
export interface IImportOptions {
    // Take photos from the sources below rather than walking `paths`. The import is then fed by a
    // scanner that reads those sources to the end, at the pace set below, and the run ends there.
    auto: boolean;

    // The places that are watched for new media.
    sources: IAutoImportSource[];

    // How many items the run is allowed to release per minute, so taking in a whole photo library
    // does not monopolise the phone.
    backfillItemsPerMinute: number;
}

//
// What an import reports back. Defined in `packages/api` because the mobile frontend reads it too:
// there the import runs in the embedded engine and the loop that drives it runs in the WebView.
//
export type { IImportedAsset, ISkippedImport, IImportAssetsResult };

//
// A single pending database update gathered from a completed upload-asset task.
//
interface IPendingDatabaseUpdate {
    // The asset data returned by the upload-asset worker.
    assetData: IAssetDatabaseData;

    // Logical path of the file being imported (for logging).
    logicalPath: string;

    // Total size of the uploaded asset + derivatives in bytes.
    totalSize: number;

    // Pre-computed hash, kept here so it can be deleted from hashesQueuedForImport after commit.
    expectedHash: ArrayBuffer;

    // What this file's hash cache entry is filed under, so the asset id can be recorded against it
    // once the database write has actually landed.
    cacheKey: string;
}

//
// Orchestrator handler for the import-assets task. Scans filesystem paths, hashes the files it finds
// (no more than maxConcurrentChildTasks of them at a time), deduplicates by content hash, uploads the ones
// that are new, and batches all database writes under a single throttled write lock per batch.
//
export async function importAssetsHandler(data: IImportAssetsData, context: ITaskContext): Promise<IImportAssetsResult> {
    const { paths, storageDescriptor, googleApiKey, sessionId, dryRun } = data;
    const { uuidGenerator, timestampProvider, maxConcurrentChildTasks } = context;

    if (!Number.isInteger(maxConcurrentChildTasks) || maxConcurrentChildTasks < 1) {
        throw new Error(`import-assets needs maxConcurrentChildTasks to be a whole number of at least 1, got ${maxConcurrentChildTasks}.`);
    }

    // The same outcome the messages below report, gathered so a caller that cannot see the messages
    // (an orchestrator task running in a worker) can still read what happened.
    const result: IImportAssetsResult = {
        imported: [],
        skipped: [],
        failedCount: 0,
        timings: createEmptyImportTimings(),
    };

    // When the run started, so its wall clock can be reported against the work its child tasks did.
    const runStartedAt = Date.now();

    // What the timings counted last time they were reported, so the same numbers are not reported
    // again. See where it is set for why the elapsed time is not part of it.
    let lastTimingsSignature = "";

    // True once the scanner has nothing left to hand over, which is when a part-filled batch of
    // database writes should go out rather than wait for more that are not coming.
    let scannerHasNothingLeft = false;

    // What this run did, for the database's import record. Gathered as it goes and flushed in
    // batches, so a long import is a handful of writes rather than one per file.
    let recordEntries: IImportRecordEntry[] = [];

    //
    // Writes what has been gathered for the import record so far, and forgets it.
    //
    // Flushed part way through rather than only at the end, because the end used to be the only
    // place it happened: an import of two thousand photos that died at nineteen hundred wrote no
    // record at all, and an automatic import that runs until the app quits never reached the end.
    // Each flush is a full read-modify-write of one JSON file, which is why it is every hundred
    // rather than every file. A dry run records nothing, because it changed nothing.
    //
    async function flushImportRecord(): Promise<void> {
        if (dryRun || recordEntries.length === 0) {
            return;
        }

        const entriesToWrite = recordEntries;
        recordEntries = [];
        await recordImports(storage, entriesToWrite);
    }

    //
    // Records what happened to one file, flushing when enough have piled up or enough time has
    // passed.
    //
    async function recordImportOutcome(entry: IImportRecordEntry): Promise<void> {
        recordEntries.push(entry);
        if (recordEntries.length >= IMPORT_RECORD_FLUSH_SIZE) {
            await swallowError(() => flushImportRecord());
        }
    }

    //
    // Saves the hash cache once enough files have been hashed. The timer above is what covers an
    // import that stops short of the next hundred.
    //
    async function flushCacheIfDue(): Promise<void> {
        if (filesAddedToCache % CACHE_FLUSH_SIZE !== 0) {
            return;
        }

        await swallowError(() => localHashCache.save());
    }

    // Whether a write of the hash cache and the import record is happening right now, so two of them
    // cannot overlap.
    let flushing = false;

    // How many files have been recorded in the hash cache since it was last written out. Only used to
    // say so in the log, and to say nothing when there was nothing to write.
    let pendingCacheWrites = 0;

    // Whether the user asked for this import or it arrived on its own. Recorded against every entry
    // so the Import page can say which is which.
    const importSource: ImportSource = data.options?.auto ? "automatic" : "manual";

    const hashCacheDir = getHashCacheDir(storageDescriptor.databasePath);

    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(storageDescriptor.databasePath, storageDescriptor.encryptionKey);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage, rawStorage } = createStorage(storageDescriptor.databasePath, s3Config, storageOptions);

    // What the database writes, counted where it happens.
    //
    // Committing is the largest thing a database write does and the least understood: removing
    // storage calls from it twice over changed nothing, which says the cost is not the number of
    // calls. What is left is how many bytes it moves and how long the platform takes to take them,
    // and neither has been measured.
    let databaseWrites = 0;
    let databaseWriteBytes = 0;
    let databaseWriteCallMs = 0;
    const countedStorage = new Proxy(storage, {
        get(target: IStorage, property: string | symbol) {
            const value = (target as any)[property];
            if (property !== "write" || typeof value !== "function") {
                return typeof value === "function" ? value.bind(target) : value;
            }
            return async (filePath: string, contentType: string | undefined, data: Buffer): Promise<void> => {
                const startedAt = Date.now();
                await value.call(target, filePath, contentType, data);
                databaseWriteCallMs += Date.now() - startedAt;
                databaseWriteBytes += data.length;
                databaseWrites += 1;
            };
        },
    });

    const bsonDatabase = new BsonDatabase(countedStorage, ".db/bson", uuidGenerator, timestampProvider);
    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");

    // Every hash the database already holds, and the asset it belongs to.
    //
    // Built once, here, rather than asked per file. The question is "have I already got this photo",
    // and it used to be answered by an index query inside every hash-file task, each of which built
    // its own database object so the collection's sort index cache never survived to be used twice.
    // On a Pixel 6 that was 69% of an import, and it grew as the database did: 373 milliseconds a
    // file early in a run, 4.3 seconds a file by the end of one.
    //
    // A snapshot taken at the start is enough, because anything added during the run is added to
    // hashesQueuedForImport below, which is checked as well.
    //
    const existingAssetIdsByHash = new Map<string, string>();

    async function loadExistingHashes(): Promise<void> {
        let next: string | undefined = undefined;
        do {
            const page = await metadataCollection.getAll(next);
            for (const record of page.records) {
                if (record.hash) {
                    existingAssetIdsByHash.set(record.hash, record._id);
                }
            }
            next = page.next;
        }
        while (next !== undefined);
    }

    await loadExistingHashes();

    const localHashCache = new HashCache(hashCacheDir);
    await localHashCache.load();

    // What each file in flight is filed under in the hash cache, when that is not its own path.
    // Filled in as the scanner pushes a photo library item, and dropped once the import has finished
    // with the file, so it holds only what is actually in flight rather than the whole run.
    const cacheKeysByPath = new Map<string, string>();

    // Tracks hashes already queued for import in this scan to prevent duplicate uploads.
    const hashesQueuedForImport = new BufferSet();

    let filesAddedToCache = 0;
    let isProcessingQueue = false;
    const queue = new TaskQueue(context.uuidGenerator, sessionId);
    let pendingDatabaseUpdates: IPendingDatabaseUpdate[] = [];

    // Files the scan has found that have not been handed to a hash-file task yet. The scan runs far
    // faster than the hashing, so without this the whole library would be queued in seconds and every
    // other task on the machine would wait behind it.
    const filesAwaitingHash: IHashFileData[] = [];

    // Files that have been hashed and are waiting for an upload-asset task. Held here rather than
    // queued straight away for the same reason, and drained ahead of the hash queue below.
    const assetsAwaitingUpload: IUploadAssetData[] = [];

    // How many hash-file and upload-asset tasks this import currently has in flight. Never allowed
    // above maxConcurrentChildTasks.
    let childTasksInFlight = 0;

    //
    // Whether the import still has a file it has not finished with.
    //
    // That is a task running, a file waiting to be hashed, or an asset waiting to be uploaded. The
    // scanner being caught up says only that it has nothing left to hand over, which on a backfill
    // happens while hundreds of the photos it already handed over are still being worked on.
    //
    function hasWorkInFlight(): boolean {
        return childTasksInFlight > 0 || filesAwaitingHash.length > 0 || assetsAwaitingUpload.length > 0;
    }

    //
    // What one file's hash cache entry is filed under: the identity the scanner gave it, or its own
    // path when it did not give one.
    //
    function cacheKeyOfPath(filePath: string): string {
        return cacheKeysByPath.get(filePath) ?? filePath;
    }

    //
    // Tells the scanner the import has finished with a file, whatever it made of it.
    //
    // For a photo library item this is what deletes the temporary copy that had to be made to read
    // it. Doing it here rather than at the end of the run is what keeps a long automatic import from
    // filling the sandbox with copies of every photo it has ever looked at.
    //
    function releaseFile(filePath: string): void {
        cacheKeysByPath.delete(filePath);
        // Started rather than waited for. This runs inside the completion callback of a child task,
        // and anything awaited there lets the end of the run arrive before the callback has finished
        // recording what the child did: an upload whose database write had not been queued yet was
        // dropped on the floor. Deleting a temporary copy is not something the import waits on, and
        // a failure to delete one must not fail the import, which is what the swallow is for.
        void swallowError(() => scanner.release(filePath));
    }

    //
    // Hands as many waiting files to the queue as the concurrency limit allows.
    //
    // Uploads go before hashes, because an upload finishes a file that has already been paid for:
    // draining them first keeps the number of half-imported files down and gets assets into the
    // database sooner. Called once per completion, so a slot is refilled the moment one frees.
    //
    function dispatchChildTasks(): void {
        if (context.isCancelled()) {
            // Nothing more goes to the queue once the import has been cancelled. What is already
            // waiting is abandoned, and awaitAllTasks below stops as soon as the running ones settle.
            return;
        }

        while (childTasksInFlight < maxConcurrentChildTasks) {
            const uploadData = assetsAwaitingUpload.shift();
            if (uploadData !== undefined) {
                childTasksInFlight += 1;
                queue.addTask("upload-asset", uploadData);
                continue;
            }

            const hashData = filesAwaitingHash.shift();
            if (hashData === undefined) {
                return;
            }

            childTasksInFlight += 1;
            queue.addTask("hash-file", hashData);
        }
    }

    //
    // Writes a batch of completed uploads to the Merkle tree and BSON database under the write lock.
    // Returns true on success, false if the write lock could not be acquired.
    //
    // The modified stamp this run last wrote, so the next batch can tell its own writes apart from
    // somebody else.'s. Undefined until the first batch commits, which is why the first batch of a run
    // always drops its caches: it cannot know what happened before it started.
    let lastModifiedAtWrittenByThisRun: string | undefined = undefined;

    async function processPendingDatabaseUpdates(itemsToProcess: IPendingDatabaseUpdate[]): Promise<boolean> {
        if (itemsToProcess.length === 0) {
            return true;
        }

        const databaseWriteStartedAt = Date.now();

        if (!await acquireWriteLock(rawStorage, sessionId, 1)) {
            return false;
        }
        const lockedAt = Date.now();

        // The cached shards and index pages are dropped only when somebody else has written to the
        // database since this run last did.
        //
        // Dropping them unconditionally, which is what this used to do, makes every batch read back
        // what it already had: about one and three quarter reads per record, against none when the
        // caches are kept, and those reads grow with the database because an index page holds every
        // record in it. On a phone each one crosses the embedded engine bridge.
        //
        // The check is the database.'s own modified stamp, which every writer updates under this
        // same lock, compared against what this run wrote when it last held the lock. It is read here
        // rather than before the lock because a database read outside the lock says nothing: another
        // writer can change it in the moment between.
        const stateBeforeWriting = await loadDatabaseState(rawStorage);
        const databaseChangedElsewhere = stateBeforeWriting?.lastModifiedAt !== lastModifiedAtWrittenByThisRun;
        if (databaseChangedElsewhere) {
            await bsonDatabase.flush();
        }
        const flushedAt = Date.now();

        log.verbose(`Have write lock, processing ${itemsToProcess.length} items.`);

        try {
            let merkleTree = await retry(() => loadMerkleTree(storage));
            if (!merkleTree) {
                throw new Error(`Failed to load merkle tree.`);
            }
            const treeLoadedAt = Date.now();

            // The loop below is the largest part of a database write and its cost grows with the
            // size of the database, so what it spends where is counted rather than guessed at.
            let merkleAddMs = 0;
            let recordInsertMs = 0;
            let collectionInsertMs = 0;
            let hashCacheAssetIdMs = 0;

            for (const item of itemsToProcess) {
                const { assetData, logicalPath } = item;

                const merkleAddStartedAt = Date.now();

                merkleTree = addItem(merkleTree, {
                    name: assetData.assetPath,
                    hash: Buffer.from(assetData.assetHash, "hex"),
                    length: assetData.assetLength,
                    lastModified: assetData.assetLastModified,
                });

                if (assetData.thumbPath) {
                    merkleTree = addItem(merkleTree, {
                        name: assetData.thumbPath,
                        hash: Buffer.from(assetData.thumbHash!, "hex"),
                        length: assetData.thumbLength!,
                        lastModified: assetData.thumbLastModified!,
                    });
                }

                if (assetData.displayPath) {
                    merkleTree = addItem(merkleTree, {
                        name: assetData.displayPath,
                        hash: Buffer.from(assetData.displayHash!, "hex"),
                        length: assetData.displayLength!,
                        lastModified: assetData.displayLastModified!,
                    });
                }

                merkleAddMs += Date.now() - merkleAddStartedAt;

                const recordInsertStartedAt = Date.now();

                if (!dryRun) {
                    await metadataCollection.insertOne(assetData.assetRecord);
                    const recordWrittenAt = Date.now();

                    // Recorded only here, on the far side of the write, so an id in the cache always
                    // means the asset really is in the database rather than that an import once
                    // intended to put it there. The next run reads this and skips the file without
                    // asking the database. A dry run records nothing, because it wrote nothing: an id
                    // from a dry run would make the next real import skip a file it never took in.
                    localHashCache.setAssetId(item.cacheKey, assetData.assetId);

                    // Counted apart from the insert because they are two different things that could
                    // each account for the cost: putting the record in the database, and finding the
                    // file.'s entry in the hash cache to write the id into it.
                    collectionInsertMs += recordWrittenAt - recordInsertStartedAt;
                    hashCacheAssetIdMs += Date.now() - recordWrittenAt;
                }

                recordInsertMs += Date.now() - recordInsertStartedAt;

                log.verbose(`Added file "${logicalPath}" to the database with ID "${assetData.assetId}".`);
                result.imported.push({ assetId: assetData.assetId, logicalPath, asset: assetData.assetRecord });
                await recordImportOutcome({
                    assetId: assetData.assetId,
                    logicalPath,
                    outcome: "imported",
                    importedAt: new Date(timestampProvider.dateNow()).toISOString(),
                    source: importSource,
                    micro: assetData.assetRecord.micro,
                });

                // The database is named on every arrival, because the gallery has to know which one
                // the photo landed in: automatic import writes to the default database, which is not
                // necessarily the one on screen, and an arrival in another one is not that gallery's
                // to show.
                const arrival: IImportSuccessMessage = {
                    type: "import-success",
                    databasePath: storageDescriptor.databasePath,
                    assetId: assetData.assetId,
                    logicalPath,
                    source: importSource,
                    micro: assetData.assetRecord.micro,
                    asset: assetData.assetRecord,
                };
                context.sendMessage(arrival);
            }

            if (!merkleTree.databaseMetadata) {
                merkleTree.databaseMetadata = { filesImported: 0 };
            }
            merkleTree.databaseMetadata.filesImported += itemsToProcess.length;

            const itemsAddedAt = Date.now();

            if (!dryRun) {
                await retry(() => saveMerkleTree(merkleTree, storage));
                const treeSavedAt = Date.now();

                await bsonDatabase.commit();
                const committedAt = Date.now();

                await stampDatabaseModified(storage, rawStorage);

                // Read back rather than guessed at, so the next batch compares against exactly what
                // is on disk. The stamp is a timestamp this run did not choose, and a value that
                // merely looks like it would make the next batch think somebody else had written.
                lastModifiedAtWrittenByThisRun = (await loadDatabaseState(rawStorage))?.lastModifiedAt;

                // What this batch cost, split by what it was doing. The batch count matters as much
                // as the times: the merkle tree is loaded and saved whole every batch, so a run that
                // writes in small batches pays for the whole tree over and over, and only the count
                // beside the totals shows that.
                result.timings = addDatabaseWriteBreakdown(result.timings, {
                    lockWaitMs: lockedAt - databaseWriteStartedAt,
                    flushMs: flushedAt - lockedAt,
                    treeLoadMs: treeLoadedAt - flushedAt,
                    addItemsMs: itemsAddedAt - treeLoadedAt,
                    merkleAddMs,
                    recordInsertMs,
                    collectionInsertMs,
                    hashCacheAssetIdMs,

                    // What the loop spent on everything else: recording the outcome, telling the
                    // gallery, and the bookkeeping between the two timed parts.
                    perItemOtherMs: Math.max(0, (itemsAddedAt - treeLoadedAt) - merkleAddMs - recordInsertMs),
                    treeSaveMs: treeSavedAt - itemsAddedAt,
                    commitMs: committedAt - treeSavedAt,
                    stampMs: Date.now() - committedAt,
                    writes: databaseWrites,
                    writeBytes: databaseWriteBytes,
                    writeCallMs: databaseWriteCallMs,
                });
            }

            return true;
        }
        finally {
            await releaseWriteLock(rawStorage);
            log.verbose(`Released write lock.`);

            // Counted here rather than beside the return, so a batch that failed part way still says
            // what it cost. The write lock's own wait is inside this, deliberately: waiting for the
            // lock is part of what a database write costs an import, and leaving it out would make
            // the stage look cheaper than it is.
            result.timings = addDatabaseWriteTiming(result.timings, Date.now() - databaseWriteStartedAt);
        }
    }

    //
    // Throttled processor that drains pendingDatabaseUpdates in batches.
    // Trailing-edge throttled so that multiple completions that arrive close together
    // are coalesced into a single write-lock acquisition.
    //
    const throttledProcessQueue = throttle(async () => {
        if (isProcessingQueue || pendingDatabaseUpdates.length === 0) {
            return;
        }

        // Hold back until enough assets have piled up to be worth a batch, unless the scan has run
        // dry, in which case what is waiting is all there is ever going to be.
        //
        // The throttle above coalesces completions that arrive within a second of each other, which
        // does nothing at all on a phone: an item there takes over ten seconds to reach this point,
        // so every item got a batch to itself. Measured on a Pixel 6, that was 37 batches for 42
        // photos, and each batch pays for a full database commit whatever its size. Committing is
        // 47% of the write stage and the write stage is half the import.
        //
        // The end of the run is covered without this: the final drain below calls
        // processPendingDatabaseUpdates directly rather than going through here, so nothing is left
        // stranded in a part-filled batch. The rule itself is in shouldWriteDatabaseBatch.
        if (!shouldWriteDatabaseBatch(pendingDatabaseUpdates.length, scannerHasNothingLeft, hasWorkInFlight())) {
            return;
        }

        isProcessingQueue = true;

        try {
            const itemsToProcess = pendingDatabaseUpdates;
            pendingDatabaseUpdates = [];

            const processed = await processPendingDatabaseUpdates(itemsToProcess);
            if (!processed) {
                pendingDatabaseUpdates = pendingDatabaseUpdates.concat(itemsToProcess);
            }
            else {
                for (const item of itemsToProcess) {
                    hashesQueuedForImport.delete(Buffer.from(item.expectedHash));
                }
            }
        }
        catch (error: any) {
            log.exception(`Error processing pending database updates`, error);
        }
        finally {
            isProcessingQueue = false;
        }
    }, 1000, { leading: false, trailing: true });

    //
    // Subscribe to task completions for hash-file and upload-asset tasks that belong
    // to this import session. The source filter prevents concurrent imports from
    // processing each other's completions.
    //
    queue.onTaskComplete(async (taskResult) => { //todo: would be good to have two separate handles here for better type checking!
        try {
            await recordChildTaskOutcome(taskResult);
        }
        finally {
            // In a finally so a slot is released even when handling the outcome threw. A slot leaked
            // here would be leaked for the life of the import, and enough of them would stop the
            // import dead with files still waiting and nothing running.
            childTasksInFlight -= 1;
            dispatchChildTasks();
        }
    });

    //
    // Records what one finished child task did: caches the hash, queues the upload of a file that is
    // new, or counts the failure.
    //
    async function recordChildTaskOutcome(taskResult: ITaskResult): Promise<void> {
        if (context.isCancelled()) {
            return;
        }

        if (taskResult.type === "hash-file") {
            const hashFileData = taskResult.inputs as IHashFileData;
            if (taskResult.status === TaskStatus.Succeeded) {
                const hashResult = taskResult.outputs as IHashFileResult;

                result.timings = addHashFileTiming(result.timings, hashResult);

                if (!hashResult.hashFromCache) {
                    const cacheIdentity = hashFileData.cacheIdentity;
                    if (cacheIdentity !== undefined) {
                        // Filed under the item's source id, and against the size and created time the
                        // photo library reported, not the temporary copy's own path and modified time:
                        // the copy is deleted the moment the import finishes and its modified time was
                        // minted by the copy, so an entry describing it would never match anything again.
                            localHashCache.addSourceHash(cacheIdentity.key, {
                            hash: Buffer.from(hashResult.hash),
                            lastModified: new Date(cacheIdentity.lastModified),
                            length: cacheIdentity.length,
                        });
                    }
                    else {
                        localHashCache.addHash(hashFileData.filePath, {
                            hash: Buffer.from(hashResult.hash),
                            lastModified: hashFileData.fileStat.lastModified,
                            length: hashFileData.fileStat.length,
                        });
                    }
                    filesAddedToCache++;
                    pendingCacheWrites++;
                    await flushCacheIfDue();
                }

                // Whether the database already holds this hash, answered from a map built once when
                // the run started.
                //
                // Asked synchronously, and that is not incidental. This is a task completion
                // callback, and anything awaited here lets the end of the run arrive before the
                // callback has finished recording what the child did: an upload whose database write
                // had not been queued yet is dropped on the floor. The comment further down says the
                // same thing about the upload branch, and it was learned the same way.
                //
                // The query this replaces ran inside the hash-file task, which built its own
                // database object per file, so the collection's sort index cache was fresh every
                // time and the whole hash index was loaded again to answer one question. That
                // measured 69% of an import on a Pixel 6.
                const existingAssetId = existingAssetIdsByHash.get(Buffer.from(hashResult.hash).toString("hex"));
                const filesAlreadyAdded = existingAssetId !== undefined;

                // The database already holds this file, and now the cache says so too, which is what
                // lets the next run skip it without asking the database at all.
                if (existingAssetId !== undefined) {
                    localHashCache.setAssetId(cacheKeyOfPath(hashFileData.filePath), existingAssetId);
                }

                if (filesAlreadyAdded) {
                    result.skipped.push({
                        logicalPath: hashFileData.logicalPath,
                        contentHash: Buffer.from(hashResult.hash).toString("hex"),
                    });
                    await recordImportOutcome({
                        assetId: hashFileData.assetId,
                        logicalPath: hashFileData.logicalPath,
                        outcome: "skipped",
                        importedAt: new Date(timestampProvider.dateNow()).toISOString(),
                        source: importSource,
                    });
                    context.sendMessage({ type: "import-skipped", assetId: hashFileData.assetId, logicalPath: hashFileData.logicalPath });
                    // Nothing more will read this file.
                    releaseFile(hashFileData.filePath);
                }
                else {
                    const hashBuffer = Buffer.from(hashResult.hash);
                    if (hashesQueuedForImport.has(hashBuffer)) {
                        log.verbose(`File "" is a duplicate in this scan, skipping.`);
                        releaseFile(hashFileData.filePath);
                    }
                    else {
                        hashesQueuedForImport.add(hashBuffer);
                        assetsAwaitingUpload.push({
                            filePath: hashFileData.filePath,
                            fileStat: hashFileData.fileStat,
                            contentType: hashFileData.contentType,
                            storageDescriptor: hashFileData.storageDescriptor,
                            logicalPath: hashFileData.logicalPath,
                            labels: hashFileData.labels,
                            googleApiKey: hashFileData.googleApiKey,
                            sessionId: hashFileData.sessionId,
                            dryRun: hashFileData.dryRun,
                            assetId: hashFileData.assetId,
                            expectedHash: hashResult.hash,
                        });
                    }
                }
            }
            else if (taskResult.status === TaskStatus.Failed) {
                log.error(`Failed to hash file "${hashFileData.logicalPath}": ${taskResult.errorMessage}`);
                result.failedCount += 1;
                await recordImportOutcome({ assetId: hashFileData.assetId, logicalPath: hashFileData.logicalPath, outcome: "failed", importedAt: new Date(timestampProvider.dateNow()).toISOString(), source: importSource });
                context.sendMessage({ type: "import-failed", assetId: hashFileData.assetId, logicalPath: hashFileData.logicalPath });
                releaseFile(hashFileData.filePath);
            }
        }
        else if (taskResult.type === "upload-asset") {
            const uploadData = taskResult.inputs as IUploadAssetData;
            if (taskResult.status === TaskStatus.Succeeded) {
                const uploadResult = taskResult.outputs as IUploadAssetResult;

                result.timings = addUploadAssetTiming(result.timings, uploadResult);

                pendingDatabaseUpdates.push({
                    assetData: uploadResult.assetData,
                    logicalPath: uploadData.logicalPath,
                    totalSize: uploadResult.totalSize,
                    expectedHash: uploadData.expectedHash.slice().buffer,
                    cacheKey: cacheKeyOfPath(uploadData.filePath),
                });
                // Queued and scheduled with nothing awaited in between, so the update is on the list
                // before this callback yields. An await here would let the end of the run look at an
                // empty list and finish without writing this asset to the database at all.
                throttledProcessQueue();

                // The upload has read the file and written what it needs into storage, and the
                // database write works from what it returned, so the local copy is finished with
                // even though the record has not landed yet.
                releaseFile(uploadData.filePath);
            }
            else if (taskResult.status === TaskStatus.Failed) {
                log.error(`Failed to upload file "${uploadData.logicalPath}": ${taskResult.errorMessage}`);
                result.failedCount += 1;
                await recordImportOutcome({ assetId: uploadData.assetId, logicalPath: uploadData.logicalPath, outcome: "failed", importedAt: new Date(timestampProvider.dateNow()).toISOString(), source: importSource });
                context.sendMessage({ type: "import-failed", assetId: uploadData.assetId, logicalPath: uploadData.logicalPath });
                releaseFile(uploadData.filePath);
            }
        }
    }

    const sessionTempDir = path.join(getProcessTmpDir(), "photosphere", uuidGenerator.generate());
    await ensureDir(sessionTempDir);

    // Where the files come from. The orchestrator below does not know which of the two it has: it
    // asks for files and takes what it is given. The only difference it can see is that a manual
    // scan returns when the paths have been walked, and an automatic one does not return until the
    // task is cancelled.
    const scanner: IImportScanner = data.options?.auto
        ? await createAutoImportScanner({
            ...data.options,
            storage,
            metadataCollection,
            localHashCache,
            sessionTempDir,
            context,
            onProgress: onScannerProgress,
        })
        : new ManualImportScanner(paths, { ignorePatterns: [/\.db/] }, sessionTempDir, uuidGenerator);

    //
    // How many items the scanner recognised as already imported without opening them. Kept so the
    // run can report once more at the end, after the photos it pushed have finished being imported.
    let skippedBeforeOpening = 0;

    //
    // Saves what has been learnt when the scanner says it is caught up, and reports progress.
    //
    function onScannerProgress(scannerProgress: IAutoImportScannerProgress): void {
        skippedBeforeOpening = scannerProgress.skippedAsAlreadyImported;

        // The scanner keeps a running total rather than reporting each copy, so this replaces what
        // was recorded rather than adding to it.
        result.timings = withExportMs(result.timings, scannerProgress.exportMs);

        // Save the hash cache and the import record once there is nothing left to import.
        //
        // Saving on a count alone only works for an import that ends, and this one may not:
        // automatic import brings in a handful of photos and then waits, so without this a phone
        // that imported five photos and stayed running saved none of those entries, and the next run
        // hashed and copied the same photos again. Being caught up is the moment that matters, and
        // the moment it costs nothing: nothing more is coming, and hours may pass before anything is.
        //
        // It is deliberately not a timer. This task runs inside an embedded JavaScript engine on a
        // phone, where a timer fires outside the task's own control flow, can overlap the task's own
        // writes, and outlives the task if a clear is ever missed. This runs on the scanner's own
        // loop instead. Both writes cost nothing when nothing has changed, so repeating it on every
        // idle tick is free.
        scannerHasNothingLeft = scannerProgress.caughtUp;

        if (scannerProgress.caughtUp) {
            // Nudged from here because the escape above waits for the work in flight to finish, and
            // the last of that work finishes inside a completion callback that has already asked the
            // queue whether it should write. Without this an automatic import that brought in a
            // handful of photos and then went quiet would leave them in a part-filled batch, unwritten
            // until something else happened to arrive.
            throttledProcessQueue();
        }

        if (scannerProgress.caughtUp && !flushing) {

            flushing = true;
            void swallowError(async () => {
                try {
                    const written = pendingCacheWrites;
                    pendingCacheWrites = 0;
                    await localHashCache.save();
                    await flushImportRecord();
                    if (written > 0) {
                        // Said out loud because an entry that is only in memory does nothing for the
                        // next run: it would hash and copy the same file again.
                        log.info(`Import saved ${written} hash cache entries.`);
                    }
                }
                finally {
                    flushing = false;
                }
            });
        }

        sendImportProgress(scannerProgress.currentItem);
    }

    //
    // Reports what the run has done so far, so the panel on the Import page can show it without
    // waiting for the run to end. Sent by both kinds of import, because there is nothing about it
    // that is particular to one of them.
    //
    // The counters come from this task, because it is the one that knows them: it is what sends
    // import-success, import-skipped and import-failed per file.
    //
    function sendImportProgress(currentItem: string | undefined): void {
        const message: IImportProgressMessage = {
            type: "import-progress",
            seen: result.imported.length + result.skipped.length + result.failedCount + skippedBeforeOpening,
            imported: result.imported.length,
            // What the import recognised, plus what the scanner recognised before it went to the
            // trouble of copying the photo out of the library at all.
            skipped: result.skipped.length + skippedBeforeOpening,
            failed: result.failedCount,
            currentItem,
        };
        context.sendMessage(message);

        // Where the time has gone so far, sent as the run goes rather than only when it ends.
        //
        // A run over a real photo library does not end for hours, so timings that were only reported
        // at the end could only be read by stopping the import, and stopping it means driving the
        // app's interface. That cannot be relied on: a phone left on its lockscreen has its WebView
        // paused by Android, so the command to stop the import goes unanswered and the measurement
        // is lost along with the run. Reported as it goes, a measurement is whatever the last report
        // said, and nothing has to be asked of the interface at all.
        //
        // Only when the work it counts has actually moved, though. Progress is reported on a timer
        // as well as on a completion, so sending this every time put thousands of lines that
        // differed by a millisecond into the app log of a single import and buried everything else
        // in it. The elapsed time is deliberately not part of what counts as a change: it moves on
        // every tick, which would defeat the whole check.
        const timingsSignature = `${result.timings.filesHashed}/${result.timings.filesFromCache}/${skippedBeforeOpening}/${result.timings.childTaskMs}`;
        if (timingsSignature !== lastTimingsSignature) {
            lastTimingsSignature = timingsSignature;
            context.sendMessage({
                type: "import-timings",
                timings: withTotalMs(withSkippedBeforeOpening(result.timings, skippedBeforeOpening), Date.now() - runStartedAt),
            });
        }
    }

    try {
        // Track how many files have been reported as ignored so we can emit one
        // file-ignored message per newly ignored file (scanPaths reports a cumulative count).
        let prevIgnoredCount = 0;

        await scanner.scan(
            async (result) => {
                if (context.isCancelled()) {
                    return;
                }

                if (result.cacheIdentity !== undefined) {
                    cacheKeysByPath.set(result.filePath, result.cacheIdentity.key);
                }

                filesAwaitingHash.push({
                    filePath: result.filePath,
                    fileStat: result.fileStat,
                    contentType: result.contentType,
                    storageDescriptor,
                    hashCacheDir,
                    cacheIdentity: result.cacheIdentity,
                    logicalPath: result.logicalPath,
                    labels: result.labels,
                    googleApiKey,
                    sessionId,
                    dryRun,
                    assetId: uuidGenerator.generate(),
                });
                dispatchChildTasks();
            },
            (currentlyScanning, state) => {
                const newIgnored = state.numFilesIgnored - prevIgnoredCount;
                prevIgnoredCount = state.numFilesIgnored;
                if (newIgnored > 0) {
                    context.sendMessage({ type: "file-ignored", count: newIgnored });
                }
                if (currentlyScanning) {
                    context.sendMessage({ type: "scan-progress", currentPath: currentlyScanning });
                }

                // The same progress a watching run reports. Nothing about it is particular to one
                // kind of import, so the panel shows either without knowing which it is watching.
                sendImportProgress(currentlyScanning);
            }
        );

        //
        // Wait for all child tasks to complete.
        // If the task is cancelled, childQueue.shutdown() in the finally block
        // will resolve this immediately rather than waiting for the backlog.
        //
        await queue.awaitAllTasks();

        // The queue says its tasks are finished, which is not the same as this import having finished
        // with them: a completion callback may still be recording what one of them did, and a hash
        // that has just come back may still be waiting for its upload to be queued. Ending here left
        // an uploaded asset with its database write never queued, so the file was uploaded and then
        // not in the database.
        while (childTasksInFlight > 0 || filesAwaitingHash.length > 0 || assetsAwaitingUpload.length > 0) {
            if (context.isCancelled()) {
                break;
            }
            await sleep(50);
        }

        if (context.isCancelled()) {
            return result;
        }

        // Flush the throttled queue and wait for any in-progress batch to finish.
        throttledProcessQueue.flush();
        throttledProcessQueue.cancel();

        while (isProcessingQueue) {
            await sleep(100);
        }

        // Process any remaining items, retrying until the write lock is acquired.
        while (pendingDatabaseUpdates.length > 0) {
            const processed = await processPendingDatabaseUpdates(pendingDatabaseUpdates);
            if (!processed) {
                log.error(`Failed to acquire write lock for final ${pendingDatabaseUpdates.length} pending database updates; retrying.`);
                await sleep(1000);
            }
            else {
                for (const item of pendingDatabaseUpdates) {
                    hashesQueuedForImport.delete(Buffer.from(item.expectedHash));
                }
                pendingDatabaseUpdates = [];
            }
        }

        await retryOrLog(() => localHashCache.save(), "Failed to save hash cache");

        // The last word on what this run did, sent after the photos it queued have actually landed.
        //
        // Every other progress report goes out on a scanner tick, and the scanner stops ticking the
        // moment it has read the source to the end, which is well before the last photo it pushed
        // has been hashed, uploaded and written. Without this the run's final report says nothing
        // was imported and is never corrected, which is exactly what a phone importing one photo
        // looked like: `0 imported` repeatedly, and then the run ended.
        sendImportProgress(undefined);
    }
    finally {
        queue.shutdown();
        await swallowError(() => remove(sessionTempDir));

        // Whatever has not reached the flush size yet. Written even when the import failed part way,
        // because what it did take in before failing is exactly what a user asking "what happened?"
        // wants to see.
        await swallowError(() => flushImportRecord());

        // Where the run's time went, written here rather than beside the return so a run that was
        // cancelled or that failed part way still reports it. A measurement of a photo library too
        // big to import in one sitting is a run that was stopped on purpose, and a run that reported
        // nothing because it did not reach the end would be no measurement at all.
        result.timings = withSkippedBeforeOpening(result.timings, skippedBeforeOpening);
        result.timings = withTotalMs(result.timings, Date.now() - runStartedAt);
        log.info(formatImportTimings(result.timings));

        // Sent as well as logged, because on mobile this task runs inside the embedded JS engine and
        // the line above never reaches the app log. Messages are the only thing that crosses.
        context.sendMessage({
            type: "import-timings",
            timings: result.timings,
        });
    }

    return result;
}

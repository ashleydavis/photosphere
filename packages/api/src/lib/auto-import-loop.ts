import { IAsset } from "./asset";
import { AutoImportQueue, IBackfillCursor } from "./auto-import-queue";
import { IMediaItem, IMediaSource } from "./media-source";
import { IImportAssetsResult } from "./import-assets.types";
import { IImportedSourceItem, runSourceCleanup, selectConfirmedForCleanup } from "./source-cleanup";

//
// The loop that notices photos and imports them, with nothing platform-specific in it.
//
// It owns no import machinery: every batch it decides on is handed to whatever the platform passes
// in as `importBatch`, which on every platform is the existing import task, so deduplication by
// content hash, the write lock, derivative generation and the hash cache all behave exactly as they
// do for a manual import.
//
// It lives here, apart from the auto-import task that runs it, so the decisions can be tested with
// no filesystem, no photo library, no task queue and no clock: the current time, the sleep, the
// import and the database read are all passed in.
//

//
// How often the loop wakes up to release whatever the pacing allows. Short enough that a photo the
// user has just taken appears promptly, long enough that an idle loop costs nothing.
//
export const AUTO_IMPORT_TICK_MS = 250;

//
// How many items are fetched from the source per backfill page. The pacing decides how quickly they
// are released; this only decides how often the source is asked.
//
export const BACKFILL_PAGE_SIZE = 50;

//
// How many source files are deleted per cleanup request. Batched because Android and iOS both put a
// system confirmation in front of deleting media the app does not own, and one dialog per photo
// would be unusable.
//
export const SOURCE_CLEANUP_BATCH_SIZE = 50;

//
// The most pages the arrival walk will read before giving up. A source whose cursor does not
// advance would otherwise spin here forever, so it fails loudly instead.
//
export const MAX_ARRIVAL_PAGES = 100000;

//
// Streamed as the loop makes progress, so the user interface can show what is happening without
// waiting for the loop to end (which, unless it is a single pass, it never does).
//
export interface IAutoImportProgressMessage {
    // Discriminator matched by onTaskMessage("auto-import-progress").
    type: "auto-import-progress";

    // How many items have been handed to the import.
    seen: number;

    // How many items the import added to the database.
    imported: number;

    // How many items the import recognised as already present.
    skipped: number;

    // How many items the import could not take in.
    failed: number;

    // How many source files have been deleted from the device after being confirmed.
    deletedFromSource: number;

    // How many backfill items are buffered and waiting for their turn.
    backfillRemaining: number;

    // True once the whole existing library has been walked.
    backfillComplete: boolean;

    // The item most recently handed to the import, for the user interface to name.
    currentItem: string | undefined;
}

//
// Streamed once per asset the import adds, so arrivals can be shown landing one at a time.
//
export interface IAutoImportItemMessage {
    // Discriminator matched by onTaskMessage("auto-import-item").
    type: "auto-import-item";

    // The database the asset was added to.
    //
    // Automatic import writes to the default database, which is not necessarily the one the user is
    // looking at. Without this the gallery takes every arrival as its own: a photo landing in another
    // database appears in this one, and a photo landing in this one appears twice, once from the
    // arrival and once from the load that follows.
    databasePath: string;

    // The id the asset was given in the database.
    assetId: string;

    // The path the asset was imported from.
    logicalPath: string;

    // The asset record, so the gallery can show it without reloading the database.
    asset: IAsset;
}

//
// What a run of the loop did. Only a single pass returns; a background run is cancelled.
//
export interface IAutoImportResult {
    // How many items were handed to the import.
    seen: number;

    // How many items were added to the database.
    imported: number;

    // How many items were already present.
    skipped: number;

    // How many items could not be imported.
    failed: number;

    // How many source files were deleted after being confirmed in the database.
    deletedFromSource: number;

    // True if the whole existing library was walked.
    backfillComplete: boolean;
}

//
// Everything the loop needs from the platform driving it.
//
// Everything with a side effect is passed in rather than reached for, which is what lets the whole
// loop be tested without a filesystem, a photo library or a task queue, and lets the pacing be
// walked forward without waiting for real time to pass.
//
export interface IAutoImportLoopDeps {
    // Where media arrives, already built for the configured sources.
    source: IMediaSource;

    // The two lanes and the pacing, already positioned at the persisted backfill cursor.
    queue: AutoImportQueue;

    // The database being imported into, named on every arrival so the interface can tell an arrival
    // in the database it is showing from one in another.
    databasePath: string;

    // Whether the source file is deleted once the local database is confirmed to hold it.
    cleanupEnabled: boolean;

    // When true the loop imports everything once and returns, rather than running until cancelled.
    once: boolean;

    // True once the caller wants the loop to stop. Checked in every part of the loop that can wait.
    isCancelled: () => boolean;

    // The current time in milliseconds since the epoch. Injected so the pacing is testable.
    nowMs: () => number;

    // Waits for the given number of milliseconds. Injected for the same reason.
    sleep: (milliseconds: number) => Promise<void>;

    // Hands one batch of exported paths to the platform's import, returning what it did.
    //
    // An import that failed outright reports every path in the batch as failed, because saying
    // nothing there would report a clean run over an import that did not happen. Undefined means the
    // import could not be started at all, which happens when the loop is being cancelled, and is not
    // a failure of the batch.
    importBatch: (paths: string[]) => Promise<IImportAssetsResult | undefined>;

    // Every content hash the local database holds an original for, lower-case hex. This is what
    // confirmation means for the cleanup: not that the import said it worked, but that the database
    // itself holds a file with that hash.
    loadDatabaseHashes: () => Promise<Set<string>>;

    // Records where the backfill has reached, so a restart resumes here rather than rescanning.
    persistCursor: (cursor: IBackfillCursor) => Promise<void>;

    // Reports progress to whoever is showing it.
    onProgress: (message: IAutoImportProgressMessage) => void;

    // Reports one arrival, so the gallery can show it landing.
    onItem: (message: IAutoImportItemMessage) => void;

    // Says something worth reading in the log.
    logInfo: (message: string) => void;

    // Says something that went wrong and was not thrown, so it is not lost.
    logError: (message: string) => void;
}

//
// Runs automatic import until it is cancelled, or, for a single pass, until the library has been
// walked once.
//
export async function runAutoImportLoop(deps: IAutoImportLoopDeps): Promise<IAutoImportResult> {
    const { source, queue } = deps;

    const startedAtMs = deps.nowMs();
    let seen = 0;
    let imported = 0;
    let skipped = 0;
    let failed = 0;
    let deletedFromSource = 0;
    let currentItem: string | undefined = undefined;

    // Set by the watcher and by the source's own poll. The first pass is forced, so the loop looks
    // for arrivals as soon as it starts rather than waiting for the first poll.
    let listingChanged = true;

    // Items the import took in that have not yet been considered for cleanup, and the source id each
    // came from so the right file is deleted.
    let cleanupCandidates: IImportedSourceItem[] = [];
    const sourceIdByImportPath = new Map<string, string>();

    //
    // The current counters, for the progress message and the result.
    //
    function progressMessage(): IAutoImportProgressMessage {
        return {
            type: "auto-import-progress",
            seen,
            imported,
            skipped,
            failed,
            deletedFromSource,
            backfillRemaining: queue.pendingBackfillCount(),
            backfillComplete: queue.isBackfillComplete(),
            currentItem,
        };
    }

    //
    // Records what one import run did, and tells the user interface about each arrival.
    //
    function recordImportOutcome(importResult: IImportAssetsResult): void {
        skipped += importResult.skipped.length;
        failed += importResult.failedCount;

        // A file the import recognised is in the database just as surely as one it added, so it is
        // a cleanup candidate too. Leaving it out would mean a source file the database already
        // holds is never tidied away, and is offered again on every poll for as long as the app runs.
        for (const skippedImport of importResult.skipped) {
            const sourceId = sourceIdByImportPath.get(skippedImport.logicalPath);
            if (sourceId !== undefined && skippedImport.contentHash) {
                cleanupCandidates.push({ sourceId, contentHash: skippedImport.contentHash });
            }
        }

        for (const importedAsset of importResult.imported) {
            imported += 1;

            const sourceId = sourceIdByImportPath.get(importedAsset.logicalPath);
            if (sourceId !== undefined && importedAsset.asset && importedAsset.asset.hash) {
                cleanupCandidates.push({ sourceId, contentHash: importedAsset.asset.hash });
            }

            deps.onItem({
                type: "auto-import-item",
                databasePath: deps.databasePath,
                assetId: importedAsset.assetId,
                logicalPath: importedAsset.logicalPath,
                asset: importedAsset.asset,
            });
        }
    }

    const unsubscribeWatcher = source.watch(() => {
        listingChanged = true;
    });

    //
    // Whether an item found by the arrival walk is a new arrival rather than part of the library
    // that already existed.
    //
    // While the backfill is still running, only items created since the loop started count, because
    // everything older is the backfill's job and would otherwise all arrive at once. Once the whole
    // library has been walked, anything the queue has not seen is new however old its timestamp is,
    // which is how a photo copied in from elsewhere with an old date still gets imported.
    //
    function isArrival(item: IMediaItem): boolean {
        if (queue.isBackfillComplete()) {
            return true;
        }
        return item.createdAt.getTime() >= startedAtMs;
    }

    //
    // Walks the whole listing looking for items the queue has not seen. This is what actually
    // guarantees nothing is missed, and is why it runs on every reported change rather than trusting
    // the operating system's watcher to describe what happened.
    //
    async function collectArrivals(): Promise<void> {
        let cursor: string | undefined = undefined;
        let pages = 0;

        do {
            const page = await source.listPage(cursor, BACKFILL_PAGE_SIZE);
            const arrivals = page.items.filter(isArrival);
            if (arrivals.length > 0) {
                queue.addFastLaneItems(arrivals);
            }

            cursor = page.nextCursor;
            pages += 1;
            if (pages > MAX_ARRIVAL_PAGES) {
                throw new Error(`Automatic import walked ${pages} pages without reaching the end of the source listing. The source's cursor is not advancing.`);
            }
        } while (cursor !== undefined && !deps.isCancelled());
    }

    //
    // Fetches the next page of the existing library into the backfill lane.
    //
    async function fetchBackfillPage(): Promise<void> {
        const page = await source.listPage(queue.getBackfillCursor().pageCursor, BACKFILL_PAGE_SIZE);
        const accepted = queue.addBackfillItems(page.items, page.nextCursor);
        deps.logInfo(`Automatic import found ${page.items.length} item(s) in the source, ${accepted} of them new.`);
    }

    //
    // Deletes the source files of items now confirmed present in the local database.
    //
    // Confirmation is against the database's own content hashes, not against what the import
    // reported, and it deliberately has nothing to do with the remote: the user asked for the source
    // file to go once the local database has it.
    //
    async function cleanUpConfirmedSources(): Promise<void> {
        if (cleanupCandidates.length === 0) {
            return;
        }

        const databaseHashes = await deps.loadDatabaseHashes();
        const confirmed = selectConfirmedForCleanup(cleanupCandidates, databaseHashes);
        const confirmedSourceIds = new Set(confirmed);
        // Anything not confirmed this time stays on the list and is looked at again next batch.
        cleanupCandidates = cleanupCandidates.filter(candidate => !confirmedSourceIds.has(candidate.sourceId));

        if (confirmed.length === 0) {
            return;
        }

        const result = await runSourceCleanup(source, confirmed, SOURCE_CLEANUP_BATCH_SIZE);
        deletedFromSource += result.deletedSourceIds.length;

        if (result.failedSourceIds.length > 0) {
            // Not retried: a source that refused once will refuse again, and looping would ask the
            // user the same question forever. Said out loud so the files are known to still be there.
            deps.logError(`Automatic import could not delete ${result.failedSourceIds.length} source file(s) after import: ${result.failedSourceIds.join(", ")}`);
        }
    }

    //
    // Hands one batch to the platform's import and waits for it to finish.
    //
    async function importBatch(batch: IMediaItem[]): Promise<void> {
        const paths: string[] = [];

        for (const item of batch) {
            const exportedPath = await source.openItem(item);
            paths.push(exportedPath);
            sourceIdByImportPath.set(exportedPath, item.sourceId);
            currentItem = item.displayName;
            seen += 1;
        }

        deps.logInfo(`Automatic import is importing ${paths.length} item(s).`);
        deps.onProgress(progressMessage());

        const importResult = await deps.importBatch(paths);

        if (importResult === undefined) {
            // The import could not be run at all, which happens when the loop is being cancelled.
            // There is nothing to record and nothing more to do with this batch.
            return;
        }

        recordImportOutcome(importResult);

        for (const item of batch) {
            await source.closeItem(item);
        }
        for (const exportedPath of paths) {
            sourceIdByImportPath.delete(exportedPath);
        }

        if (deps.cleanupEnabled) {
            await cleanUpConfirmedSources();
        }

        await deps.persistCursor(queue.getBackfillCursor());

        deps.onProgress(progressMessage());
    }

    //
    // True when a single pass has nothing left to do.
    //
    function singlePassIsFinished(): boolean {
        return queue.isBackfillComplete() && !queue.hasPendingBackfill() && !queue.hasPendingFastLane();
    }

    try {
        while (!deps.isCancelled()) {
            if (listingChanged) {
                listingChanged = false;
                await collectArrivals();
            }

            if (deps.isCancelled()) {
                break;
            }

            if (queue.needsBackfillPage()) {
                await fetchBackfillPage();
            }

            const batch = queue.nextBatch(deps.nowMs());
            if (batch.length > 0) {
                await importBatch(batch);
            }

            if (deps.isCancelled()) {
                break;
            }

            if (deps.once && singlePassIsFinished()) {
                break;
            }

            await deps.sleep(AUTO_IMPORT_TICK_MS);
        }
    }
    finally {
        unsubscribeWatcher();
    }

    return {
        seen,
        imported,
        skipped,
        failed,
        deletedFromSource,
        backfillComplete: queue.isBackfillComplete(),
    };
}
